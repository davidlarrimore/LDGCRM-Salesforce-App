#Requires -Version 5.1

<#
    Proves scripts/ is still a self-contained bundle. Run it after touching
    anything under scripts/, and before building a hand-off zip.

    WHY THIS EXISTS AS A TEST RATHER THAN A CONVENTION
      The bundle's self-containment is invisible while you work in this
      repository, because everything it must NOT depend on is sitting right
      there one level up. Add `Join-Path (Get-RepoRoot) "docs"` to a script here
      and it resolves, the file is found, the tests pass, and nothing is wrong
      until the folder is dropped into the Operations repo - at which point it
      silently reads or writes somewhere in a repository we do not control.

      Every check below is something that CANNOT be noticed by running the
      pipeline normally on this machine.

    WHAT IT DOES NOT DO
      It does not touch Salesforce, so it is safe to run any time. It does not
      check that the pipeline WORKS - that is what
      `Invoke-FullMigrationLoad.ps1 -PlanOnly` is for.

    Exits non-zero on the first category of failure so it can gate a commit.
#>

param(
    # Print every check, not just failures.
    [switch]$Detailed
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.Tools.ps1")

$Repo = Get-RepoRoot
$Bundle = Get-LdgcrmBundleRoot
$Failures = [System.Collections.Generic.List[string]]::new()

function Assert-Check {
    param(
        [bool]$Condition,
        [string]$What,
        [string]$Detail = ""
    )

    if ($Condition) {
        if ($Detailed) { Write-Host "  ok    $What" -ForegroundColor Green }
        return
    }

    Write-Host "  FAIL  $What" -ForegroundColor Red
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
    $Failures.Add($What)
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " BUNDLE STRUCTURE CHECK" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bundle  $Bundle"
Write-Host ""

$BundleScripts = @(Get-ChildItem -LiteralPath $Bundle -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notlike "*\logs\*" })

# ---------------------------------------------------------------- 1. syntax
Write-Host "Syntax" -ForegroundColor Cyan

foreach ($File in @($BundleScripts) + @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Filter *.ps1 -File)) {
    $Errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$null, [ref]$Errors) | Out-Null
    Assert-Check -Condition (-not $Errors -or $Errors.Count -eq 0) `
                 -What "parses: $($File.FullName.Substring($Repo.Length + 1))" `
                 -Detail $(if ($Errors -and $Errors.Count) { $Errors[0].Message } else { "" })
}

# ------------------------------------------------------- 2. no upward paths
Write-Host "Self-containment" -ForegroundColor Cyan

foreach ($File in $BundleScripts) {
    $Text = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    $Relative = $File.FullName.Substring($Repo.Length + 1)

    # The CALL form only - a comment explaining why the function moved is fine.
    Assert-Check -Condition ($Text -notmatch '\(\s*Get-RepoRoot\s*\)') `
                 -What "does not call Get-RepoRoot: $Relative" `
                 -Detail "Use Get-LdgcrmRoot. If this script genuinely needs sfdx/ or docs/, it belongs in tools/."

    # A dot-source climbing two levels leaves the bundle. One level is fine
    # (common/ -> cleanup/), two is not.
    Assert-Check -Condition ($Text -notmatch '\$PSScriptRoot["\s]*[,)]?\s*"\.\.[\\/]\.\.') `
                 -What "no dot-source escapes the bundle: $Relative"
}

# The helper the whole bundle depends on, and the one it must NOT have.
. (Join-Path $Bundle "powershell-scripts\Common.ps1")
. (Join-Path $Bundle "powershell-scripts\Common.DataMigration.ps1")

Assert-Check -Condition ((Get-LdgcrmRoot) -eq $Bundle) `
             -What "Get-LdgcrmRoot resolves to the bundle root"

# Dot-sourcing the bundle must not have introduced Get-RepoRoot into scope from
# anywhere other than tools/Common.Tools.ps1, which this script loaded itself.
$RepoRootSource = (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue).ScriptBlock.File
Assert-Check -Condition ($RepoRootSource -eq (Join-Path $PSScriptRoot "Common.Tools.ps1")) `
             -What "Get-RepoRoot comes only from tools/Common.Tools.ps1" `
             -Detail "Found in: $RepoRootSource"

foreach ($Pair in @(
    @{ Name = "airtable-exports"; Path = (Split-Path -Parent (Get-AirtableExportPath -Label "Accounts")) },
    @{ Name = "salesforce-loads"; Path = (Get-SalesforceLoadDirectory) },
    @{ Name = "prod-accounts";    Path = (Get-ProdAccountExportDirectory) },
    @{ Name = "logs";             Path = (Get-LogCategoryDirectory -Category "data-migration") }
)) {
    Assert-Check -Condition ($Pair.Path.StartsWith($Bundle, [StringComparison]::OrdinalIgnoreCase)) `
                 -What "$($Pair.Name) resolves inside the bundle" `
                 -Detail $Pair.Path
}

# -------------------------------------------------- 3. the shipped structure
Write-Host "Required files" -ForegroundColor Cyan

foreach ($Required in @(
    "README.md", ".gitignore", ".env.example",
    "powershell-scripts\Common.ps1", "powershell-scripts\Common.Orgs.ps1",
    "docs\OVERVIEW.md", "docs\SETUP.md", "docs\RUNNING-A-LOAD.md",
    "docs\TROUBLESHOOTING.md", "docs\ROLLBACK.md", "docs\RELOAD-QA-CHECKLIST.md",
    "data\prod-accounts\README.md", "logs\README.md"
)) {
    Assert-Check -Condition (Test-Path -LiteralPath (Join-Path $Bundle $Required)) `
                 -What "present: $Required"
}

# .gitignore has to actually ignore the things it exists to ignore. Asked of
# git itself rather than by reading the file - the rules interact, and a later
# negation can re-admit what an earlier rule excluded.
Write-Host "Ignore rules" -ForegroundColor Cyan

foreach ($Case in @(
    @{ Path = "scripts/.env";                                Ignored = $true  },
    @{ Path = "scripts/.env.example";                        Ignored = $false },
    @{ Path = "scripts/data/airtable-exports/Accounts.json";  Ignored = $true  },
    @{ Path = "scripts/data/prod-accounts/export.xlsx";       Ignored = $true  },
    @{ Path = "scripts/data/prod-accounts/README.md";         Ignored = $false },
    @{ Path = "scripts/logs/data-migration/run/SUMMARY.txt";  Ignored = $true  },
    @{ Path = "scripts/logs/README.md";                       Ignored = $false },
    @{ Path = "scripts/README.md";                            Ignored = $false }
)) {
    # git check-ignore exits 0 when the path IS ignored, 1 when it is not.
    & git -C $Repo check-ignore --quiet -- $Case.Path
    $IsIgnored = ($LASTEXITCODE -eq 0)

    Assert-Check -Condition ($IsIgnored -eq $Case.Ignored) `
                 -What "$(if ($Case.Ignored) { 'ignored' } else { 'tracked' }): $($Case.Path)" `
                 -Detail "git says ignored=$IsIgnored"
}

# ------------------------------------------------- 4. the environment rules
Write-Host "Environment rules" -ForegroundColor Cyan

foreach ($Case in @(
    @{ Env = "Dev"; Rebuild = $true }, @{ Env = "QA"; Rebuild = $true },
    @{ Env = "UAT"; Rebuild = $false },
    @{ Env = "Full"; Rebuild = $false }, @{ Env = "Prod"; Rebuild = $false }
)) {
    Assert-Check -Condition ((Test-LdgcrmAccountRebuildAllowed -Environment $Case.Env) -eq $Case.Rebuild) `
                 -What "Account rebuild allowed in $($Case.Env) = $($Case.Rebuild)"
}

$Table = Get-LdgcrmEnvironmentTable
Assert-Check -Condition ($Table["Prod"].Alias -eq "gsa-peo" -and $Table["Prod"].IsProduction) `
             -What "Prod is alias 'gsa-peo' and flagged as production"

# THE FULL-SANDBOX PATH, WHICH NOTHING ELSE CAN REACH. UAT (PEOfL1UATp) and Full
# (PEOfL2STGp) are provisioned but not authorized on a dev machine, so a real
# reset against either throws on alias resolution long before the Account filter
# matters - meaning without this, the code protecting a copy of production would
# first run unobserved against a copy of production.
$Sample = @("LDGCRM_Application_Contact__c", "Contact", "Account", "LDGCRM_Market_Segment__c")

foreach ($Case in @(
    @{ Env = "Dev";  Expect = 4; Keeps = $true  },
    @{ Env = "QA";   Expect = 4; Keeps = $true  },
    @{ Env = "UAT";  Expect = 3; Keeps = $false },
    @{ Env = "Full"; Expect = 3; Keeps = $false },
    @{ Env = "Prod"; Expect = 3; Keeps = $false }
)) {
    $Kept = @(Select-LdgcrmResettableObjects -Environment $Case.Env -Objects $Sample)

    Assert-Check -Condition ($Kept.Count -eq $Case.Expect) `
                 -What "$($Case.Env) reset keeps $($Case.Expect) of 4 objects" `
                 -Detail ($Kept -join ", ")

    Assert-Check -Condition ((@($Kept) -contains "Account") -eq $Case.Keeps) `
                 -What "$($Case.Env) reset $(if ($Case.Keeps) { 'includes' } else { 'EXCLUDES' }) Account"

    # The non-Account objects must be untouched - a Full reset still resets
    # everything this migration created.
    Assert-Check -Condition (@($Kept) -contains "Contact" -and @($Kept) -contains "LDGCRM_Market_Segment__c") `
                 -What "$($Case.Env) reset still includes the migration's own objects"
}

# Asking to reset ONLY Account where that is forbidden must throw, not quietly
# do nothing and report success.
$Threw = $false
try { Select-LdgcrmResettableObjects -Environment "Full" -Objects @("Account") | Out-Null }
catch { $Threw = $true }
Assert-Check -Condition $Threw -What "Full reset of ONLY Account throws rather than no-opping"

foreach ($Key in @("Dev", "QA", "UAT", "Full", "Prod")) {
    Assert-Check -Condition ([bool]$Table[$Key].InstanceUrl -and [bool]$Table[$Key].LightningUrl) `
                 -What "$Key has both URLs recorded"
}

# The bind-time blocks. Asserted by EXIT CODE - never redirect a native
# command's stderr in PS 5.1 (it becomes a terminating NativeCommandError).
Write-Host "Bind-time blocks" -ForegroundColor Cyan

foreach ($Case in @(
    @{ Script = "powershell-scripts\Invoke-AccountBootstrap.ps1"; Env = "UAT";  Args = "-PlanOnly" },
    @{ Script = "powershell-scripts\Invoke-AccountBootstrap.ps1"; Env = "Full"; Args = "-PlanOnly" },
    @{ Script = "powershell-scripts\Invoke-AccountBootstrap.ps1"; Env = "Prod"; Args = "-PlanOnly" },
    @{ Script = "powershell-scripts\Invoke-SandboxFactoryReset.ps1";     Env = "Prod"; Args = "" }
)) {
    $Path = Join-Path $Bundle $Case.Script
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -Command "& '$Path' -Environment $($Case.Env) $($Case.Args)" | Out-Null

    Assert-Check -Condition ($LASTEXITCODE -ne 0) `
                 -What "$(Split-Path -Leaf $Case.Script) rejects -Environment $($Case.Env)"
}

# ----------------------------------------------------------------- verdict
Write-Host ""

if ($Failures.Count -eq 0) {
    Write-Host "PASS - the bundle is self-contained." -ForegroundColor Green
    exit 0
}

Write-Host "FAILED - $($Failures.Count) check(s):" -ForegroundColor Red
foreach ($Failure in $Failures) { Write-Host "  - $Failure" -ForegroundColor Red }
exit 1
