#Requires -Version 5.1

<#
    Takes a RETAINED backup of the Airtable base: runs the bundle's normal pull,
    then zips the result into dist/ with a timestamp so it survives the next pull.

    WHY THIS EXISTS
      scripts/powershell-scripts/Get-AirtableExport.ps1 writes one JSON file per
      table into scripts/data/airtable-exports/ and OVERWRITES that folder every
      run. That is deliberate - it is a current-state mirror of the base, and the
      standing rule is to load the latest pull rather than an older copy. But it
      means there is no point-in-time copy of the base anywhere, and "copy the
      folder somewhere after a pull" (which is what the export script tells the
      operator to do) is a manual step nobody performs consistently.

      This wraps the same pull and does that copy as an archive: one zip per run,
      named for the moment it was taken, in a folder git ignores.

    WHY IT LIVES IN tools/ AND NOT IN THE BUNDLE
      It writes to dist/ at the REPOSITORY root - above the bundle root - which
      nothing in scripts/ may resolve (see Common.Tools.ps1). The pull itself is
      bundle work and stays there; this only wraps it.

    IT ALWAYS PULLS THE WHOLE BASE
      There is deliberately no -MigrationOnly / -Tables pass-through. A zip
      called "airtable-backup" holding 10 of 22 tables is worse than no zip: the
      shortfall is invisible from the filename, and this archive is the copy
      someone reaches for precisely when the live base can no longer answer the
      question. Use Get-AirtableExport.ps1 directly to refresh a subset.

    ⚠ THE ZIP CONTAINS PII. Every applicant name, email and partner note in the
      base is in it. dist/ is gitignored, and this checks that with git rather
      than assuming it. Treat the file the way you would treat scripts/data/:
      never commit it, never attach it to a ticket.

    Run with -SkipPull to archive the export folder exactly as it stands (when a
    pull has just finished, or when the token is unavailable).
#>

param(
    # Zip the current contents of data/airtable-exports/ without re-pulling.
    # The staleness report below still runs, so an old pull cannot be archived
    # as though it were taken now without saying so.
    [switch]$SkipPull,

    # Where to write the zip. Defaults to dist/airtable-backup-<timestamp>.zip
    # at the repo root.
    [string]$OutputPath = "",

    # Skip the pass that reads the finished archive back. Exists so a failure in
    # the check can be told apart from a failure in the build; no other use.
    [switch]$SkipVerification
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.Tools.ps1")
. (Join-Path $PSScriptRoot "..\scripts\powershell-scripts\Common.ps1")
# For Get-LdgcrmAirtableTableCatalog - the same list the pull works from, so
# "every table arrived" is checked against one definition rather than two.
. (Join-Path $PSScriptRoot "..\scripts\powershell-scripts\Common.DataMigration.ps1")

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot = Get-RepoRoot
$Bundle = Get-LdgcrmBundleRoot
$ExportDirectory = Join-Path $Bundle "data\airtable-exports"
$ExportScript = Join-Path $Bundle "powershell-scripts\Get-AirtableExport.ps1"

# The zip carries the run's timestamp, so it can be traced back to the
# transcript in logs/tools/ that recorded how it was produced.
$Timestamp = Start-ToolLog -ScriptName "Backup-AirtableBase"
$RunDirectory = $env:LDGCRM_RUN_DIRECTORY

try {

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " AIRTABLE BASE BACKUP" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Export folder  $ExportDirectory"
Write-Host "  Run log        $RunDirectory"
Write-Host ""

# ============================================================
# PULL
# ============================================================
# A child process, matching how Invoke-FullMigrationLoad runs its steps: it
# gives a clean exit code, and $env:LDGCRM_RUN_DIRECTORY (set by Start-ToolLog)
# is inherited, so the pull's own transcript and pull-summary CSV land in this
# run's folder instead of starting a second one.

$PullStart = Get-Date

if ($SkipPull) {
    Write-Host "-SkipPull: archiving the export folder as it stands." -ForegroundColor Yellow
}
else {
    if (-not (Test-Path -LiteralPath $ExportScript)) {
        throw "Export script not found: $ExportScript"
    }

    Write-Host "Pulling every table in the base..." -ForegroundColor Cyan
    Write-Host ""

    # Out-Host, not a bare call: a child process writes stdout to the PIPELINE,
    # so without it every line the pull printed would be returned as output here.
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ExportScript | Out-Host

    if ($LASTEXITCODE -ne 0) {
        # The pull exits non-zero only when a table FAILED, which means the
        # folder now holds a mix of fresh and stale files. Archiving that would
        # produce a backup whose filename claims a date its contents do not
        # all have.
        throw "The Airtable pull failed (exit $LASTEXITCODE). No archive was written - see the transcript above for which table(s) failed."
    }
}

if (-not (Test-Path -LiteralPath $ExportDirectory)) {
    throw "Export folder not found: $ExportDirectory"
}

# ============================================================
# INVENTORY
# ============================================================

$Catalog = @(Get-LdgcrmAirtableTableCatalog)
$CatalogByLabel = @{}
foreach ($Table in $Catalog) { $CatalogByLabel[$Table.Label] = $Table }

$Files = @(Get-ChildItem -LiteralPath $ExportDirectory -File -Filter "*.json" | Sort-Object Name)

if ($Files.Count -eq 0) {
    throw "No JSON files in $ExportDirectory - there is nothing to back up."
}

$Manifest = [System.Collections.Generic.List[object]]::new()

foreach ($File in $Files) {
    $Label = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)

    $Purpose = "Unlisted"   # in the folder but not in the catalog - see below
    if ($CatalogByLabel.ContainsKey($Label)) { $Purpose = $CatalogByLabel[$Label].Purpose }

    # -Encoding UTF8 is not optional: without it PS 5.1 decodes a BOM-less file
    # as Windows-1252 and every non-ASCII character in the base comes back wrong.
    $RecordCount = $null

    try {
        $Content = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if (-not [string]::IsNullOrWhiteSpace($Content)) {
            # ASSIGN, then count. PS 5.1's ConvertFrom-Json writes a JSON array
            # to the pipeline as ONE object rather than enumerating it, so
            # @($Content | ConvertFrom-Json).Count is 1 for every table however
            # many records it holds - it counts the array, not its contents.
            # It reads as a plausible number, which is what makes it dangerous:
            # the first run of this script reported "22 tables, 22 records".
            # Assigning first gives @() a real array to measure, and still
            # yields 1 (not $null) for a one-record table.
            $Parsed = ConvertFrom-Json $Content
            $RecordCount = @($Parsed).Count
        }
        else {
            $RecordCount = 0
        }
    }
    catch {
        # A file that will not parse is the one thing a backup must not hide.
        Write-Host "  UNPARSEABLE: $($File.Name) - $($_.Exception.Message)" -ForegroundColor Red
    }

    $Manifest.Add([PSCustomObject]@{
        Table       = $Label
        Purpose     = $Purpose
        RecordCount = $RecordCount
        Bytes       = $File.Length
        ModifiedUtc = $File.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    })
}

$Unparseable = @($Manifest | Where-Object { $null -eq $_.RecordCount })

if ($Unparseable.Count -gt 0) {
    throw "$($Unparseable.Count) export file(s) could not be parsed as JSON. No archive was written - a backup that cannot be read back is not a backup."
}

# --- every catalogued table actually present? -------------------------------
# The pull reports a table it failed to write, but only for tables it knows
# about; this is the other half - a file the catalog expects that is not on
# disk at all, which -SkipPull can produce trivially.
$PresentLabels = @($Manifest.Table)
$MissingTables = @($Catalog | Where-Object { $_.Label -notin $PresentLabels })

if ($MissingTables.Count -gt 0) {
    Write-Host ""
    Write-Host "  WARNING: $($MissingTables.Count) catalogued table(s) have no file in the export folder:" -ForegroundColor Red
    foreach ($Table in $MissingTables) {
        Write-Host ("      {0}  ({1})" -f $Table.Label, $Table.Purpose) -ForegroundColor Yellow
    }
}

# --- files the catalog does not know about ----------------------------------
# Archived anyway - this backs up the FOLDER - but named, because the usual
# cause is a table dropped from the catalog whose old pull is still sitting
# there, and that file's contents are as old as the day it was removed.
$Unlisted = @($Manifest | Where-Object { $_.Purpose -eq "Unlisted" })

if ($Unlisted.Count -gt 0) {
    Write-Host ""
    Write-Host "  For information - $($Unlisted.Count) file(s) in the folder are not in the table catalog." -ForegroundColor DarkGray
    Write-Host "  They are included in the archive, but nothing refreshes them:" -ForegroundColor DarkGray
    foreach ($Item in $Unlisted) {
        Write-Host ("      {0}   last written {1}" -f $Item.Table, $Item.ModifiedUtc) -ForegroundColor DarkGray
    }
}

# --- staleness --------------------------------------------------------------
# The single question this archive's filename implies an answer to: is
# everything in it actually from the moment in that filename? After a pull,
# anything older than the pull started was not refreshed by it.
$Reference = if ($SkipPull) { Get-Date } else { $PullStart }
$Stale = @($Files | Where-Object { $_.LastWriteTime -lt $Reference })

if ($Stale.Count -gt 0) {
    $Oldest = ($Stale | Sort-Object LastWriteTime | Select-Object -First 1)
    $AgeDays = [Math]::Round(((Get-Date) - $Oldest.LastWriteTime).TotalDays, 1)

    Write-Host ""
    if ($SkipPull) {
        Write-Host ("  -SkipPull: $($Stale.Count) of $($Files.Count) file(s) predate this run; oldest is $AgeDays day(s) old ($($Oldest.Name)).") -ForegroundColor Yellow
        Write-Host "  The archive is a copy of that pull, not of the base as it is now." -ForegroundColor Yellow
    }
    else {
        Write-Host "  WARNING: $($Stale.Count) file(s) were NOT refreshed by this pull:" -ForegroundColor Red
        foreach ($File in $Stale) {
            Write-Host ("      {0}   last written {1:yyyy-MM-dd HH:mm}" -f $File.Name, $File.LastWriteTime) -ForegroundColor Yellow
        }
    }
}

# ============================================================
# MANIFEST
# ============================================================
# Written into the run folder and then into the archive, so the zip can be
# read for what it holds without unpacking every file - and so a future reader
# can tell an empty table from a table that failed to pull.

$ManifestPath = Join-Path $RunDirectory "backup-manifest.csv"
$Manifest | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding UTF8

$ReadmePath = Join-Path $RunDirectory "README.txt"
$ReadmeLines = @(
    "Login.gov CRM migration - Airtable base backup"
    "Taken: $Timestamp (local time on the machine that ran it)"
    "Source: Airtable base, pulled via scripts/powershell-scripts/Get-AirtableExport.ps1"
    ""
    "airtable-exports/  one JSON file per Airtable table, each a top-level array"
    "                   of { id, createdTime, fields } records. Linked-record"
    "                   fields are real arrays of rec... IDs."
    "backup-manifest.csv  table, purpose, record count, size, last modified."
    ""
    "CONTAINS PII. Login.gov applicant and partner data. Do not commit this"
    "archive to a repository, attach it to a ticket, or upload it to a shared"
    "drive without checking where that drive is."
    ""
    "To use it: extract airtable-exports/ over scripts/data/airtable-exports/."
    "Note the pipeline's standing rule is to load the LATEST pull - reach for"
    "this copy to answer what the base held on this date, not to run a load."
)
$ReadmeLines | Set-Content -LiteralPath $ReadmePath -Encoding UTF8

# ============================================================
# BUILD
# ============================================================

if (-not $OutputPath) {
    $DistDirectory = Join-Path $RepoRoot "dist"

    if (-not (Test-Path -LiteralPath $DistDirectory)) {
        New-Item -ItemType Directory -Path $DistDirectory -Force | Out-Null
    }

    $OutputPath = Join-Path $DistDirectory "airtable-backup-$Timestamp.zip"
}
else {
    $Parent = Split-Path -Parent $OutputPath

    if ($Parent -and -not (Test-Path -LiteralPath $Parent)) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }
}

if (Test-Path -LiteralPath $OutputPath) {
    # Only reachable via -OutputPath: the default name carries a to-the-second
    # timestamp, so it never collides with an earlier backup.
    throw "$OutputPath already exists. Backups are never overwritten - pass a different -OutputPath."
}

# Everything sits under airtable-exports/ inside the zip so extracting it
# reproduces the folder it came from rather than 22 loose JSON files.
$RootFolder = "airtable-exports"

$Archive = [System.IO.Compression.ZipFile]::Open($OutputPath, [System.IO.Compression.ZipArchiveMode]::Create)

try {
    foreach ($File in $Files) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $Archive, $File.FullName, "$RootFolder/$($File.Name)") | Out-Null
    }

    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $Archive, $ManifestPath, "backup-manifest.csv") | Out-Null
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $Archive, $ReadmePath, "README.txt") | Out-Null
}
finally {
    $Archive.Dispose()
}

$SizeMb = [Math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1MB, 2)

Write-Host ""
Write-Host "Written: $OutputPath ($SizeMb MB)" -ForegroundColor Green

# ============================================================
# VERIFY
# ============================================================
# Reads the FINISHED archive rather than trusting the list built above, the
# same way Export-OpsBundle.ps1 does: the build and the check can only agree by
# both being right, and a backup is the one artifact whose defects surface
# only when it is already the last copy of something.

if (-not $SkipVerification) {
    $Problems = [System.Collections.Generic.List[string]]::new()
    $Verify = [System.IO.Compression.ZipFile]::OpenRead($OutputPath)

    try {
        $Entries = @($Verify.Entries | ForEach-Object { $_.FullName })

        foreach ($File in $Files) {
            $Expected = "$RootFolder/$($File.Name)"

            if ($Entries -notcontains $Expected) {
                $Problems.Add("MISSING from archive: $Expected")
                continue
            }

            $Entry = $Verify.GetEntry($Expected)

            if ($Entry.Length -ne $File.Length) {
                $Problems.Add("size mismatch: $Expected ($($Entry.Length) bytes in archive, $($File.Length) on disk)")
            }
        }

        foreach ($Required in @("backup-manifest.csv", "README.txt")) {
            if ($Entries -notcontains $Required) { $Problems.Add("MISSING required file: $Required") }
        }

        Write-Host "Verification: $($Entries.Count) entries read back from the archive." -ForegroundColor Cyan
    }
    finally {
        $Verify.Dispose()
    }

    if ($Problems.Count -gt 0) {
        Write-Host ""
        foreach ($Problem in $Problems) { Write-Host "  $Problem" -ForegroundColor Red }
        Remove-Item -LiteralPath $OutputPath -Force
        throw "Backup verification FAILED ($($Problems.Count) problem(s)). The archive was deleted rather than left on disk to be trusted."
    }

    Write-Host "  Every export file is present and the right size." -ForegroundColor Green
}
else {
    Write-Host "Verification skipped (-SkipVerification)." -ForegroundColor Yellow
}

# ============================================================
# IS IT SOMEWHERE GIT WILL COMMIT IT?
# ============================================================
# dist/ is ignored by the repo-root .gitignore, but -OutputPath can point
# anywhere, and this file is PII. Asked of git rather than read off the ignore
# file, because a later negation can re-admit what an earlier rule excluded.
# Never fatal: the archive is already written and correct, and git may not be
# on PATH or the path may be outside any repository.

$IgnoreState = "unknown"

try {
    & git -C $RepoRoot check-ignore --quiet -- $OutputPath

    if ($LASTEXITCODE -eq 0) { $IgnoreState = "ignored" }
    elseif ($LASTEXITCODE -eq 1) { $IgnoreState = "tracked" }
}
catch {
    $IgnoreState = "unknown"
}

Write-Host ""
switch ($IgnoreState) {
    "ignored" { Write-Host "  git ignores this path - it cannot be committed by accident." -ForegroundColor Green }
    "tracked" {
        Write-Host "  WARNING: git does NOT ignore this path." -ForegroundColor Red
        Write-Host "  The archive contains Login.gov applicant PII. Move it out of the working" -ForegroundColor Yellow
        Write-Host "  tree, or add its folder to .gitignore, before your next commit." -ForegroundColor Yellow
    }
    default { Write-Host "  Could not ask git whether this path is ignored - check it yourself before committing." -ForegroundColor DarkGray }
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " BACKUP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

$Manifest | Format-Table Table, Purpose, RecordCount, ModifiedUtc -AutoSize

Write-Host ("Tables: {0}   Records: {1:N0}   Archive: {2} MB" -f `
    $Manifest.Count, (($Manifest | Measure-Object -Property RecordCount -Sum).Sum), $SizeMb)
Write-Host ""
Write-Host "Archive:" -ForegroundColor Cyan
Write-Host $OutputPath
Write-Host "Run log:" -ForegroundColor Cyan
Write-Host $RunDirectory

if ($MissingTables.Count -gt 0) {
    Write-Host ""
    Write-Host "$($MissingTables.Count) catalogued table(s) are absent from this backup - see above." -ForegroundColor Red
    exit 1
}

}
finally {
    Stop-ToolLog
}
