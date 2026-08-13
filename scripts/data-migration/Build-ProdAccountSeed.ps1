#Requires -Version 5.1

<#
    ============================================================
    SUPERSEDED 2026-08-13 by Invoke-AccountBootstrap.ps1. PREFER THAT.
    ============================================================
    This script seeds Account NAMES ONLY and deduplicates them by name.
    Invoke-AccountBootstrap.ps1 does everything this does and also rebuilds the
    parent hierarchy, in multiple passes, against any registered environment.

    Keeping this file for the record, but be aware of what its name-dedupe
    actually cost: production has 14 Account names borne by two or more
    DISTINCT Accounts ("Office of the Inspector General" under four different
    departments, and so on). Collapsing those to one record each means a later
    hierarchy pass cannot tell which planned Account an existing record
    represents - 31 rows in the first bootstrap dry run had to be reported as
    unmappable for exactly this reason. A sandbox seeded by this script will
    always carry that gap; one seeded by Invoke-AccountBootstrap.ps1 from empty
    will not.

    Kept, not deleted, because docs/engineering/ARCHITECTURE.md and TRANSFORMATION-RULES.md
    record what it did on 2026-08-13 and those accounts of the rebuild should
    stay checkable. Delete it once the bootstrap has been exercised in QA.
    ============================================================

    One-time(ish) bootstrap step, not part of the regular Airtable pipeline
    chunks - see docs/engineering/ARCHITECTURE.md for how this fits in. Purpose: the Dev
    sandbox's Account data has been a moving target and doesn't reliably
    reflect the real universe of production Accounts, which makes testing
    Build-AccountReconciliation.ps1 against it a weak proxy for how the real
    production migration will behave. This script closes that gap by seeding
    gsa-peo with the actual production Account names first, so the
    reconciliation script can then be tested against a realistic baseline -
    exactly the two-phase test the user asked for:
      1. THIS script: seed base Account records (Name only, Federal record
         type) for every production Account name gsa-peo doesn't already have.
      2. Re-run Build-AccountReconciliation.ps1 + Invoke-SalesforceLoad.ps1
         (already built, no changes needed) against the now-realistic Account
         set, to prove out the actual production reconciliation+backfill
         process.

    Source: data/peo-prod-accounts-<yyyy-MM-dd>.xls (renamed 2026-08-13 from
    "PEO PROD Accounts 07162026 (1).xls") - a Salesforce report export of
    production Account data. Despite the .xls extension this is actually an
    HTML table (a browser "Export" from Salesforce, not a real binary Excel
    file). Parsed by the SHARED Import-ProdAccountExport in
    Common.DataMigration.ps1, which also documents the two traps in the file -
    notably that its "Account ID" column is misaligned and does NOT identify
    the row. Contains real production Account Names/Owners/hierarchy but, as
    expected pre-migration, no LDGCRM_External_ID__c/Type/Market Segment.

    Scope (user-confirmed 2026-08-13): Name only. Nothing in this migration's
    scripts reads Account.Owner or the Parent Account hierarchy - only
    Name (for matching) and Id (once matched) matter to
    Build-AccountReconciliation.ps1 - so this deliberately does not attempt to
    reconstruct Owner or Parent Account hierarchy, which would need
    email-based User matching and a two-pass parent-before-child load
    respectively, for no effect on what's actually being tested.

    Confirmed via `sf sobject describe`-equivalent lookup that Account.Type
    (Federal vs State) can't be inferred from this export - it isn't a column
    here. That's fine: Type gets backfilled in phase 2 from the Airtable
    "States + DC/PR" checkbox, same as every other Account, once these seed
    rows exist to backfill onto.

    Read-only against Salesforce (two SOQL queries: existing Account Names,
    and the Federal RecordTypeId) - this script does not write to gsa-peo. It
    only produces a local CSV, loaded separately via:
      Invoke-SalesforceLoad.ps1 -ObjectApiName Account -Operation Insert
        -CsvFile data/salesforce-loads/Account-prod-seed-insert.csv
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (scripts/common/Common.Orgs.ps1).
    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # Empty = newest data/peo-prod-accounts-<yyyy-MM-dd>.xls, resolved after
    # dot-sourcing by Resolve-ProdAccountExportPath. (Param defaults evaluate
    # before dot-sourcing, so it can't be resolved here.) The export was
    # renamed from "PEO PROD Accounts 07162026 (1).xls" on 2026-08-13.
    [string]$SourceFile = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-ProdAccountSeed"

function Get-NormalizedName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    return $Name.Trim().ToLowerInvariant()
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PRODUCTION ACCOUNT SEED PREP (production export -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script is READ-ONLY against Salesforce. No records are written." -ForegroundColor Yellow
Write-Host ""

if (-not $SourceFile) {
    $SourceFile = Resolve-ProdAccountExportPath
}

if (-not $SourceFile) {
    throw "No production Account export found. Expected data/peo-prod-accounts-<yyyy-MM-dd>.xls"
}

# ============================================================
# PARSE THE SOURCE (HTML table saved with an .xls extension)
# ============================================================

# Parsing now goes through the SHARED Import-ProdAccountExport in
# Common.DataMigration.ps1, which Invoke-AccountBootstrap.ps1 also uses. It
# used to be a private copy here; two parsers over one quirky file is how the
# two scripts end up disagreeing about what's in it.
Write-Host "Parsing production Account export..." -ForegroundColor Cyan
Write-Host "  $SourceFile"

$ExportRows = @(Import-ProdAccountExport -Path $SourceFile)
$ProdNames = @($ExportRows | ForEach-Object { $_.Name })

Write-Host "$($ProdNames.Count) production Account rows parsed."

# ============================================================
# QUERY EXISTING gsa-peo ACCOUNTS + THE FEDERAL RECORD TYPE ID
# ============================================================

Write-Host ""
Write-Host "Querying existing $OrgAlias Account names..." -ForegroundColor Cyan
$ExistingAccounts = @(Invoke-SalesforceQuery -Soql "SELECT Name FROM Account" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
Write-Host "$($ExistingAccounts.Count) existing Account records found in $OrgAlias."

$ExistingNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($Account in $ExistingAccounts) {
    [void]$ExistingNames.Add((Get-NormalizedName -Name $Account.Name))
}

Write-Host ""
Write-Host "Looking up the Federal record type ID for Account..." -ForegroundColor Cyan
$RecordTypeResult = @(Invoke-SalesforceQuery -Soql "SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'Federal'" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

if ($RecordTypeResult.Count -ne 1) {
    throw "Expected exactly one Account RecordType named 'Federal' in $OrgAlias, found $($RecordTypeResult.Count)."
}

$FederalRecordTypeId = $RecordTypeResult[0].Id
Write-Host "Federal RecordTypeId: $FederalRecordTypeId"

# ============================================================
# COMPUTE THE MISSING SET
# ============================================================

$SeenInThisRun = [System.Collections.Generic.HashSet[string]]::new()
$InsertRows = [System.Collections.Generic.List[object]]::new()
$DuplicateInSourceCount = 0

foreach ($ProdName in $ProdNames) {
    $Normalized = Get-NormalizedName -Name $ProdName

    if ($ExistingNames.Contains($Normalized)) {
        continue
    }

    if ($SeenInThisRun.Contains($Normalized)) {
        # Same production Account name appears more than once in the export
        # (a hierarchy report can list a name at multiple levels) - insert it
        # once, not once per occurrence.
        $DuplicateInSourceCount++
        continue
    }

    [void]$SeenInThisRun.Add($Normalized)

    $InsertRows.Add([PSCustomObject]@{
        Name         = $ProdName
        RecordTypeId = $FederalRecordTypeId
    })
}

# ============================================================
# WRITE OUTPUT
# ============================================================

$LoadDir = Get-SalesforceLoadDirectory
$InsertFile = Join-Path $LoadDir "Account-prod-seed-insert.csv"

if ($InsertRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $InsertRows.ToArray() -Path $InsertFile
}
else {
    Write-Host ""
    Write-Host "No missing Account names found - $OrgAlias already has every production Account name. Nothing written to $InsertFile." -ForegroundColor Yellow
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " PRODUCTION ACCOUNT SEED PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-45} {1,8:N0}" -f "Production Account rows (export)", $ProdNames.Count)
Write-Host ("{0,-45} {1,8:N0}" -f "Duplicate names within the export (deduped)", $DuplicateInSourceCount)
Write-Host ("{0,-45} {1,8:N0}" -f "Existing Account records in the org", $ExistingAccounts.Count)
Write-Host ("{0,-45} {1,8:N0}" -f "Already present by name (skipped)", ($ProdNames.Count - $DuplicateInSourceCount - $InsertRows.Count))
Write-Host ("{0,-45} {1,8:N0}" -f "New Accounts to insert", $InsertRows.Count)
Write-Host ""

if ($InsertRows.Count -gt 0) {
    Write-Host "Insert file (pure insert, no key column - see Invoke-SalesforceLoad.ps1 -Operation Insert):" -ForegroundColor Cyan
    Write-Host $InsertFile
}

}
finally {
    Stop-ScriptLog
}
