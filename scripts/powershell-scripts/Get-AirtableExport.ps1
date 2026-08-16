#Requires -Version 5.1

<#
    Pulls current data directly from the Airtable REST API for every table in
    the Login.gov migration base, replacing the manual "download the export
    zip" step with a repeatable, scriptable one. Preserves linked-record
    fields as real JSON arrays instead of comma-joined CSV strings.

    THIS IS A BACKUP OF THE BASE, NOT JUST A MIGRATION INPUT (widened
    2026-08-16). It pulls ALL 22 tables, not only the 10 the migration reads.
    Ten tables feed the transforms; the other twelve are carried purely so the
    pull is a faithful copy of the base. Both kinds are marked in
    $DefaultTables below, and the migration ones are the only entries whose
    Label may not change -- the transforms open <Label>.json by name.

    Writes one JSON file per table directly to data/airtable-exports/,
    overwriting the previous pull each run -- this is meant to reflect
    current Airtable state, not accumulate a history of past pulls. A
    timestamped transcript log (record counts, any failures) still lands in
    logs/data-migration/ each run via Common.ps1, so run history isn't lost.
    If you want a retained backup, copy the folder somewhere after a pull;
    the next pull overwrites it.

    COVERAGE CHECK. Because the table list is hardcoded (see the comment on
    $DefaultTables), a table ADDED to the base after this script was last
    edited would simply never be backed up, and nothing would say so. After
    every pull the script asks Airtable what tables actually exist and reports
    any it did not pull, plus any it holds that the base no longer has. That
    check needs the schema.bases:read scope; without it the pull still
    succeeds and the check reports that it could not run. -SkipCoverageCheck
    turns it off.

    Requires AIRTABLE_API_KEY (a Personal Access Token, e.g. "pat...") and
    AIRTABLE_BASE_ID (e.g. "app...") in the bundle's .env (copy .env.example
    to get started), or already set as environment variables. The token
    needs the data.records:read scope, ideally schema.bases:read as well (see
    the coverage check above), and must be granted access to this base in the
    Airtable Builder hub.
#>

param(
    # Subset of table labels (see $DefaultTables below) to pull; defaults to all.
    [string[]]$Tables,

    # Pull only the ten tables the migration transforms actually read, skipping
    # the backup-only ones. Use it when you are about to run a load and want
    # the inputs refreshed without waiting for the rest of the base.
    [switch]$MigrationOnly,

    # Skip the post-pull check that asks Airtable what tables exist. Only
    # useful when the token lacks schema.bases:read and the warning is noise.
    [switch]$SkipCoverageCheck,

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

# One entry per Airtable table, keyed by table ID (not name) so a rename in
# Airtable doesn't silently break the pull the way it just did for "Partners"
# -- table names ARE editable in Airtable, IDs aren't. Migration IDs captured
# via GET /v0/meta/bases/{base}/tables on 2026-08-12, backup-only ones on
# 2026-08-16 from the same endpoint.
#
# Label drives the output filename. For Purpose="Migration" it matches the
# "Airtable table" column in CLAUDE.md's "Airtable -> Salesforce mapping"
# section and CANNOT be changed casually -- Get-AirtableTablePath opens
# <Label>.json by that exact string, so a transform breaks the moment it moves.
# It can differ from Airtable's current display name: "Partner Accounts" here
# is the table Airtable now calls "Partners".
#
# Purpose="Backup" tables are pulled ONLY so this is a real copy of the base.
# Nothing reads them, so their Label just tracks the Airtable name. Adding one
# costs a file; leaving one out costs a table nobody notices is missing --
# which is what the coverage check at the end exists to catch.
$DefaultTables = @(
    # --- Read by the migration transforms. Labels are load-bearing. ---
    [PSCustomObject]@{ Label = "Accounts"; TableId = "tbl0ZQdw6VfSOJ3lc"; Purpose = "Migration" },
    [PSCustomObject]@{ Label = "Partner Accounts"; TableId = "tblmnsGxhrtPDmUOc"; Purpose = "Migration" },
    [PSCustomObject]@{ Label = "Applications"; TableId = "tbl6oSxRSNMgxlPOv"; Purpose = "Migration" },
    [PSCustomObject]@{ Label = "Contacts"; TableId = "tbl7TmpbaVsM4BoWX"; Purpose = "Migration" },
    [PSCustomObject]@{ Label = "Opportunities"; TableId = "tblLK76R3rOsY7Bm0"; Purpose = "Migration" },
    [PSCustomObject]@{ Label = "Opportunity Contacts"; TableId = "tbl6tVFthvVrdpNbf"; Purpose = "Migration" },
    [PSCustomObject]@{ Label = "Impediments"; TableId = "tbl8j1PTFBUBAMcyq"; Purpose = "Migration" },
    [PSCustomObject]@{ Label = "Market Segments"; TableId = "tblu0YYt8ffuWZ2ef"; Purpose = "Migration" },
    [PSCustomObject]@{ Label = "Meetings"; TableId = "tblGEHJ83qdnLEc6M"; Purpose = "Migration" },
    [PSCustomObject]@{ Label = "Issuer Strings"; TableId = "tbl8XAxD4G5uBEPMk"; Purpose = "Migration" },

    # --- Backup only. Nothing in the pipeline reads these. ---
    [PSCustomObject]@{ Label = "Programs"; TableId = "tblCgazDmq1KQiJVx"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "Organizations"; TableId = "tblyepquUOM6q7Fu7"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "Opportunity Status Changes"; TableId = "tblB0CY1Ojv7Kxw1L"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "Market Segment Revenue"; TableId = "tblKItp6Zf6TjCy1A"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "Agreement Actions"; TableId = "tbln1L5HKwhADiVQE"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "Data Sharing Requests"; TableId = "tblQQrMPUhNy8keT4"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "End User Feedback"; TableId = "tblzJ3ATL03ASc9Kg"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "Account Health Status Change"; TableId = "tbliYD6IcL0ZikKvv"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "Initiatives"; TableId = "tblkOtvH8vF4i7H3P"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "Pod Metrics Entries"; TableId = "tblAWJ1BFJkOdSo7a"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "Resources"; TableId = "tblJVxo5Ki4Ch3vRd"; Purpose = "Backup" },
    [PSCustomObject]@{ Label = "OOO"; TableId = "tblAGArSaC563IsUy"; Purpose = "Backup" }
)

if ($Tables -and $Tables.Count -gt 0) {
    $SelectedTables = @($DefaultTables | Where-Object { $_.Label -in $Tables })

    $UnknownLabels = @($Tables | Where-Object { $_ -notin $DefaultTables.Label })

    if ($UnknownLabels.Count -gt 0) {
        Write-Host "Unknown table label(s): $($UnknownLabels -join ', ')" -ForegroundColor Red
        Write-Host "Valid labels: $($DefaultTables.Label -join ', ')" -ForegroundColor Yellow
        exit 1
    }

    if ($MigrationOnly) {
        Write-Host "-MigrationOnly is ignored when -Tables names the tables explicitly." -ForegroundColor Yellow
    }
}
elseif ($MigrationOnly) {
    $SelectedTables = @($DefaultTables | Where-Object { $_.Purpose -eq "Migration" })
}
else {
    $SelectedTables = @($DefaultTables)
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

function Get-AirtableBaseTables {
    <#
        Asks Airtable what tables the base actually contains, so the pull can
        report anything the hardcoded map above has missed.

        Returns an array of the base's tables, or $null if the answer could
        not be obtained -- which is NOT treated as a failure. This needs the
        schema.bases:read scope, separate from data.records:read, so a token
        that pulls every record perfectly well may still be unable to list
        tables. A backup that refuses to run because it cannot self-check
        would be worse than one that says "I could not self-check".

        Contract: returns a plain array; the caller wraps in @().
    #>

    $Headers = @{ Authorization = "Bearer $ApiToken" }
    $Uri = "https://api.airtable.com/v0/meta/bases/$BaseId/tables"

    try {
        $Response = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
        return $Response.tables
    }
    catch {
        $StatusCode = $null

        if ($_.Exception.Response) {
            $StatusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($StatusCode -eq 401 -or $StatusCode -eq 403) {
            Write-Host "  Could not list the base's tables ($StatusCode). The token most likely lacks" -ForegroundColor Yellow
            Write-Host "  the schema.bases:read scope. The pull itself was unaffected." -ForegroundColor Yellow
        }
        else {
            Write-Host "  Could not list the base's tables: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        return $null
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
$MigrationCount = @($SelectedTables | Where-Object { $_.Purpose -eq "Migration" }).Count
$BackupCount = @($SelectedTables | Where-Object { $_.Purpose -eq "Backup" }).Count

Write-Host "Base ID: $BaseId"
Write-Host ("Pulling: {0} table(s) - {1} read by the migration, {2} backup-only" -f $SelectedTables.Count, $MigrationCount, $BackupCount)
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
            Purpose     = $Table.Purpose
            RecordCount = $Records.Count
            Status      = "Completed"
        }
    }
    catch {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red

        $Results += [PSCustomObject]@{
            Table       = $Table.Label
            Purpose     = $Table.Purpose
            RecordCount = 0
            Status      = "FAILED"
        }
    }
}

# ============================================================
# COVERAGE CHECK
#
# The table map above is hardcoded on purpose (IDs beat names), and the cost
# of that is a table added to the base later is simply never pulled. Nothing
# errors, no count looks wrong, and the backup is quietly incomplete -- the
# same shape of failure as an inactive Flow. So ask the base what it holds and
# compare. Reported, never fatal: this runs AFTER the data is safely written,
# and a self-check that cannot run is not a reason to fail a good pull.
# ============================================================

$Uncovered = @()

if (-not $SkipCoverageCheck) {
    Write-Host ""
    Write-Host "------------------------------------------------------------"
    Write-Host "Checking the pull covers every table in the base..." -ForegroundColor Cyan

    $BaseTables = @(Get-AirtableBaseTables)

    if ($BaseTables.Count -gt 0) {
        $KnownIds = @{}
        foreach ($T in $DefaultTables) { $KnownIds[$T.TableId] = $T.Label }

        $Uncovered = @($BaseTables | Where-Object { -not $KnownIds.ContainsKey($_.id) })

        $BaseIds = @{}
        foreach ($T in $BaseTables) { $BaseIds[$T.id] = $T.name }

        $Vanished = @($DefaultTables | Where-Object { -not $BaseIds.ContainsKey($_.TableId) })

        Write-Host ("  Base holds {0} table(s); this script knows {1}." -f $BaseTables.Count, $DefaultTables.Count)

        if ($Uncovered.Count -gt 0) {
            Write-Host ""
            Write-Host "  WARNING: $($Uncovered.Count) table(s) in the base are NOT backed up by this script." -ForegroundColor Red
            Write-Host "  Add them to `$DefaultTables to include them:" -ForegroundColor Yellow
            foreach ($T in $Uncovered) {
                Write-Host ("      [PSCustomObject]@{{ Label = `"{0}`"; TableId = `"{1}`"; Purpose = `"Backup`" }}," -f $T.name, $T.id) -ForegroundColor Yellow
            }
        }

        if ($Vanished.Count -gt 0) {
            Write-Host ""
            Write-Host "  WARNING: $($Vanished.Count) table(s) this script expects are no longer in the base." -ForegroundColor Red
            Write-Host "  They were deleted, or the token can no longer see them:" -ForegroundColor Yellow
            foreach ($T in $Vanished) {
                Write-Host ("      {0}  ({1})" -f $T.Label, $T.TableId) -ForegroundColor Yellow
            }
        }

        if ($Uncovered.Count -eq 0 -and $Vanished.Count -eq 0) {
            Write-Host "  Every table in the base is covered." -ForegroundColor Green
        }

        # A table renamed in Airtable is not a problem -- the pull is keyed on
        # ID -- but the operator should know the label here has drifted from
        # what they see in Airtable, or the next person will "fix" it.
        $Renamed = @()
        foreach ($T in $DefaultTables) {
            if ($BaseIds.ContainsKey($T.TableId) -and $BaseIds[$T.TableId] -ne $T.Label) {
                $Renamed += [PSCustomObject]@{ Label = $T.Label; AirtableName = $BaseIds[$T.TableId] }
            }
        }

        if ($Renamed.Count -gt 0) {
            Write-Host ""
            Write-Host "  For information - label here differs from the Airtable name (pull is by ID, so this is harmless):" -ForegroundColor DarkGray
            foreach ($R in $Renamed) {
                Write-Host ("      {0,-30} is called '{1}' in Airtable" -f $R.Label, $R.AirtableName) -ForegroundColor DarkGray
            }
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

$Results | Format-Table Table, Purpose, RecordCount, Status -AutoSize

Write-Host ("Records pulled: {0:N0} across {1} table(s)." -f (($Results | Measure-Object -Property RecordCount -Sum).Sum, $Results.Count))
Write-Host ""
Write-Host "Output directory:" -ForegroundColor Cyan
Write-Host $OutputDirectory
Write-Host "Summary file:" -ForegroundColor Cyan
Write-Host $SummaryFile

# This folder is overwritten by the next pull. Say so here rather than only in
# the header comment, because the operator reading this line is the one who
# may have just run it intending to keep a copy.
Write-Host ""
Write-Host "The next pull OVERWRITES this folder. Copy it elsewhere to retain this snapshot." -ForegroundColor DarkGray

if ($Uncovered.Count -gt 0) {
    Write-Host ""
    Write-Host "$($Uncovered.Count) table(s) in the base were not backed up - see the coverage check above." -ForegroundColor Red
}

if ($Results | Where-Object { $_.Status -eq "FAILED" }) {
    exit 1
}

}
finally {
    Stop-ScriptLog
}
