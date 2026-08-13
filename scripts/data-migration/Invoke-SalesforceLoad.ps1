#Requires -Version 5.1

<#
    Chunk 5 of the Airtable -> Salesforce data-migration pipeline (see
    scripts/data-migration/README.md) - the actual load step. Wraps `sf data
    upsert bulk` / `sf data update bulk` (Bulk API 2.0) around a CSV produced
    by one of this directory's Build-*.ps1 transform scripts.

    Uses the Salesforce CLI rather than the headless Data Loader CLI: `sf` is
    already installed, authenticated, and used by every other script in this
    repo, whereas Data Loader CLI isn't installed anywhere in this environment
    and current versions need Java 11+ (this machine only has Java 8). Both
    tools sit on Bulk API underneath and resolve lookups the same way (a CSV
    column named "RelationshipName.LDGCRM_External_ID__c" resolves the parent
    by external ID at load time), so nothing about how the Build-*.ps1 scripts
    write their CSVs depends on which loader actually runs them.

    -Operation Upsert (default) is for every object except Account: the CSV's
    key column is the external ID field (LDGCRM_External_ID__c by default).
    -Operation Update is for Account specifically (see
    Build-AccountReconciliation.ps1): the CSV's key column must be named "Id".

    This writes to gsa-peo. Per sfdx-sandbox-ops: preflight counts are shown,
    and nothing is sent to Salesforce until you type LOAD to confirm.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ObjectApiName,

    [Parameter(Mandatory = $true)]
    [string]$CsvFile,

    [ValidateSet("Upsert", "Update")]
    [string]$Operation = "Upsert",

    [string]$ExternalIdField = "LDGCRM_External_ID__c",

    [string]$OrgAlias = "gsa-peo",
    [string]$ApiVersion = "67.0",
    [int]$WaitMinutes = 30
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Invoke-SalesforceLoad-$ObjectApiName"

function Invoke-SalesforceCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "sf $($Arguments -join ' ')" -ForegroundColor DarkGray

    $RawResult = & sf @Arguments --json

    if ($LASTEXITCODE -ne 0) {
        Write-Host $RawResult -ForegroundColor Red
        throw "Salesforce CLI command failed with exit code $LASTEXITCODE."
    }

    return $RawResult | ConvertFrom-Json
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " SALESFORCE LOAD: $ObjectApiName" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Target org alias: $OrgAlias"
Write-Host "Operation:        $Operation"
Write-Host "CSV file:         $CsvFile"
Write-Host ""

if (-not (Test-Path -LiteralPath $CsvFile)) {
    throw "CSV file not found: $CsvFile"
}

$Rows = @(Import-Csv -LiteralPath $CsvFile)

if ($Rows.Count -eq 0) {
    Write-Host "CSV has no data rows. Nothing to load." -ForegroundColor Yellow
    exit 0
}

$KeyColumn = if ($Operation -eq "Update") { "Id" } else { $ExternalIdField }

if (-not ($Rows[0].PSObject.Properties.Name -contains $KeyColumn)) {
    throw "CSV is missing the expected key column '$KeyColumn' for a $Operation operation."
}

# ============================================================
# PREFLIGHT
# ============================================================

Write-Host "Checking the target org..." -ForegroundColor Cyan
Invoke-SalesforceCliJson -Arguments @("org", "display", "--target-org", $OrgAlias) | Out-Null

$CurrentCountResult = Invoke-SalesforceCliJson -Arguments @(
    "data", "query",
    "--target-org", $OrgAlias,
    "--api-version", $ApiVersion,
    "--query", "SELECT COUNT() FROM $ObjectApiName"
)
$CurrentCount = [int]$CurrentCountResult.result.totalSize

Write-Host ""
Write-Host ("{0,-35} {1,10:N0}" -f "Rows in CSV", $Rows.Count)
Write-Host ("{0,-35} {1,10:N0}" -f "Existing $ObjectApiName records in $OrgAlias", $CurrentCount)
Write-Host ""

# ============================================================
# CONFIRMATION
# ============================================================

Write-Host "This will write $($Rows.Count) record(s) to $ObjectApiName in $OrgAlias." -ForegroundColor Yellow
$Confirmation = Read-Host "Type LOAD to continue"

if ($Confirmation -cne "LOAD") {
    Write-Host ""
    Write-Host "Load cancelled. Nothing was written." -ForegroundColor Yellow
    exit 0
}

# ============================================================
# LOAD
# ============================================================

$LogDir = Get-LogDirectory -Category "data-migration"
$ResultFile = Join-Path $LogDir "Load-$ObjectApiName-$Timestamp.json"

$LoadArguments = @(
    "data", ($Operation.ToLower()),
    "bulk",
    "--sobject", $ObjectApiName,
    "--file", $CsvFile,
    "--target-org", $OrgAlias,
    "--api-version", $ApiVersion,
    "--wait", $WaitMinutes.ToString()
)

if ($Operation -eq "Upsert") {
    $LoadArguments += @("--external-id", $ExternalIdField)
}

$LoadResult = Invoke-SalesforceCliJson -Arguments $LoadArguments
$LoadResult | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultFile -Encoding UTF8

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " LOAD COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

$JobInfo = $LoadResult.result.jobInfo

if ($JobInfo) {
    # Shape used by `sf data upsert bulk`.
    Write-Host ("{0,-35} {1}" -f "Job ID", $JobInfo.id)
    Write-Host ("{0,-35} {1}" -f "State", $JobInfo.state)
    Write-Host ("{0,-35} {1:N0}" -f "Records processed", $JobInfo.numberRecordsProcessed)
    Write-Host ("{0,-35} {1:N0}" -f "Records failed", $JobInfo.numberRecordsFailed)
}
elseif ($null -ne $LoadResult.result.processedRecords) {
    # Flat shape used by `sf data update bulk`.
    Write-Host ("{0,-35} {1}" -f "Job ID", $LoadResult.result.jobId)
    Write-Host ("{0,-35} {1:N0}" -f "Records processed", $LoadResult.result.processedRecords)
    Write-Host ("{0,-35} {1:N0}" -f "Records successful", $LoadResult.result.successfulRecords)
    Write-Host ("{0,-35} {1:N0}" -f "Records failed", $LoadResult.result.failedRecords)
}
else {
    Write-Host "Full result written to:" -ForegroundColor Cyan
    Write-Host $ResultFile
}

Write-Host ""
Write-Host "Full job result:" -ForegroundColor Cyan
Write-Host $ResultFile

}
finally {
    Stop-ScriptLog
}
