#Requires -Version 5.1

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")

# ============================================================
# HARDCODED CONFIGURATION
# ============================================================

$OrgAlias = "gsa-peo"
$ApiVersion = "67.0"
$ExternalIdField = "LDGCRM_External_ID__c"
$WaitMinutes = 30

# Child and junction objects must be deleted before parent objects.
$Objects = @(
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

$Timestamp = Start-ScriptLog -Category "cleanup" -ScriptName "cleanup-gsa-peo"
$OutputDirectory = Join-Path (Get-LogDirectory -Category "cleanup") "sandbox-cleanup-$Timestamp"

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

# ============================================================
# START
# ============================================================

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " GSA PEO SANDBOX DATA CLEANUP" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Target org alias:  $OrgAlias"
Write-Host "API version:       $ApiVersion"
Write-Host "External ID field: $ExternalIdField"
Write-Host "Delete mode:       HARD DELETE" -ForegroundColor Red
Write-Host ""

# Confirm that Salesforce CLI is installed.
Write-Host "Checking Salesforce CLI..." -ForegroundColor Cyan

Invoke-SalesforceCli -Arguments @(
    "--version"
)

# Display the hardcoded org so the operator can visually inspect it.
Write-Host ""
Write-Host "Checking the hardcoded target org..." -ForegroundColor Cyan

Invoke-SalesforceCli -Arguments @(
    "org", "display",
    "--target-org", $OrgAlias
)

# ============================================================
# PREFLIGHT RECORD COUNTS
# ============================================================

Write-Host ""
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

if ($TotalRecords -eq 0) {
    Write-Host ""
    Write-Host "No matching records were found. Nothing was deleted." `
        -ForegroundColor Green
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

$Results = @()

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

}
finally {
    Stop-ScriptLog
}