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

# --------------------------------------- 5. PowerShell platform traps
Write-Host "Platform traps" -ForegroundColor Cyan

<#
    @($list) THROWS WHEN THE LIST WAS BUILT WITH New-Object.

    Windows PowerShell 5.1 on the current .NET Framework cannot bind the @( )
    operator to a PSObject-wrapped List[object]:

        $l = New-Object System.Collections.Generic.List[object]
        @($l)      ->  ArgumentException: Argument types do not match

    THE WRAPPER IS WHAT BREAKS IT, NOT THE TYPE. New-Object emits its result
    through the pipeline, so what reaches @( ) is a PSObject around the list,
    and PSEnumerableBinder.MaybeDebase then builds an Expression.Condition()
    whose two branches disagree on type. Building the same list with
    [System.Collections.Generic.List[object]]::new() yields the raw object and
    binds fine, as do List[string], List[psobject] and ArrayList however they
    are built. EVERY OTHER OPERATION on the wrapped list is unaffected -
    .ToArray(), an [object[]] cast, foreach, the pipeline, parameter binding -
    which is why nothing else in the pipeline ever hinted at it.

    It cost a UAT -PlanOnly run on 2026-08-21. The owner-roster name join in
    Invoke-FullMigrationLoad.ps1 keyed a hashtable on List[object] values built
    with New-Object and died the first time a roster name matched a User. Dev
    and QA never saw it: that block only runs behind the Full/Prod gate.

    So the rule is simply: build a List[object] with ::new(), never with
    New-Object. The probe below asserts the platform still behaves as described,
    so that if a future .NET update fixes it this check reads as unnecessary
    rather than as wrong.
#>
$WrappedListThrows = $false
try   { $Probe = New-Object System.Collections.Generic.List[object]; @($Probe) | Out-Null }
catch { $WrappedListThrows = $true }

Write-Host $(if ($WrappedListThrows) {
    "  note  this PowerShell cannot bind @() to a New-Object List[object]"
} else {
    "  note  this PowerShell binds @() to a New-Object List[object] - the rule still holds for operator machines"
}) -ForegroundColor DarkGray

# This file is excluded from its own check: the probe above and the comment
# explaining it both have to contain the very construction being banned.
foreach ($File in @($BundleScripts) + @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Filter *.ps1 -File)) {
    if ($File.FullName -eq $PSCommandPath) { continue }

    $Text = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    Assert-Check -Condition ($Text -notmatch 'New-Object\s+(System\.)?Collections\.Generic\.List\[\s*(object|System\.Object)\s*\]') `
                 -What "builds List[object] with ::new(): $($File.FullName.Substring($Repo.Length + 1))" `
                 -Detail "New-Object wraps the list in a PSObject and @(...) cannot bind that. Use [System.Collections.Generic.List[object]]::new()."
}


# ------------------------------------------------- owned record type scoping
Write-Host ""
Write-Host "Record-type scoping" -ForegroundColor Cyan

# WHY THIS IS TESTED HERE. Same reason as the reset filter above: the failure
# these checks guard against cannot be reproduced on a dev machine. Dev and QA
# hold ~1,300 Accounts, all of them ours, so an unscoped read behaves
# identically to a scoped one and every test passes either way. The difference
# only appears in a full sandbox - a copy of production - where the same query
# returned 1,533,704 records on 2026-08-24 and stopped the run. Neither UAT nor
# Full is authorized on a dev machine, so without these the scoping rule would
# first be exercised, unobserved, against a copy of production.

$OwnedTable = Get-LdgcrmOwnedRecordTypes

foreach ($Case in @(
    @{ SObject = "Account";                Expect = @("Federal") },
    @{ SObject = "Contact";                Expect = @("Federal", "GSA") },
    @{ SObject = "Opportunity";            Expect = @("Login_gov") },
    @{ SObject = "OpportunityContactRole"; Expect = @("Login_gov") }
)) {
    $Entry = $OwnedTable[$Case.SObject]
    $Names = @($Entry.Names | Sort-Object)
    $Want = @($Case.Expect | Sort-Object)

    Assert-Check -Condition (($Names -join ",") -eq ($Want -join ",")) `
                 -What "$($Case.SObject) owns exactly $($Want -join ' + ')" `
                 -Detail ("table says: " + ($Names -join ", "))
}

# The other apps' record types must never appear in the owned set. Named
# explicitly rather than inferred, so that adding one to the table is a visible
# test failure rather than a silently wider filter.
foreach ($Foreign in @("FCIC_Individual", "FCIC_Duplicate", "TTS_Individual", "TTS_OTCRM_Opportunity")) {
    $Found = @($OwnedTable.Keys | Where-Object { @($OwnedTable[$_].Names) -contains $Foreign })

    Assert-Check -Condition ($Found.Count -eq 0) `
                 -What "'$Foreign' is not claimed as ours" `
                 -Detail ("claimed by: " + ($Found -join ", "))
}

# OpportunityContactRole has no record type of its own and must be scoped
# through its parent. A plain RecordType.DeveloperName here would be a SOQL
# error at runtime, in the middle of a load, against production.
Assert-Check -Condition ($OwnedTable["OpportunityContactRole"].Path -eq "Opportunity.RecordType.DeveloperName") `
             -What "OpportunityContactRole is scoped through its parent Opportunity" `
             -Detail $OwnedTable["OpportunityContactRole"].Path

# Objects that are wholly ours must return an EMPTY clause, not a filter on a
# field they do not have. LDGCRM_Market_Segment__c has no RecordType at all, so
# a non-empty clause here is an invalid query rather than a narrow one.
foreach ($Ours in @("LDGCRM_application__c", "LDGCRM_Market_Segment__c",
                    "LDGCRM_Partner_Account__c", "LDGCRM_Impediment__c",
                    "LDGCRM_Application_Contact__c", "LDGCRM_Opportunity_Impediment__c")) {
    Assert-Check -Condition ((Get-LdgcrmOwnedRecordTypeClause -SObject $Ours) -eq "") `
                 -What "$Ours needs no record-type filter (wholly ours)"
}

# Clause shape. Checked as a string because it is spliced into SOQL by hand at
# every call site - an unquoted value or a stray comma is a runtime failure in
# the middle of a load, and there is no org here to catch it.
Assert-Check -Condition ((Get-LdgcrmOwnedRecordTypeClause -SObject "Account") -eq "RecordType.DeveloperName IN ('Federal')") `
             -What "Account clause is well-formed SOQL" `
             -Detail (Get-LdgcrmOwnedRecordTypeClause -SObject "Account")

Assert-Check -Condition ((Get-LdgcrmOwnedRecordTypeClause -SObject "Contact") -eq "RecordType.DeveloperName IN ('Federal', 'GSA')") `
             -What "Contact clause quotes and separates both values" `
             -Detail (Get-LdgcrmOwnedRecordTypeClause -SObject "Contact")

# -Scope is mandatory on Get-SalesforceRecordCount. That is the whole design:
# an unscoped count has to be typed as one. If a refactor ever gives it a
# default, every existing call keeps working and new ones silently go org-wide -
# which is precisely the state this change was made to end.
$ScopeParam = (Get-Command Get-SalesforceRecordCount).Parameters["Scope"]
$ScopeMandatory = @($ScopeParam.Attributes |
    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
    Where-Object { $_.Mandatory })

Assert-Check -Condition ($ScopeMandatory.Count -gt 0) `
             -What "Get-SalesforceRecordCount requires -Scope to be stated"

# No bundle script may count by fetching every Id of an object. That form
# cannot see past the CLI's 50,000-row ceiling, and the ceiling is not reachable
# in any org a developer can authorize here.
#
# Matched as "SELECT Id FROM <variable>" carrying no WHERE, which is the shape
# that was actually wrong. A SELECT Id that IS filtered stays legal - the
# factory reset legitimately fetches tagged Ids to walk ContentDocumentLink from
# them, and wants the Ids themselves rather than a number.
foreach ($File in $BundleScripts) {
    $Text = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    $Relative = $File.FullName.Substring($Repo.Length + 1)

    $Unfiltered = @([regex]::Matches($Text, '"SELECT Id FROM \$[^"]*"') |
        Where-Object { $_.Value -notmatch 'WHERE' })

    Assert-Check -Condition ($Unfiltered.Count -eq 0) `
                 -What "counts with COUNT(), not by fetching Ids: $Relative" `
                 -Detail ("Use Get-SalesforceRecordCount -Scope Owned. Found: " + (@($Unfiltered | ForEach-Object { $_.Value }) -join "; "))
}

# Every read of a shared standard object must carry a WHERE. This is a coarse
# check on purpose - it cannot tell a record-type filter from any other
# predicate - but the failure it catches is the one that actually happened: a
# query written with no WHERE at all.
foreach ($File in $BundleScripts) {
    $Text = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
    $Relative = $File.FullName.Substring($Repo.Length + 1)

    foreach ($Shared in @("Account", "Contact", "Opportunity", "OpportunityContactRole")) {
        Assert-Check -Condition ($Text -notmatch ("FROM $Shared\s*""")) `
                     -What "no unfiltered read of $Shared in $Relative" `
                     -Detail "A read of a record-typed object shared with FCIC/TTS must carry a WHERE. See Get-LdgcrmOwnedRecordTypeClause."
    }
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
