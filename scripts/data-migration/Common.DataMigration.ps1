# Shared helpers for the Airtable -> Salesforce data-migration scripts
# (scripts/data-migration/Build-*.ps1). Dot-source both this file and
# scripts/common/Common.ps1 from any script in this category:
#   . (Join-Path $PSScriptRoot "..\common\Common.ps1")
#   . (Join-Path $PSScriptRoot "Common.DataMigration.ps1")
#
# Targets Windows PowerShell 5.1 (no PowerShell 7-only syntax: no ??, ?., ternary
# ?:, -AsHashtable, -Parallel, or multi-argument Join-Path).

function Get-AirtableExportPath {
    <#
        Resolves the path to a single table's pulled JSON export
        (data/airtable-exports/<Label>.json), as written by
        Get-AirtableExport.ps1. Does not read the file.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    return Join-Path (Join-Path (Get-RepoRoot) "data\airtable-exports") "$Label.json"
}

function Import-AirtableTable {
    <#
        Reads data/airtable-exports/<Label>.json and returns the array of
        Airtable records (each a PSCustomObject with .id, .createdTime,
        .fields). Throws a clear error pointing at Get-AirtableExport.ps1
        if the export hasn't been pulled yet.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $Path = Get-AirtableExportPath -Label $Label

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No Airtable export found for '$Label' at $Path. Run scripts/data-migration/Get-AirtableExport.ps1 first."
    }

    # PS 5.1's ConvertFrom-Json has no -Depth parameter (PS6+ only) but
    # defaults to a max depth of 100, well beyond these records' nesting.
    return @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-SalesforceLoadDirectory {
    <#
        Ensures/returns data/salesforce-loads/, where transform scripts
        write the CSVs staged for the Data Loader CLI. Gitignored under
        the same data/** rule as airtable-exports/ and mappings/.
    #>
    $LoadDir = Join-Path (Get-RepoRoot) "data\salesforce-loads"

    if (-not (Test-Path -LiteralPath $LoadDir)) {
        New-Item -ItemType Directory -Path $LoadDir -Force | Out-Null
    }

    return $LoadDir
}

function Export-DataLoaderCsv {
    <#
        Writes objects to CSV in a form the Data Loader CLI can read
        reliably: UTF-8 *without* a byte-order mark. PowerShell 5.1's
        Export-Csv -Encoding UTF8 always writes a BOM, which some Data
        Loader CLI versions choke on (a leading BOM gets treated as part
        of the first column header), so this writes manually instead.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($InputObject.Count -eq 0) {
        throw "Export-DataLoaderCsv: refusing to write an empty CSV to $Path (Data Loader needs at least a header row - pass an explicit empty-with-columns object if that's really intended)."
    }

    $CsvLines = $InputObject | ConvertTo-Csv -NoTypeInformation
    $Utf8NoBom = New-Object System.Text.UTF8Encoding $false

    [System.IO.File]::WriteAllLines($Path, $CsvLines, $Utf8NoBom)
}

function Invoke-SalesforceQuery {
    <#
        Runs a SOQL query via `sf data query --json` and returns the
        result's record array (empty array if none). Read-only - safe to
        call outside the sfdx-sandbox-ops confirmation gate, which only
        applies to writes/deletes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Soql,

        [Parameter(Mandatory = $true)]
        [string]$OrgAlias,

        [string]$ApiVersion = "67.0"
    )

    $RawResult = & sf data query `
        --target-org $OrgAlias `
        --api-version $ApiVersion `
        --query $Soql `
        --json

    if ($LASTEXITCODE -ne 0) {
        throw "Salesforce CLI query failed (exit $LASTEXITCODE): $Soql"
    }

    $JsonResult = $RawResult | ConvertFrom-Json

    if ($JsonResult.status -ne 0) {
        $ErrorMessage = $JsonResult.message

        if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $ErrorMessage = "Unknown Salesforce CLI error."
        }

        throw $ErrorMessage
    }

    if ($null -eq $JsonResult.result.records) {
        return @()
    }

    # CALLER CONTRACT: always wrap the call site in @(), e.g.
    #     $Rows = @(Invoke-SalesforceQuery -Soql ... -OrgAlias ...)
    # PowerShell unwraps a single-element array back to a bare scalar when a
    # function returns it through the output stream, so an unwrapped caller
    # doing $Rows.Count on a genuinely single-row result silently gets $null
    # (hit 2026-08-13 on a RecordType lookup that legitimately matched one row).
    #
    # This was first "fixed" with Write-Output -NoEnumerate, which traded one
    # failure mode for a worse one: -NoEnumerate emits the array as a SINGLE
    # object, so any caller following the idiomatic @() convention got a
    # nested 1-element array wrapping the real results - .Count == 1 no matter
    # how many rows came back, with no error. That silently reported "1 Partner
    # Account exists" against 74 real rows (caught 2026-08-13 only because the
    # number was obviously wrong). Returning normally + @() at every call site
    # is correct in all three cases (0 rows, 1 row, many) and is idempotent, so
    # it can't be double-applied by mistake.
    return $JsonResult.result.records
}
