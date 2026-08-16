#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Common.AccountMatching.ps1 - the shared Account matching
    cascade, agency resolution and depth-to-level ladder.

.DESCRIPTION
    Engineering-only, so it lives in tools/ alongside Test-BundleStructure.ps1
    rather than shipping to Operations.

    TOUCHES NO ORG. The cascade cases run against the production Account export
    in scripts/data/prod-accounts/, which is gitignored - if it is absent those
    cases are skipped and the pure-logic ones still run, so the file is useful
    in a fresh clone rather than simply failing.

    Every case here is a bug that was actually shipped and then caught:
      - a claimed Account being removed from the index broke the HIERARCHY, so
        once an agency matched its own row, its children could no longer resolve
        their agency (11 regressions);
      - an exact name under a different agency was proposed as a NEW Account,
        which would have duplicated six Commerce bureaus;
      - a common name inside a formal one ("Amtrak" in "National Railroad
        Passenger Corporation (Amtrak)") did the same;
      - a place name was read as an agency suffix.

.EXAMPLE
    .\tools\Test-AccountMatching.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Scripts  = Join-Path $RepoRoot "scripts\powershell-scripts"

. (Join-Path $Scripts "Common.ps1")
. (Join-Path $Scripts "Common.DataMigration.ps1")
. (Join-Path $Scripts "Common.AccountMatching.ps1")

$Script:Passed = 0
$Script:Failed = 0

function Assert-Equals {
    param([string]$What, $Actual, $Expected)

    if ("$Actual" -eq "$Expected") {
        $Script:Passed++
        Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    }
    else {
        $Script:Failed++
        Write-Host ("  FAIL  {0}" -f $What) -ForegroundColor Red
        Write-Host ("          expected '{0}'" -f $Expected) -ForegroundColor Red
        Write-Host ("          got      '{0}'" -f $Actual) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ACCOUNT MATCHING TESTS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ------------------------------------------------------------
Write-Host ""
Write-Host "Name normalisation" -ForegroundColor Cyan

Assert-Equals "ampersand folds to 'and'"    (Get-LdgcrmNameLoose -Name 'Economic & Business Affairs') 'economic and business affairs'
Assert-Equals "en dash folds to hyphen"     (Get-LdgcrmNameLoose -Name ('Interpol {0} Washington' -f [char]0x2013)) 'interpol washington'
Assert-Equals "agency suffix splits off"    (Split-LdgcrmAgencySuffix -Name 'Office of Civil Rights - GSA').Suffix 'GSA'
Assert-Equals "  and leaves the bare name"  (Split-LdgcrmAgencySuffix -Name 'Office of Civil Rights - GSA').Bare 'Office of Civil Rights'

# "Washington" is 10 characters, past the 6-char cap, so it is NOT a suffix.
# The cap is what stops an ordinary hyphenated name being read as a convention.
Assert-Equals "a place is not a suffix"     (Split-LdgcrmAgencySuffix -Name 'Interpol - Washington').Suffix ''
Assert-Equals "  and the name is untouched" (Split-LdgcrmAgencySuffix -Name 'Interpol - Washington').Bare 'Interpol - Washington'

# ------------------------------------------------------------
Write-Host ""
Write-Host "Account level, derived from depth" -ForegroundColor Cyan

Assert-Equals "depth 0 -> Level 1"  (Get-LdgcrmAccountLevel -Depth 0) 'Level 1'
Assert-Equals "depth 1 -> Level 2"  (Get-LdgcrmAccountLevel -Depth 1) 'Level 2'
Assert-Equals "depth 2 -> Level 3"  (Get-LdgcrmAccountLevel -Depth 2) 'Level 3'
Assert-Equals "depth 3 -> Level 4+" (Get-LdgcrmAccountLevel -Depth 3) 'Level 4+'
Assert-Equals "deeper stays Level 4+" (Get-LdgcrmAccountLevel -Depth 7) 'Level 4+'

Write-Host ""
Write-Host "Depth walk" -ForegroundColor Cyan

$Tree = @{
    'a' = [PSCustomObject]@{ Id='a'; ParentId=$null }
    'b' = [PSCustomObject]@{ Id='b'; ParentId='a'  }
    'c' = [PSCustomObject]@{ Id='c'; ParentId='b'  }
    # A cycle. The bound has to survive it rather than hang the run.
    'x' = [PSCustomObject]@{ Id='x'; ParentId='y'  }
    'y' = [PSCustomObject]@{ Id='y'; ParentId='x'  }
}
Assert-Equals "root is depth 0"        (Get-LdgcrmAccountDepth -AccountsById $Tree -AccountId 'a') 0
Assert-Equals "child is depth 1"       (Get-LdgcrmAccountDepth -AccountsById $Tree -AccountId 'b') 1
Assert-Equals "grandchild is depth 2"  (Get-LdgcrmAccountDepth -AccountsById $Tree -AccountId 'c') 2
Assert-Equals "a cycle stops at the bound" (Get-LdgcrmAccountDepth -AccountsById $Tree -AccountId 'x' -MaxDepth 5) 5

# ------------------------------------------------------------
Write-Host ""
Write-Host "Market segment aliases" -ForegroundColor Cyan

Assert-Equals "aliased segment maps"   (Get-LdgcrmMarketSegmentName -AirtableValue 'Defense & National Security') 'Defense'
Assert-Equals "unaliased passes through" (Get-LdgcrmMarketSegmentName -AirtableValue 'Benefits') 'Benefits'
Assert-Equals "blank stays blank"      (Get-LdgcrmMarketSegmentName -AirtableValue '') ''

# ------------------------------------------------------------
# The cascade needs a real Account population.
# ------------------------------------------------------------
$ExportDir = Join-Path $RepoRoot "scripts\data\prod-accounts"
$ExportFile = $null
if (Test-Path -LiteralPath $ExportDir) {
    $ExportFile = @(Get-ChildItem -LiteralPath $ExportDir -File |
        Where-Object { $_.Name -notmatch '\.(md|gitkeep)$' } |
        Sort-Object LastWriteTime -Descending) | Select-Object -First 1
}

if (-not $ExportFile) {
    Write-Host ""
    Write-Host "SKIPPED: the cascade tests need a production Account export in" -ForegroundColor Yellow
    Write-Host "         scripts/data/prod-accounts/ (gitignored, so absent in a fresh clone)." -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "Index over the production export" -ForegroundColor Cyan

    $Prod  = @(Import-ProdAccountExport -Path $ExportFile.FullName)
    $Index = New-LdgcrmAccountIndex -Accounts $Prod

    Write-Host ("  {0} Accounts indexed, {1} agency suffixes learned" -f $Prod.Count, $Index.SuffixByAgency.Count) -ForegroundColor DarkGray

    # The suffix map is learned from the data, never hard-coded.
    Assert-Equals "GSA suffix learned" $Index.SuffixByAgency[(Get-LdgcrmNameLoose -Name 'General Services Administration')] 'GSA'
    Assert-Equals "NRC suffix learned" $Index.SuffixByAgency[(Get-LdgcrmNameLoose -Name 'Nuclear Regulatory Commission')]  'NRC'

    Write-Host ""
    Write-Host "The cascade, on cases with a known right answer" -ForegroundColor Cyan

    $Cases = @(
        # The org appends an agency suffix; Airtable holds the bare name.
        @{ Name='Office of Civil Rights';        Parent='General Services Administration';       Verdict='Match'; Target='Office of Civil Rights - GSA' },
        @{ Name='Office of the General Counsel'; Parent='Nuclear Regulatory Commission';         Verdict='Match'; Target='Office of the General Counsel - NRC' },
        @{ Name='Office of Inspector General';   Parent='Department of Health and Human Services'; Verdict='Match'; Target='Office of Inspector General - HHS' },
        # Punctuation only.
        @{ Name='Economic and Business Affairs'; Parent='Department of State';                   Verdict='Match'; Target='Economic & Business Affairs' },
        # Airtable carries the suffix and the org does not.
        @{ Name='Office of the Secretary - DOC'; Parent='Department of Commerce';                Verdict='Match'; Target='Office of the Secretary' }
    )

    foreach ($Case in $Cases) {
        $Result = Resolve-LdgcrmAccount -Index $Index -Name $Case.Name -ParentName $Case.Parent
        $Label  = "{0} [{1}]" -f $Case.Name, $Case.Parent

        if ($Result.Verdict -ne $Case.Verdict) { Assert-Equals $Label $Result.Verdict $Case.Verdict }
        else { Assert-Equals $Label $Result.Account.Name $Case.Target }
    }

    Write-Host ""
    Write-Host "Top-level acceptance, and what it must NOT accept" -ForegroundColor Cyan

    # Airtable files states under an umbrella the org keeps at top level. One
    # top-level Account of exactly this name is the same body, filed differently.
    $Result = Resolve-LdgcrmAccount -Index $Index -Name 'State of Colorado' -ParentName 'State and Local Government'
    Assert-Equals "a state matches at top level" $Result.Verdict 'Match'
    Assert-Equals "  and to the right record"    $Result.Account.Name 'State of Colorado'

    # A generic office name belonging to ANOTHER agency must never be accepted -
    # this is the wrong-link case that attached seven Accounts to the wrong body.
    $Result = Resolve-LdgcrmAccount -Index $Index -Name 'Office Of The Secretary' -ParentName 'Department of Housing and Urban Development'
    Assert-Equals "another agency's office is not auto-matched" $Result.Verdict 'Confirm'

    Write-Host ""
    Write-Host "An existing Account is never proposed for creation" -ForegroundColor Cyan

    # Airtable files NOAA under Agriculture; the Account exists under Commerce.
    # Creating would duplicate it.
    $Result = Resolve-LdgcrmAccount -Index $Index -Name 'National Oceanic and Atmospheric Administration' -ParentName 'U.S. Department of Agriculture'
    Assert-Equals "exact name under another agency" $Result.Verdict 'Confirm'

    # The common name sits INSIDE the formal one the org records.
    $Result = Resolve-LdgcrmAccount -Index $Index -Name 'Amtrak' -ParentName ''
    Assert-Equals "common name inside a formal one" $Result.Verdict 'Confirm'
    $Result = Resolve-LdgcrmAccount -Index $Index -Name 'Senate' -ParentName 'Congress'
    Assert-Equals "  and again, with an agency named" $Result.Verdict 'Confirm'

    Write-Host ""
    Write-Host "Claiming must not break the hierarchy" -ForegroundColor Cyan

    # Removing a claimed Account from the index once broke agency resolution for
    # every child beneath it: an agency is still an agency after its own Airtable
    # row has matched. 11 Accounts stopped matching.
    $Agency = @($Prod | Where-Object { $_.Name -eq 'General Services Administration' }) | Select-Object -First 1
    if ($Agency) {
        Remove-LdgcrmAccountFromIndex -Index $Index -Account $Agency
        $Result = Resolve-LdgcrmAccount -Index $Index -Name 'Office of the Chief Financial Officer' -ParentName 'General Services Administration'
        Assert-Equals "a child still resolves after its agency is claimed" $Result.Verdict 'Match'
        Assert-Equals "  and to the right record" $Result.Account.Name 'Office of the Chief Financial Officer - GSA'
    }

    Write-Host ""
    Write-Host "Naming a new Account" -ForegroundColor Cyan

    Assert-Equals "a colliding name takes the agency suffix" (New-LdgcrmAccountName -Index $Index -Name 'Office of the Secretary' -AgencySuffix 'HUD') 'Office of the Secretary - HUD'
    Assert-Equals "a unique name stays bare"                 (New-LdgcrmAccountName -Index $Index -Name 'Conference of State Bank Supervisors' -AgencySuffix 'XYZ') 'Conference of State Bank Supervisors'
    Assert-Equals "no suffix known, name unchanged"          (New-LdgcrmAccountName -Index $Index -Name 'Office of the Secretary' -AgencySuffix '') 'Office of the Secretary'
}

# ------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
if ($Script:Failed -eq 0) {
    Write-Host (" PASS - {0} checks" -f $Script:Passed) -ForegroundColor Green
}
else {
    Write-Host (" FAIL - {0} of {1} checks failed" -f $Script:Failed, ($Script:Passed + $Script:Failed)) -ForegroundColor Red
}
Write-Host "============================================================" -ForegroundColor Cyan

if ($Script:Failed -gt 0) { exit 1 }
