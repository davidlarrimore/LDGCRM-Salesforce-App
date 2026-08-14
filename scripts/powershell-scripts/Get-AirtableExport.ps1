#Requires -Version 5.1

<#
    Pulls current data directly from the Airtable REST API for every table in
    the Login.gov migration base, replacing the manual "download the export
    zip" step with a repeatable, scriptable one. Preserves linked-record
    fields as real JSON arrays instead of comma-joined CSV strings.

    Writes one JSON file per table directly to data/airtable-exports/,
    overwriting the previous pull each run -- this is meant to reflect
    current Airtable state, not accumulate a history of past pulls. A
    timestamped transcript log (record counts, any failures) still lands in
    logs/data-migration/ each run via Common.ps1, so run history isn't lost.

    Requires AIRTABLE_API_KEY (a Personal Access Token, e.g. "pat...") and
    AIRTABLE_BASE_ID (e.g. "app...") in the repo-root .env (copy .env.example
    to get started), or already set as environment variables. The token
    needs the data.records:read scope and must be granted access to this
    base in the Airtable Builder hub.
#>

param(
    # Subset of table labels (see $DefaultTables below) to pull; defaults to all.
    [string[]]$Tables,

    # Overrides AIRTABLE_BASE_ID from .env / the environment.
    [string]$BaseId
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
Import-DotEnv

# ============================================================
# CONFIGURATION
# ============================================================

$ApiToken = $env:AIRTABLE_API_KEY

if (-not $BaseId) {
    $BaseId = $env:AIRTABLE_BASE_ID
}

# One entry per Airtable table this migration reads from, keyed by table ID
# (not name) so a rename in Airtable doesn't silently break the pull the way
# it just did for "Partners" -- table names ARE editable in Airtable, IDs
# aren't. IDs captured via GET /v0/meta/bases/{base}/tables on 2026-08-12.
# Label matches the "Airtable table" column in CLAUDE.md's "Airtable ->
# Salesforce mapping" section, which is what drives the output filenames
# below -- it can differ from Airtable's current display name (e.g. "Partner
# Accounts" here is the Airtable table currently named "Partners").
$DefaultTables = @(
    [PSCustomObject]@{ Label = "Accounts"; TableId = "tbl0ZQdw6VfSOJ3lc" },
    [PSCustomObject]@{ Label = "Partner Accounts"; TableId = "tblmnsGxhrtPDmUOc" },
    [PSCustomObject]@{ Label = "Applications"; TableId = "tbl6oSxRSNMgxlPOv" },
    [PSCustomObject]@{ Label = "Contacts"; TableId = "tbl7TmpbaVsM4BoWX" },
    [PSCustomObject]@{ Label = "Opportunities"; TableId = "tblLK76R3rOsY7Bm0" },
    [PSCustomObject]@{ Label = "Opportunity Contacts"; TableId = "tbl6tVFthvVrdpNbf" },
    [PSCustomObject]@{ Label = "Impediments"; TableId = "tbl8j1PTFBUBAMcyq" },
    [PSCustomObject]@{ Label = "Market Segments"; TableId = "tblu0YYt8ffuWZ2ef" },
    [PSCustomObject]@{ Label = "Meetings"; TableId = "tblGEHJ83qdnLEc6M" },
    [PSCustomObject]@{ Label = "Issuer Strings"; TableId = "tbl8XAxD4G5uBEPMk" }
)

if ($Tables -and $Tables.Count -gt 0) {
    $SelectedTables = $DefaultTables | Where-Object { $_.Label -in $Tables }

    $UnknownLabels = $Tables | Where-Object { $_ -notin $DefaultTables.Label }

    if ($UnknownLabels) {
        Write-Host "Unknown table label(s): $($UnknownLabels -join ', ')" -ForegroundColor Red
        Write-Host "Valid labels: $($DefaultTables.Label -join ', ')" -ForegroundColor Yellow
        exit 1
    }
}
else {
    $SelectedTables = $DefaultTables
}

$PageSize = 100
$RequestDelayMs = 250 # keeps requests comfortably under Airtable's 5 req/sec/base limit
$MaxRetries = 5

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Get-AirtableExport"
$OutputDirectory = Join-Path (Get-LdgcrmRoot) "data\airtable-exports"
$SummaryFile = Join-Path (Get-LogDirectory -Category "data-migration") "pull-summary-$Timestamp.csv"

# ============================================================
# FUNCTIONS
# ============================================================

function Invoke-AirtableRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $Attempt = 0

    while ($true) {
        $Attempt++

        try {
            return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
        }
        catch {
            $StatusCode = $null

            if ($_.Exception.Response) {
                $StatusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($StatusCode -eq 429 -and $Attempt -lt $MaxRetries) {
                Write-Host "Rate limited by Airtable. Waiting 30s before retry $Attempt/$MaxRetries..." -ForegroundColor Yellow
                Start-Sleep -Seconds 30
                continue
            }

            if ($StatusCode -eq 401 -or $StatusCode -eq 403) {
                throw "Airtable rejected the request ($StatusCode). Airtable returns 403 both when the token lacks access and when the table ID doesn't exist in this base -- check that AIRTABLE_API_KEY is a valid Personal Access Token with the data.records:read scope and access to base $BaseId, and that the table ID is still current (re-run the schema.bases:read metadata lookup if a table was recently added/removed)."
            }

            if ($StatusCode -eq 404) {
                throw "Airtable returned 404 for this table. Check that AIRTABLE_BASE_ID is correct."
            }

            throw
        }
    }
}

function Get-AirtableTableRecords {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableId
    )

    $Headers = @{ Authorization = "Bearer $ApiToken" }
    $EncodedTable = [uri]::EscapeDataString($TableId)
    $AllRecords = [System.Collections.Generic.List[object]]::new()
    $Offset = $null

    do {
        $Uri = "https://api.airtable.com/v0/$BaseId/$EncodedTable`?pageSize=$PageSize"

        if ($Offset) {
            $Uri += "&offset=$Offset"
        }

        $Response = Invoke-AirtableRequest -Uri $Uri -Headers $Headers

        foreach ($Record in $Response.records) {
            $AllRecords.Add($Record)
        }

        $Offset = $Response.offset

        if ($Offset) {
            Start-Sleep -Milliseconds $RequestDelayMs
        }
    } while ($Offset)

    return $AllRecords
}

# ============================================================
# START
# ============================================================

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " AIRTABLE DATA PULL" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Base ID: $BaseId"
Write-Host "Tables:  $($SelectedTables.Label -join ', ')"
Write-Host ""

if ([string]::IsNullOrWhiteSpace($ApiToken)) {
    Write-Host "AIRTABLE_API_KEY is not set." -ForegroundColor Red
    Write-Host "Add it to the repo-root .env as a Personal Access Token, e.g.:" -ForegroundColor Yellow
    Write-Host "  AIRTABLE_API_KEY=pat..." -ForegroundColor Yellow
    exit 1
}

if ([string]::IsNullOrWhiteSpace($BaseId)) {
    Write-Host "AIRTABLE_BASE_ID is not set." -ForegroundColor Red
    Write-Host "Add it to the repo-root .env, or pass -BaseId, e.g.:" -ForegroundColor Yellow
    Write-Host "  AIRTABLE_BASE_ID=app..." -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$Results = @()

foreach ($Table in $SelectedTables) {
    Write-Host "------------------------------------------------------------"
    Write-Host "Pulling $($Table.Label)..." -ForegroundColor Cyan

    try {
        $Records = Get-AirtableTableRecords -TableId $Table.TableId

        $OutputFile = Join-Path $OutputDirectory "$($Table.Label).json"
        $Records | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputFile -Encoding UTF8

        Write-Host "$($Records.Count) records -> $OutputFile" -ForegroundColor Green

        $Results += [PSCustomObject]@{
            Table       = $Table.Label
            RecordCount = $Records.Count
            Status      = "Completed"
        }
    }
    catch {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red

        $Results += [PSCustomObject]@{
            Table       = $Table.Label
            RecordCount = 0
            Status      = "FAILED"
        }
    }
}

# ============================================================
# SUMMARY
# ============================================================

$Results | Export-Csv -LiteralPath $SummaryFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " PULL COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

$Results | Format-Table -AutoSize

Write-Host "Output directory:" -ForegroundColor Cyan
Write-Host $OutputDirectory
Write-Host "Summary file:" -ForegroundColor Cyan
Write-Host $SummaryFile

if ($Results | Where-Object { $_.Status -eq "FAILED" }) {
    exit 1
}

}
finally {
    Stop-ScriptLog
}
