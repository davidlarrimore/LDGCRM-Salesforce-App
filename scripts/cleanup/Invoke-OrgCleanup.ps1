#Requires -Version 5.1

<#
    Interactive, destructive record cleanup for a chosen environment, with an
    optional Account bootstrap afterwards. See sfdx-sandbox-ops for the safety
    checklist this follows (target-org verification, preflight counts,
    export-before-write, typed HARD DELETE confirmation).

    Renamed from cleanup-gsa-peo.ps1 on 2026-08-13. The old name baked in an
    org alias that pointed at the DEV sandbox while reading like production -
    see scripts/common/Common.Orgs.ps1 for the whole story. This script now
    targets an ENVIRONMENT (-Environment Dev|QA|Full|Prod, default Dev) and
    resolves the alias from the registry, so what it is about to destroy is
    stated in terms a human can check against the banner it prints.

    -ObjectsCsv overrides the default full object list, for scoped cleanup
    runs that don't need to touch every migrated object (e.g. re-testing just
    the Account/Partner Account chain without disturbing already-loaded/
    verified Impediment records). Comma-separated (not a real PowerShell
    array parameter) specifically so it survives being passed through a
    nested `powershell -File` invocation intact - that's the only way to get
    a working Read-Host confirmation prompt out of this tool's non-interactive
    host, and array literals/space-separated values don't reliably cross that
    process boundary the way a single comma-joined string does. Order
    matters - list children/junctions before their parents, same as the
    default list, or deletes will fail against Restrict-type
    deleteConstraints (e.g. LDGCRM_application__c.LDGCRM_Partner_Account__c
    blocks deleting a Partner Account any Application still references).

    ------------------------------------------------------------------
    THE ACCOUNT BOOTSTRAP OPTION
    ------------------------------------------------------------------
    Deleting is only half of a rebuild. This script removes every record the
    migration created - which includes the Accounts it tagged with
    LDGCRM_External_ID__c - and the rest of the pipeline then has nothing to
    reconcile against, because Build-AccountReconciliation.ps1 deliberately
    MATCHES existing Accounts rather than creating them (Accounts pre-date the
    migration in production). A cleaned org therefore needs its Account
    universe rebuilt before any other load will do anything useful.

    That rebuild was done by hand on 2026-08-13 (cleanup -> seed -> reconcile),
    and it is the exact sequence a QA or Full-sandbox rehearsal needs to
    repeat. So: when data/peo-prod-accounts-<date>.xls is present, this script
    OFFERS to run Invoke-AccountBootstrap.ps1 against the same environment once
    the deletes finish. The bootstrap is hierarchy-aware and takes several
    passes (Account.ParentId is a self-lookup that can only be filled in once
    the parent row exists) - see that script's header.

    The offer is a prompt, not a default. -BootstrapAccounts answers yes up
    front, -SkipBootstrap answers no and suppresses the prompt entirely. The
    bootstrap runs in its own process with its own typed confirmation, so
    approving the cleanup never silently approves a load.

    Note the two halves have deliberately different scopes: this script only
    ever deletes records carrying LDGCRM_External_ID__c, and bootstrapped
    Accounts carry none. Bootstrapped Accounts are therefore NOT removed by a
    later cleanup run - which is what makes the bootstrap safely repeatable
    (it inserts only what's missing, by name).
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Escape hatch for an org that isn't in the registry. Skips the registry's
    # identity checks - see Assert-LdgcrmOrgTarget.
    [string]$OrgAlias = "",

    [string]$ObjectsCsv = "",

    # Run the Account bootstrap after the deletes without prompting.
    [switch]$BootstrapAccounts,

    # Never prompt for, and never run, the Account bootstrap.
    [switch]$SkipBootstrap
)

$DefaultObjects = @(
    "LDGCRM_Application_Contact__c",
    "LDGCRM_Opportunity_Impediment__c",
    "LDGCRM_Application__c",
    "Opportunity",
    "Contact",
    "LDGCRM_Impediment__c",
    "LDGCRM_Partner_account__c",
    "Account"
    #"LDGCRM_Market_Segment__c"
)

$Objects = if ($ObjectsCsv) { $ObjectsCsv -split "," | ForEach-Object { $_.Trim() } } else { $DefaultObjects }

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "..\data-migration\Common.DataMigration.ps1")

if ($BootstrapAccounts -and $SkipBootstrap) {
    throw "-BootstrapAccounts and -SkipBootstrap are mutually exclusive."
}

# ============================================================
# CONFIGURATION
# ============================================================

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias
$ApiVersion = "67.0"
$ExternalIdField = "LDGCRM_External_ID__c"
$WaitMinutes = 30

$Timestamp = Start-ScriptLog -Category "cleanup" -ScriptName "Invoke-OrgCleanup"
$OutputDirectory = Join-Path (Get-LogDirectory -Category "cleanup") "org-cleanup-$Timestamp"

# ============================================================
# FUNCTIONS
# ============================================================

function Invoke-SalesforceCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "sf $($Arguments -join ' ')" -ForegroundColor DarkGray

    & sf @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Salesforce CLI command failed with exit code $LASTEXITCODE."
    }
}

function Get-MatchingRecordCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectApiName
    )

    $Soql = "SELECT COUNT() FROM $ObjectApiName WHERE $ExternalIdField != null"

    $RawResult = & sf data query `
        --target-org $OrgAlias `
        --api-version $ApiVersion `
        --query $Soql `
        --json

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query $ObjectApiName."
    }

    $JsonResult = $RawResult | ConvertFrom-Json

    if ($JsonResult.status -ne 0) {
        $ErrorMessage = $JsonResult.message

        if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $ErrorMessage = "Unknown Salesforce CLI error."
        }

        throw $ErrorMessage
    }

    return [int]$JsonResult.result.totalSize
}

function Export-RecordIds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectApiName,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile
    )

    $Soql = "SELECT Id FROM $ObjectApiName WHERE $ExternalIdField != null"

    Invoke-SalesforceCli -Arguments @(
        "data", "export", "bulk",
        "--target-org", $OrgAlias,
        "--api-version", $ApiVersion,
        "--query", $Soql,
        "--output-file", $OutputFile,
        "--result-format", "csv",
        "--wait", $WaitMinutes.ToString()
    )
}

function Test-DeleteFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CsvFile
    )

    if (-not (Test-Path -LiteralPath $CsvFile)) {
        throw "The expected CSV file was not created: $CsvFile"
    }

    $Rows = @(Import-Csv -LiteralPath $CsvFile)

    if ($Rows.Count -eq 0) {
        return 0
    }

    $Columns = @($Rows[0].PSObject.Properties.Name)

    if ($Columns.Count -ne 1 -or $Columns[0] -ne "Id") {
        throw "The CSV must contain exactly one column named Id."
    }

    foreach ($Row in $Rows) {
        if ([string]::IsNullOrWhiteSpace($Row.Id)) {
            throw "The CSV contains an empty record ID."
        }
    }

    return $Rows.Count
}

function Remove-Records {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectApiName,

        [Parameter(Mandatory = $true)]
        [string]$CsvFile
    )

    Invoke-SalesforceCli -Arguments @(
        "data", "delete", "bulk",
        "--target-org", $OrgAlias,
        "--api-version", $ApiVersion,
        "--sobject", $ObjectApiName,
        "--file", $CsvFile,
        "--hard-delete",
        "--wait", $WaitMinutes.ToString()
    )
}

function Invoke-AccountBootstrapStep {
    <#
        Offers, then runs, the Account bootstrap.

        Run as a CHILD PROCESS rather than dot-sourced, for two reasons: the
        bootstrap has its own typed confirmation (which needs a real console,
        the same reason this script is itself run via `powershell -File`), and
        a failure there must not take down this script's own transcript and
        summary. Its exit code is reported, not swallowed.
    #>
    param(
        [string]$Env,
        [string]$Alias,
        [bool]$AlreadyAnswered,
        [bool]$Suppressed
    )

    if ($Suppressed) {
        return "Skipped (-SkipBootstrap)"
    }

    $ExportPath = Resolve-ProdAccountExportPath

    if (-not $ExportPath) {
        Write-Host ""
        Write-Host "No production Account export found in data/ - skipping the bootstrap offer." -ForegroundColor DarkGray
        Write-Host "(Expected data/peo-prod-accounts-<yyyy-MM-dd>.xls)" -ForegroundColor DarkGray
        return "Not offered (no export file)"
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " OPTIONAL: BOOTSTRAP THE ACCOUNT TREE" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "A production Account export is available:"
    Write-Host "  $ExportPath"
    Write-Host ""
    Write-Host "The pipeline reconciles onto EXISTING Accounts rather than creating"
    Write-Host "them, so a cleaned org has nothing for the later loads to attach to."
    Write-Host "Bootstrapping rebuilds the Account names and their parent hierarchy"
    Write-Host "(several passes - ParentId is a self-lookup)."
    Write-Host ""

    if (-not $AlreadyAnswered) {
        $Answer = Read-Host "Run the Account bootstrap against $Alias now? (y/N)"

        if ($Answer -notmatch '^(y|yes)$') {
            Write-Host ""
            Write-Host "Bootstrap skipped. Run it later with:" -ForegroundColor Yellow
            Write-Host "  .\scripts\data-migration\Invoke-AccountBootstrap.ps1 -Environment $Env" -ForegroundColor Yellow
            return "Declined at the prompt"
        }
    }

    $BootstrapScript = Join-Path (Split-Path -Parent $PSScriptRoot) "data-migration\Invoke-AccountBootstrap.ps1"

    if (-not (Test-Path -LiteralPath $BootstrapScript)) {
        Write-Host "Bootstrap script not found: $BootstrapScript" -ForegroundColor Red
        return "FAILED (script not found)"
    }

    Write-Host ""
    Write-Host "Handing off to Invoke-AccountBootstrap.ps1..." -ForegroundColor Cyan

    & powershell -NoProfile -ExecutionPolicy Bypass -File $BootstrapScript -Environment $Env

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "The Account bootstrap exited with code $LASTEXITCODE - review its transcript in logs/data-migration/." -ForegroundColor Red
        return "FAILED (exit $LASTEXITCODE)"
    }

    return "Completed"
}

# ============================================================
# START
# ============================================================

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " SALESFORCE ORG DATA CLEANUP" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Confirm that Salesforce CLI is installed.
Invoke-SalesforceCli -Arguments @("--version")

# Verify the alias still points at the org the registry says it does, BEFORE
# counting anything. This replaces the old "print `sf org display` and hope the
# operator reads it" check - a repointed alias now stops the run outright.
$OrgInfo = Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias

Write-Host "API version:       $ApiVersion"
Write-Host "External ID field: $ExternalIdField"
Write-Host "Delete mode:       HARD DELETE" -ForegroundColor Red
Write-Host ""
Write-Host "Only records with $ExternalIdField populated are deleted."
Write-Host "Objects, in order: $($Objects -join ' -> ')"
Write-Host ""

# ============================================================
# PREFLIGHT RECORD COUNTS
# ============================================================

Write-Host "Counting records selected for deletion..." -ForegroundColor Cyan
Write-Host ""

$Counts = [ordered]@{}
$TotalRecords = 0

foreach ($ObjectApiName in $Objects) {
    try {
        $Count = Get-MatchingRecordCount -ObjectApiName $ObjectApiName

        $Counts[$ObjectApiName] = $Count
        $TotalRecords += $Count

        Write-Host ("{0,-35} {1,12:N0}" -f $ObjectApiName, $Count)
    }
    catch {
        Write-Host ""
        Write-Host "PRE-FLIGHT CHECK FAILED" -ForegroundColor Red
        Write-Host "Object: $ObjectApiName" -ForegroundColor Red
        Write-Host "Error:  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Confirm that:" -ForegroundColor Yellow
        Write-Host "  1. The object API name is correct."
        Write-Host "  2. $ExternalIdField exists on the object."
        Write-Host "  3. Your Salesforce user can read and delete the records."
        exit 1
    }
}

Write-Host ""
Write-Host "Total records selected: $($TotalRecords.ToString('N0'))" `
    -ForegroundColor Yellow

$Results = @()

if ($TotalRecords -eq 0) {
    Write-Host ""
    Write-Host "No matching records were found. Nothing was deleted." `
        -ForegroundColor Green

    # Deliberately NOT an early exit any more. An org with nothing to delete is
    # the normal state of a freshly-refreshed QA/Full sandbox, and that is
    # precisely when the Account bootstrap is most needed - exiting here would
    # have made the combined "reset this org" workflow impossible to run in one
    # go.
    $BootstrapStatus = Invoke-AccountBootstrapStep `
        -Env $Environment `
        -Alias $OrgAlias `
        -AlreadyAnswered ([bool]$BootstrapAccounts) `
        -Suppressed ([bool]$SkipBootstrap)

    Write-Host ""
    Write-Host "Account bootstrap: $BootstrapStatus" -ForegroundColor Cyan
    exit 0
}

# ============================================================
# ONE CONFIRMATION
# ============================================================

Write-Host ""
Write-Host "WARNING" -ForegroundColor Red
Write-Host "These records will be permanently deleted from $OrgAlias." `
    -ForegroundColor Red
Write-Host "They will not be placed in the Recycle Bin." `
    -ForegroundColor Red
Write-Host ""

if (-not (Assert-LdgcrmProductionConsent -Environment $Environment -Action "HARD DELETE $($TotalRecords.ToString('N0')) migrated record(s)")) {
    exit 0
}

$Confirmation = Read-Host "Type HARD DELETE to continue"

if ($Confirmation -cne "HARD DELETE") {
    Write-Host ""
    Write-Host "Cleanup cancelled. No records were deleted." `
        -ForegroundColor Yellow
    exit 0
}

# ============================================================
# CREATE RUN DIRECTORY
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $OutputDirectory `
    -Force | Out-Null

Write-Host ""
Write-Host "Output directory:" -ForegroundColor Cyan
Write-Host $OutputDirectory

# ============================================================
# EXPORT AND DELETE
# ============================================================

foreach ($ObjectApiName in $Objects) {
    $ExpectedCount = $Counts[$ObjectApiName]

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Processing $ObjectApiName" -ForegroundColor Cyan
    Write-Host "============================================================"

    if ($ExpectedCount -eq 0) {
        Write-Host "No matching records. Skipped." -ForegroundColor DarkGray

        $Results += [PSCustomObject]@{
            Object        = $ObjectApiName
            PreflightCount = 0
            ExportedCount = 0
            Status        = "Skipped"
        }

        continue
    }

    $CsvFile = Join-Path $OutputDirectory "$ObjectApiName.csv"

    try {
        Write-Host ""
        Write-Host "Exporting record IDs..." -ForegroundColor Cyan

        Export-RecordIds `
            -ObjectApiName $ObjectApiName `
            -OutputFile $CsvFile

        $ExportedCount = Test-DeleteFile -CsvFile $CsvFile

        Write-Host ""
        Write-Host "Exported IDs: $($ExportedCount.ToString('N0'))"

        if ($ExportedCount -eq 0) {
            Write-Host "No IDs were exported. Delete skipped." `
                -ForegroundColor Yellow

            $Results += [PSCustomObject]@{
                Object         = $ObjectApiName
                PreflightCount = $ExpectedCount
                ExportedCount  = 0
                Status         = "No exported records"
            }

            continue
        }

        if ($ExportedCount -ne $ExpectedCount) {
            Write-Host ""
            Write-Host "Notice: the current export count differs from the preflight count." `
                -ForegroundColor Yellow
            Write-Host "Preflight count: $ExpectedCount"
            Write-Host "Export count:    $ExportedCount"
            Write-Host "The script will delete only the IDs in the exported CSV." `
                -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "Hard deleting $($ExportedCount.ToString('N0')) records..." `
            -ForegroundColor Yellow

        Remove-Records `
            -ObjectApiName $ObjectApiName `
            -CsvFile $CsvFile

        Write-Host ""
        Write-Host "$ObjectApiName completed successfully." `
            -ForegroundColor Green

        $Results += [PSCustomObject]@{
            Object         = $ObjectApiName
            PreflightCount = $ExpectedCount
            ExportedCount  = $ExportedCount
            Status         = "Completed"
        }
    }
    catch {
        Write-Host ""
        Write-Host "DELETE FAILED" -ForegroundColor Red
        Write-Host "Object: $ObjectApiName" -ForegroundColor Red
        Write-Host "Error:  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "The script has stopped. Parent objects were not processed." `
            -ForegroundColor Yellow
        Write-Host "The Account bootstrap was NOT offered - bootstrapping on top of a" `
            -ForegroundColor Yellow
        Write-Host "half-deleted org would confuse the next run's preflight counts." `
            -ForegroundColor Yellow

        $Results += [PSCustomObject]@{
            Object         = $ObjectApiName
            PreflightCount = $ExpectedCount
            ExportedCount  = 0
            Status         = "FAILED"
        }

        $PartialSummaryFile = Join-Path `
            $OutputDirectory `
            "cleanup-summary.csv"

        $Results |
            Export-Csv `
                -LiteralPath $PartialSummaryFile `
                -NoTypeInformation `
                -Encoding UTF8

        Write-Host ""
        Write-Host "Partial summary:" -ForegroundColor Cyan
        Write-Host $PartialSummaryFile

        exit 1
    }
}

# ============================================================
# FINAL SUMMARY
# ============================================================

$SummaryFile = Join-Path $OutputDirectory "cleanup-summary.csv"

$Results |
    Export-Csv `
        -LiteralPath $SummaryFile `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " CLEANUP COMPLETED" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

$Results | Format-Table -AutoSize

Write-Host ""
Write-Host "Summary file:" -ForegroundColor Cyan
Write-Host $SummaryFile
Write-Host ""
Write-Host "Exported ID files:" -ForegroundColor Cyan
Write-Host $OutputDirectory

# ============================================================
# OPTIONAL ACCOUNT BOOTSTRAP
# ============================================================

$BootstrapStatus = Invoke-AccountBootstrapStep `
    -Env $Environment `
    -Alias $OrgAlias `
    -AlreadyAnswered ([bool]$BootstrapAccounts) `
    -Suppressed ([bool]$SkipBootstrap)

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " DONE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Environment:       $Environment ($OrgAlias)"
Write-Host "Records deleted:   $(($Results | Where-Object { $_.Status -eq 'Completed' } | Measure-Object -Property ExportedCount -Sum).Sum)"
Write-Host "Account bootstrap: $BootstrapStatus"

}
finally {
    Stop-ScriptLog
}
