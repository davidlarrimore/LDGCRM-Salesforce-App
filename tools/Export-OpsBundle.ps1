#Requires -Version 5.1

<#
    Packages scripts/ into the zip handed to the GSA Salesforce Operations team.

    WHAT THEY DO WITH IT
      Extract it into their own GitHub repository as a /scripts folder and run
      the migration out of it. Nothing else from this repository goes with it -
      not sfdx/, not the engineering docs, not tools/.

    WHAT THIS SCRIPT IS ACTUALLY FOR
      Not convenience - the exclusions. Three things in that folder must never
      leave this machine, and all three are easy to include by accident because
      they sit in the middle of a folder that is otherwise entirely shippable:

        .env                  the Airtable Personal Access Token.
        data/                 Airtable extracts, load-ready CSVs, and the
                              production Account export. Real partner and
                              applicant data.
        logs/                 every past run's transcripts and review CSVs,
                              which quote the records they are about.

      A hand-rolled "zip the scripts folder" gets all three wrong by default.
      This script excludes them by construction, then VERIFIES the result by
      reading the finished archive back and failing if anything unexpected is
      in it - because the cost of being wrong here is publishing PII to a
      repository this project does not control.

      .env.example IS included, and deliberately: it is the template operators
      copy to make their own .env, and it documents how to obtain a token. It
      contains no secret. So does the AIRTABLE_BASE_ID value, which is not one.

    FOLDER STRUCTURE IS PRESERVED, CONTENTS ARE NOT. data/ and logs/ ship as
    empty folders with their .gitkeep and README.md, so the pipeline can run
    without anyone creating directories by hand and so the READMEs explaining
    what belongs in them arrive with the folders they describe.

    Run -WhatIf first to see the file list without writing anything.
#>

param(
    # Where to write the zip. Defaults to dist/ at the repo root (gitignored).
    [string]$OutputPath = "",

    # Report what would be included and exit. Always do this first.
    [switch]$WhatIf,

    # Skip the post-build verification pass. There is no good reason to use
    # this; it exists so a failure in the check can be distinguished from a
    # failure in the build.
    [switch]$SkipVerification
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.Tools.ps1")
. (Join-Path $PSScriptRoot "..\scripts\powershell-scripts\Common.ps1")

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Bundle = Get-LdgcrmBundleRoot

if (-not (Test-Path -LiteralPath $Bundle)) {
    throw "Bundle folder not found: $Bundle"
}

# ============================================================
# EXCLUSIONS
# ============================================================
# Matched against the path RELATIVE TO THE BUNDLE, with forward slashes, so a
# rule reads the same as the path an operator would see. Deny wins over allow.

$DenyPatterns = @(
    ".env",                 # the token. NOT .env.example - see $AllowPatterns.
    ".env.*",
    "data/*",               # every file under data/, at any depth...
    "logs/*",               # ...and logs/. The folders themselves still ship.
    ".sf/*",
    ".sfdx/*",
    "*.sfdx-token",
    "750*-success-records.csv",
    "750*-failed-records.csv",
    "*/.DS_Store",
    "*/Thumbs.db",
    "*/desktop.ini"
)

# Re-admitted after the deny rules above. These are the structural files that
# make an empty data/ or logs/ usable and self-explanatory.
$AllowPatterns = @(
    ".env.example",
    "data/.gitkeep",
    "data/*/.gitkeep",
    "data/README.md",
    "data/*/README.md",
    "logs/.gitkeep",
    "logs/*/.gitkeep",
    "logs/README.md",
    "logs/*/README.md"
)

function Test-AnyPattern {
    param([string]$Path, [string[]]$Patterns)

    foreach ($Pattern in $Patterns) {
        if ($Path -like $Pattern) { return $true }
    }

    return $false
}

function Test-Included {
    param([string]$RelativePath)

    if (Test-AnyPattern -Path $RelativePath -Patterns $AllowPatterns) { return $true }
    if (Test-AnyPattern -Path $RelativePath -Patterns $DenyPatterns)  { return $false }

    return $true
}

# ============================================================
# COLLECT
# ============================================================

$Included = [System.Collections.Generic.List[object]]::new()
$Excluded = [System.Collections.Generic.List[object]]::new()

foreach ($File in Get-ChildItem -LiteralPath $Bundle -Recurse -File -Force) {
    $Relative = $File.FullName.Substring($Bundle.Length + 1).Replace("\", "/")

    if (Test-Included -RelativePath $Relative) {
        $Included.Add([PSCustomObject]@{ Relative = $Relative; Full = $File.FullName })
    }
    else {
        $Excluded.Add($Relative)
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " OPERATIONS BUNDLE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Source    $Bundle"
Write-Host "  Included  $($Included.Count) file(s)"
Write-Host "  Excluded  $($Excluded.Count) file(s)"
Write-Host ""

# Grouped rather than listed: logs/ alone can be thousands of files, and a wall
# of paths is not something anyone reads before approving a hand-off.
$ExcludedGroups = $Excluded | Group-Object { ($_ -split "/")[0] } | Sort-Object Count -Descending

Write-Host "Excluded, by top-level folder:" -ForegroundColor Yellow
foreach ($Group in $ExcludedGroups) {
    Write-Host ("  {0,-24} {1,6} file(s)" -f $Group.Name, $Group.Count)
}

# The single most important line of output: name the credential file explicitly
# rather than letting it hide inside a count.
$EnvExcluded = @($Excluded | Where-Object { $_ -eq ".env" }).Count -eq 1
$EnvExamplePresent = @($Included | Where-Object { $_.Relative -eq ".env.example" }).Count -eq 1

Write-Host ""
if (Test-Path -LiteralPath (Join-Path $Bundle ".env")) {
    if ($EnvExcluded) { Write-Host "  .env         EXCLUDED (correct)" -ForegroundColor Green }
    else { throw "SAFETY STOP: .env exists in the bundle and was NOT excluded. Nothing was written." }
}
else {
    Write-Host "  .env         not present in the bundle" -ForegroundColor DarkGray
}

if ($EnvExamplePresent) { Write-Host "  .env.example INCLUDED (correct)" -ForegroundColor Green }
else { Write-Host "  .env.example MISSING - operators will have no template" -ForegroundColor Yellow }

if ($WhatIf) {
    Write-Host ""
    Write-Host "-WhatIf: nothing was written. Included files:" -ForegroundColor Cyan
    foreach ($Item in $Included | Sort-Object Relative) { Write-Host "  $($Item.Relative)" -ForegroundColor DarkGray }
    return
}

# ============================================================
# BUILD
# ============================================================

if (-not $OutputPath) {
    $DistDir = Join-Path (Get-RepoRoot) "dist"

    if (-not (Test-Path -LiteralPath $DistDir)) {
        New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
    }

    $OutputPath = Join-Path $DistDir ("ldgcrm-migration-scripts-" + (Get-Date -Format "yyyyMMdd") + ".zip")
}

if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Force
}

# Everything is nested under "scripts/" inside the zip so extracting it into the
# Operations repo produces the folder they expect, rather than spraying
# common/, cleanup/ and powershell-scripts/ into their repo root.
$RootFolder = "scripts"

$Archive = [System.IO.Compression.ZipFile]::Open($OutputPath, [System.IO.Compression.ZipArchiveMode]::Create)

try {
    foreach ($Item in $Included | Sort-Object Relative) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $Archive, $Item.Full, "$RootFolder/$($Item.Relative)") | Out-Null
    }
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
# Reads the FINISHED archive rather than trusting the file list above. The
# build and the check can only agree by both being right; a bug in the
# exclusion logic would otherwise be invisible until the zip was already sent.

if ($SkipVerification) {
    Write-Host "Verification skipped (-SkipVerification)." -ForegroundColor Yellow
    return
}

$Problems = [System.Collections.Generic.List[string]]::new()
$Verify = [System.IO.Compression.ZipFile]::OpenRead($OutputPath)

try {
    $Entries = @($Verify.Entries | ForEach-Object { $_.FullName })

    foreach ($Entry in $Entries) {
        if ($Entry -notlike "$RootFolder/*") {
            $Problems.Add("entry outside $RootFolder/: $Entry")
            continue
        }

        $Relative = $Entry.Substring($RootFolder.Length + 1)

        if (-not (Test-Included -RelativePath $Relative)) {
            $Problems.Add("excluded file present in archive: $Relative")
        }
    }

    # Positive checks: the bundle is useless without these.
    foreach ($Required in @(
        "$RootFolder/README.md",
        "$RootFolder/.gitignore",
        "$RootFolder/.env.example",
        "$RootFolder/powershell-scripts/Common.ps1",
        "$RootFolder/powershell-scripts/Common.Orgs.ps1",
        "$RootFolder/powershell-scripts/Invoke-FullMigrationLoad.ps1",
        "$RootFolder/powershell-scripts/Invoke-SandboxFactoryReset.ps1",
        "$RootFolder/docs/SETUP.md",
        "$RootFolder/docs/RUNNING-A-LOAD.md"
    )) {
        if ($Entries -notcontains $Required) { $Problems.Add("MISSING required file: $Required") }
    }

    Write-Host ""
    Write-Host "Verification: $($Entries.Count) entries read back from the archive." -ForegroundColor Cyan
}
finally {
    $Verify.Dispose()
}

if ($Problems.Count -gt 0) {
    Write-Host ""
    foreach ($Problem in $Problems) { Write-Host "  $Problem" -ForegroundColor Red }
    Remove-Item -LiteralPath $OutputPath -Force
    throw "Bundle verification FAILED ($($Problems.Count) problem(s)). The archive was deleted rather than left on disk to be sent by mistake."
}

Write-Host "  No excluded content present. All required files present." -ForegroundColor Green
Write-Host ""
Write-Host "Ready to hand over: $OutputPath" -ForegroundColor Green
