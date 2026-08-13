#Requires -Version 5.1

<#
    One-time(ish) bootstrap step, not part of the regular Airtable pipeline
    chunks - see docs/README.md for how this fits in. Purpose: gsa-peo's
    Account data has been a moving target and doesn't reliably reflect the
    real universe of production Accounts, which makes testing
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

    Source: data/PEO PROD Accounts 07162026 (1).xls - a Salesforce report
    export of production Account data. Despite the .xls extension this is
    actually an HTML table (a browser "Export" from Salesforce, not a real
    binary Excel file) - parsed accordingly. Contains real production Account
    IDs/Names/Owners/hierarchy but, as expected pre-migration, no
    LDGCRM_External_ID__c/Type/Market Segment.

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
    [string]$OrgAlias = "gsa-peo",
    [string]$ApiVersion = "67.0",
    # Two levels up from scripts/data-migration/ is the repo root - can't call
    # Get-RepoRoot here since param defaults evaluate before dot-sourcing runs.
    [string]$SourceFile = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "data\PEO PROD Accounts 07162026 (1).xls")
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-ProdAccountSeed"

function Get-NormalizedName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    return $Name.Trim().ToLowerInvariant()
}

function ConvertFrom-HtmlEntities {
    param([string]$Text)

    if (-not $Text) { return $Text }

    return $Text -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' `
                 -replace '&quot;', '"' -replace '&#39;', "'" -replace '&nbsp;', ' '
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PRODUCTION ACCOUNT SEED PREP (production export -> gsa-peo)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script is READ-ONLY against Salesforce. No records are written." -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path -LiteralPath $SourceFile)) {
    throw "Production Account export not found: $SourceFile"
}

# ============================================================
# PARSE THE SOURCE (HTML table saved with an .xls extension)
# ============================================================

Write-Host "Parsing production Account export..." -ForegroundColor Cyan
$Html = Get-Content -LiteralPath $SourceFile -Raw -Encoding UTF8

$RowMatches = [regex]::Matches($Html, '<tr>(.*?)</tr>')
$AllRows = [System.Collections.Generic.List[string[]]]::new()

foreach ($RowMatch in $RowMatches) {
    $CellMatches = [regex]::Matches($RowMatch.Groups[1].Value, '<t[hd][^>]*>(.*?)</t[hd]>')
    $Cells = @($CellMatches | ForEach-Object { ConvertFrom-HtmlEntities ($_.Groups[1].Value.Trim()) })
    $AllRows.Add($Cells)
}

if ($AllRows.Count -lt 2) {
    throw "Expected a header row plus data rows in $SourceFile, found $($AllRows.Count) row(s) total."
}

$Header = $AllRows[0]
$NameColumnIndex = [array]::IndexOf($Header, "Account Name")

if ($NameColumnIndex -lt 0) {
    throw "Couldn't find an 'Account Name' column in $SourceFile. Header found: $($Header -join ' | ')"
}

$ProdNames = [System.Collections.Generic.List[string]]::new()

for ($i = 1; $i -lt $AllRows.Count; $i++) {
    $Name = $AllRows[$i][$NameColumnIndex]

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $ProdNames.Add($Name.Trim())
    }
}

Write-Host "$($ProdNames.Count) production Account rows parsed."

# ============================================================
# QUERY EXISTING gsa-peo ACCOUNTS + THE FEDERAL RECORD TYPE ID
# ============================================================

Write-Host ""
Write-Host "Querying existing gsa-peo Account names..." -ForegroundColor Cyan
$ExistingAccounts = @(Invoke-SalesforceQuery -Soql "SELECT Name FROM Account" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
Write-Host "$($ExistingAccounts.Count) existing Account records found in gsa-peo."

$ExistingNames = [System.Collections.Generic.HashSet[string]]::new()
foreach ($Account in $ExistingAccounts) {
    [void]$ExistingNames.Add((Get-NormalizedName -Name $Account.Name))
}

Write-Host ""
Write-Host "Looking up the Federal record type ID for Account..." -ForegroundColor Cyan
$RecordTypeResult = @(Invoke-SalesforceQuery -Soql "SELECT Id FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'Federal'" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

if ($RecordTypeResult.Count -ne 1) {
    throw "Expected exactly one Account RecordType named 'Federal' in gsa-peo, found $($RecordTypeResult.Count)."
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
    Write-Host "No missing Account names found - gsa-peo already has every production Account name. Nothing written to $InsertFile." -ForegroundColor Yellow
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
Write-Host ("{0,-45} {1,8:N0}" -f "Existing gsa-peo Account records", $ExistingAccounts.Count)
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
