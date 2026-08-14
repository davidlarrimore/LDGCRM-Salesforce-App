#Requires -Version 5.1

<#
    Bootstraps an org's Account tree - names AND parent hierarchy - from the
    production Account export dropped in data/prod-accounts/ (any of .xls,
    .xlsx or .csv - the format is sniffed from the file's content, see
    Get-ProdAccountExportFormat).

    ------------------------------------------------------------------
    DEV AND QA ONLY. NOT FULL, NOT PRODUCTION.
    ------------------------------------------------------------------
    -Environment accepts Dev and QA and nothing else, so PowerShell rejects a
    Full or Prod target at bind time - the same structural block
    Invoke-SandboxFactoryReset.ps1 uses against production, for the same
    reason: there is no legitimate use, so it is not offered as a guarded
    option. Test-LdgcrmAccountRebuildAllowed in Common.Orgs.ps1 carries the
    reasoning and is the single definition of the rule.

    In short: Dev and QA are empty developer sandboxes that need an Account
    universe invented for them. A Full sandbox is a COPY OF PRODUCTION whose
    Accounts are the real records this migration reconciles onto, and
    overwriting them with a stale export would invalidate the very rehearsal it
    was meant to support.

    WHY THIS EXISTS
      Every other object in this migration hangs off Account, and Account is
      the one object the migration does NOT create from Airtable (see
      Build-AccountReconciliation.ps1: Accounts pre-date the migration, so the
      pipeline reconciles onto existing records rather than inserting new
      ones). That works in production, where the Accounts are already there.
      It does not work in a freshly-cleaned sandbox, where there is nothing to
      reconcile onto - and a QA/Full-sandbox rehearsal of the migration is only
      meaningful if it starts from a realistic Account universe.

      This script builds that universe. It supersedes Build-ProdAccountSeed.ps1,
      which seeded Name only and left every Account parentless.

    WHY IT TAKES MULTIPLE PASSES
      Account.ParentId is a self-referential lookup, and the export identifies
      parents BY NAME, not by an ID this org would recognise (see the
      "Account ID" trap in Import-ProdAccountExport - that column is misaligned
      and unusable). A parent's Salesforce Id therefore doesn't exist until the
      parent row has actually been inserted, so the tree has to be built
      outward from the roots:

        pass 1  insert the 247 root Accounts (no parent)
        pass 2  insert/parent everything whose parent now resolves
        pass 3  ...and their children
        ...     until a pass changes nothing

      Each pass re-queries the org rather than assuming what it just wrote
      landed. Hierarchy in this export is 4 levels deep at most, so it settles
      in a handful of passes; -MaxPasses is a runaway guard, not a tuning knob.

    WHAT IT WILL NOT DO
      - It never reparents an Account that already has a parent. Existing
        hierarchy in the target org wins; conflicts are reported, not resolved.
      - It never guesses an ambiguous parent. 22 Account names appear more than
        once in the export (e.g. "Office of the Inspector General" x4), so a
        child naming one of them as its parent cannot be resolved by name.
        Those children are still INSERTED - the rest of the pipeline matches
        Accounts by name and needs the record to exist - but they are left
        parentless and written to a review CSV. -StrictHierarchy skips them
        entirely instead.
      - It never touches LDGCRM_External_ID__c. That field is the Airtable
        correlation key; Build-AccountReconciliation.ps1 owns it. Bootstrapped
        Accounts deliberately carry none, which is also why
        Invoke-SandboxFactoryReset.ps1 (which only deletes external-ID-tagged records)
        leaves them alone.
      - It DOES set OwnerId on inserted Accounts, from the export's "Account
        Owner" column, via Resolve-SalesforceOwnerIdsByName - the export carries
        a display name rather than an email, so the usual email resolver can't
        be used. Unresolvable owners are left blank (the record then lands on
        the loading user, the org default for an insert) rather than being given
        the migration's fallback owner: this bootstrap recreates a baseline of
        Accounts the migration does not own, so inventing an owner for them
        would misrepresent it. Owners are only set on INSERT - an Account that
        already exists keeps whatever owner it has.
        Consequence, worth knowing before a rehearsal: Contact ownership
        inherits from Account, so it still cannot be demonstrated outside
        production. See TRANSFORMATION-RULES.md's "Record ownership" section.

    THIS SCRIPT WRITES TO SALESFORCE. Unlike the Build-*.ps1 transforms (which
    only ever produce CSVs) this one inserts and updates records, because the
    passes have to interleave reads and writes - a plan computed up front would
    be stale by pass 2. It follows the same discipline as
    Invoke-SalesforceLoad.ps1: target-org verification, preflight counts, and a
    typed BOOTSTRAP confirmation before anything is written. Run it with
    -PlanOnly first; that is a genuine dry run (read-only, writes the pass-by-
    pass plan to CSV and exits).
#>

param(
    # "Full" and "Prod" are absent on purpose - see the block in the header.
    # Do not add them back.
    [ValidateSet("Dev", "QA")]
    [string]$Environment = "Dev",

    # Escape hatch for an org that isn't in the registry. Skips the registry's
    # identity checks - see Assert-LdgcrmOrgTarget - which is why the
    # Organization.IsSandbox check below is not optional.
    [string]$OrgAlias = "",

    [string]$ApiVersion = "67.0",

    # Defaults to the newest file in data/prod-accounts/.
    [string]$SourceFile = "",

    # Read-only dry run: computes and writes the full pass plan, writes nothing
    # to Salesforce. Always do this first.
    [switch]$PlanOnly,

    # Skip (rather than insert parentless) any Account whose parent can't be
    # resolved unambiguously.
    [switch]$StrictHierarchy,

    # Approve the bootstrap without a prompt: -Confirmation "BOOTSTRAP". A token
    # rather than a -Force switch - see Assert-LdgcrmTypedConfirmation.
    [string]$Confirmation = "",

    # NO -ProductionConfirmation HERE, deliberately. It was removed on
    # 2026-08-14 along with Prod/Full from the ValidateSet above. A parameter
    # whose only purpose is to approve something this script can no longer do
    # is worse than useless: it reads as though a production path exists and
    # invites someone to go looking for it.

    # Runaway guard. The export is 4 levels deep; this should never bind.
    [int]$MaxPasses = 12,

    [int]$WaitMinutes = 30
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Invoke-AccountBootstrap"
# The run directory itself - see Common.ps1's "one directory per run".
$RunDirectory = Get-LogDirectory -Category "data-migration"

function Get-NormalizedName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }

    return $Name.Trim().ToLowerInvariant()
}

function Get-OrgAccountIndex {
    <#
        Reads the target org's current Accounts and indexes them by normalized
        name.

        Returns a hashtable: normalized name -> array of @{Id; Name; ParentId}.
        An entry with more than one element is AMBIGUOUS and is never used as a
        parent - see the duplicate-name note in the file header.

        Re-read at the top of every pass. Deliberately not cached-and-patched:
        assuming a write landed exactly as intended is how a multi-pass loader
        silently builds the wrong tree.
    #>
    param([string]$Org, [string]$Version)

    $Records = @(Invoke-SalesforceQuery -Soql "SELECT Id, Name, ParentId FROM Account" -OrgAlias $Org -ApiVersion $Version)

    $Index = @{}

    foreach ($Record in $Records) {
        $Key = Get-NormalizedName -Name $Record.Name

        if (-not $Key) { continue }

        if (-not $Index.ContainsKey($Key)) {
            $Index[$Key] = [System.Collections.Generic.List[object]]::new()
        }

        $Index[$Key].Add([PSCustomObject]@{
            Id       = $Record.Id
            Name     = $Record.Name
            ParentId = $Record.ParentId
        })
    }

    return $Index
}

function Get-UniqueOrgAccount {
    <#
        Returns the single org Account matching a name, or $null when there
        is no match OR more than one. "More than one" deliberately returns
        nothing rather than a first-match: picking one would silently parent a
        real record under the wrong agency.
    #>
    param($Index, [string]$Name)

    $Key = Get-NormalizedName -Name $Name

    if (-not $Key -or -not $Index.ContainsKey($Key)) { return $null }

    $Matches = $Index[$Key]

    if ($Matches.Count -ne 1) { return $null }

    return $Matches[0]
}

function Invoke-BulkCsv {
    <#
        Runs one bulk insert/update from a CSV and returns the parsed result.
        Not routed through Invoke-SalesforceLoad.ps1 on purpose: that script
        gates every call behind its own typed LOAD prompt, which would mean
        answering a prompt once per pass in the middle of a loop. This script
        gates once, up front, for the whole run.
    #>
    param(
        [ValidateSet("import", "update")] [string]$Subcommand,
        [string]$CsvFile,
        [string]$Org,
        [string]$Version,
        [int]$Wait
    )

    $Arguments = @(
        "data", $Subcommand, "bulk",
        "--sobject", "Account",
        "--file", $CsvFile,
        "--target-org", $Org,
        "--api-version", $Version,
        "--wait", $Wait.ToString()
    )

    Write-Host ""
    Write-Host "sf $($Arguments -join ' ')" -ForegroundColor DarkGray

    $RawResult = & sf @Arguments --json

    # A bulk job with row-level failures exits non-zero. That is not fatal to
    # the run - later passes may still make progress, and the per-pass failure
    # count is reported - so the result is parsed either way and the caller
    # decides.
    $Parsed = $null

    try { $Parsed = $RawResult | ConvertFrom-Json } catch { $Parsed = $null }

    if ($null -eq $Parsed) {
        Write-Host $RawResult -ForegroundColor Red
        throw "Could not parse the Salesforce CLI response for $Subcommand."
    }

    return $Parsed
}

function Get-BulkCounts {
    <#
        `sf data import bulk` and `sf data update bulk` report their totals in
        two different JSON shapes (jobInfo.* vs flat processedRecords/*) - the
        same divergence Invoke-SalesforceLoad.ps1 handles in its summary block.
    #>
    param($Result)

    $JobInfo = $Result.result.jobInfo

    if ($JobInfo) {
        return [PSCustomObject]@{
            Processed = [int]$JobInfo.numberRecordsProcessed
            Failed    = [int]$JobInfo.numberRecordsFailed
            JobId     = $JobInfo.id
        }
    }

    return [PSCustomObject]@{
        Processed = [int]$Result.result.processedRecords
        Failed    = [int]$Result.result.failedRecords
        JobId     = $Result.result.jobId
    }
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ACCOUNT BOOTSTRAP (production export -> target org)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$OrgInfo = Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias

# The ValidateSet already refuses Full and Prod at bind time. These two checks
# close the -OrgAlias escape hatch, which deliberately bypasses the registry's
# identity checks and would otherwise be a way to aim a Dev-labelled run at any
# org at all. Same three-layer pattern as Invoke-SandboxFactoryReset.ps1.
if (-not (Test-LdgcrmAccountRebuildAllowed -Environment $Environment)) {
    throw ("SAFETY STOP: environment '$Environment' does not permit rebuilding the Account tree. " +
           "See Test-LdgcrmAccountRebuildAllowed in Common.Orgs.ps1. Nothing was run.")
}

if (-not [bool]$OrgInfo.isSandbox) {
    throw ("SAFETY STOP: '$OrgAlias' is a PRODUCTION org ($($OrgInfo.instanceUrl)). The Account bootstrap " +
           "inserts and reparents Accounts wholesale and has no production use. Nothing was run.")
}

if ($PlanOnly) {
    Write-Host "MODE: -PlanOnly. Read-only. Nothing will be written to Salesforce." -ForegroundColor Green
}
else {
    Write-Host "MODE: LIVE. This will INSERT and UPDATE Account records." -ForegroundColor Yellow
}

Write-Host ""

# ============================================================
# SOURCE
# ============================================================

if (-not $SourceFile) {
    $SourceFile = Resolve-ProdAccountExportPath -Report
}

if (-not $SourceFile) {
    throw ("No production Account export found. Put one in " +
           (Get-ProdAccountExportDirectory) +
           " - any .xls, .xlsx or .csv export of the PEO Accounts report. The name does not matter; " +
           "the newest file wins. Required columns: Account Name, Parent Account, Account Level, " +
           "Account Record Type, Account Owner, Level 1/2/3 Account.")
}

Write-Host "Source export:" -ForegroundColor Cyan
Write-Host "  $SourceFile"

$ExportRows = @(Import-ProdAccountExport -Path $SourceFile)

Write-Host "  $($ExportRows.Count) rows parsed."

# ------------------------------------------------------------
# Collapse the export into one planned Account per real Account.
#
# The report repeats rows (a hierarchy report lists a record once per grouping
# it appears under), so identical Name+Parent pairs are the SAME Account and
# must be inserted once. Rows that share a Name but have DIFFERENT parents are
# genuinely different Accounts and are all kept - which is precisely what makes
# that name ambiguous as a parent later on.
# ------------------------------------------------------------

$PlannedByKey = [ordered]@{}
$DuplicateRowCount = 0

foreach ($Row in $ExportRows) {
    $Key = (Get-NormalizedName -Name $Row.Name) + "|" + (Get-NormalizedName -Name $Row.ParentName)

    if ($PlannedByKey.Contains($Key)) {
        $DuplicateRowCount++
        continue
    }

    $PlannedByKey[$Key] = $Row
}

$Planned = @($PlannedByKey.Values)

# How many distinct Accounts share each name, per the export itself. A name
# claimed by 2+ planned Accounts can never be resolved as a parent, no matter
# what the target org looks like.
$ExportNameCounts = @{}

foreach ($Row in $Planned) {
    $Key = Get-NormalizedName -Name $Row.Name
    if (-not $ExportNameCounts.ContainsKey($Key)) { $ExportNameCounts[$Key] = 0 }
    $ExportNameCounts[$Key]++
}

$AmbiguousExportNames = @($ExportNameCounts.Keys | Where-Object { $ExportNameCounts[$_] -gt 1 })

Write-Host ""
Write-Host ("{0,-48} {1,8:N0}" -f "Export rows", $ExportRows.Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Repeated rows collapsed", $DuplicateRowCount)
Write-Host ("{0,-48} {1,8:N0}" -f "Distinct Accounts planned", $Planned.Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Root Accounts (no parent)", @($Planned | Where-Object { -not $_.ParentName }).Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Names shared by 2+ Accounts (unusable as parent)", $AmbiguousExportNames.Count)

# ============================================================
# RECORD TYPES
# ============================================================

$RecordTypeNames = @($Planned | ForEach-Object { $_.RecordType } | Where-Object { $_ } | Sort-Object -Unique)

Write-Host ""
Write-Host "Resolving Account record types: $($RecordTypeNames -join ', ')" -ForegroundColor Cyan

$RecordTypeRows = @(Invoke-SalesforceQuery `
    -Soql "SELECT Id, DeveloperName FROM RecordType WHERE SObjectType = 'Account'" `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

$RecordTypeIdByName = @{}

foreach ($RecordType in $RecordTypeRows) {
    $RecordTypeIdByName[(Get-NormalizedName -Name $RecordType.DeveloperName)] = $RecordType.Id
}

foreach ($Name in $RecordTypeNames) {
    if (-not $RecordTypeIdByName.ContainsKey((Get-NormalizedName -Name $Name))) {
        throw ("The export uses Account record type '$Name', which does not exist in $OrgAlias. " +
               "Available: $(@($RecordTypeRows | ForEach-Object { $_.DeveloperName }) -join ', ').")
    }
}

# ============================================================
# PREFLIGHT AGAINST THE TARGET ORG
# ============================================================

Write-Host ""
# --- Account owners, from the export's display-name column -----------------
# The export identifies owners by DISPLAY NAME, never email, so this uses the
# name-based resolver rather than the email one every other transform uses. A
# display name is a weaker join - see Resolve-SalesforceOwnerIdsByName for the
# duplicate/inactive guards, both of which this data actually trips.
#
# Verified 2026-08-13: all 14 distinct owner names in the production export
# match a real User, and the "SNA " prefix denotes real people (SNA MSadi ->
# mahendar.sadineni@gsa.gov), not service accounts. Most are INACTIVE in the Dev
# sandbox though, so expect a large share to resolve to nothing there.
Write-Host "Resolving Account owners from the export's display names..." -ForegroundColor Cyan
$OwnerLookup = Resolve-SalesforceOwnerIdsByName `
    -Names @($ExportRows | ForEach-Object { $_.OwnerName }) `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion
$OwnerIdByName = $OwnerLookup.IdByName
$OwnerResolvedCount = 0
$OwnerUnresolvedCount = 0

$DistinctOwnerNames = @($ExportRows | ForEach-Object { $_.OwnerName } | Where-Object { $_ } | Sort-Object -Unique)
Write-Host "$($OwnerIdByName.Count) of $($DistinctOwnerNames.Count) owner name(s) match a single ACTIVE User."
if (@($OwnerLookup.Ambiguous).Count -gt 0) {
    Write-Host "$(@($OwnerLookup.Ambiguous).Count) name(s) match MORE THAN ONE active User - left to the org default." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Reading current Accounts from $OrgAlias..." -ForegroundColor Cyan

$AccountIndex = Get-OrgAccountIndex -Org $OrgAlias -Version $ApiVersion
$ExistingTotal = 0
foreach ($Key in $AccountIndex.Keys) { $ExistingTotal += $AccountIndex[$Key].Count }

$AlreadyPresent = 0
$ToInsert = 0

foreach ($Row in $Planned) {
    $Key = Get-NormalizedName -Name $Row.Name

    if ($AccountIndex.ContainsKey($Key)) { $AlreadyPresent++ } else { $ToInsert++ }
}

Write-Host ""
Write-Host ("{0,-48} {1,8:N0}" -f "Accounts currently in $OrgAlias", $ExistingTotal)
Write-Host ("{0,-48} {1,8:N0}" -f "Planned Accounts already present by name", $AlreadyPresent)
Write-Host ("{0,-48} {1,8:N0}" -f "Planned Accounts missing (will insert)", $ToInsert)
Write-Host ""
Write-Host "Parent links are resolved pass by pass and counted as they happen -" -ForegroundColor DarkGray
Write-Host "they can't be totalled up front, because a parent's Id doesn't exist" -ForegroundColor DarkGray
Write-Host "until the pass that creates it." -ForegroundColor DarkGray

New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null

# ============================================================
# CONFIRMATION
# ============================================================

if (-not $PlanOnly) {
    Write-Host ""
    Write-Host "This will write to Account in $($OrgAlias): up to $ToInsert inserts plus" -ForegroundColor Yellow
    Write-Host "parent-link updates, across up to $MaxPasses passes." -ForegroundColor Yellow

    # Kept as a belt-and-braces no-op: it returns $true for every environment
    # this script can still target, but if someone ever widens the ValidateSet
    # the production guard is already wired in rather than needing to be
    # remembered.
    if (-not (Assert-LdgcrmProductionConsent -Environment $Environment -Action "bootstrap the Account tree from $([System.IO.Path]::GetFileName($SourceFile))")) {
        exit 0
    }

    Write-Host ""
    if (-not (Assert-LdgcrmTypedConfirmation `
            -Token "BOOTSTRAP" `
            -Provided $Confirmation `
            -Action "bootstrap the Account tree in $OrgAlias from $([System.IO.Path]::GetFileName($SourceFile))")) {
        Write-Host ""
        Write-Host "Bootstrap cancelled. Nothing was written." -ForegroundColor Yellow
        exit 0
    }
}

# ============================================================
# PASSES
# ============================================================

# Planned Accounts still waiting to be created, keyed as Name|Parent.
$Pending = [System.Collections.Generic.List[object]]::new()
foreach ($Row in $Planned) { $Pending.Add($Row) }

# Accounts that exist but whose ParentId still needs setting. Recomputed each
# pass from live org state, so nothing is assumed to have persisted.
$PassSummaries = [System.Collections.Generic.List[object]]::new()
$UnresolvedParents = [System.Collections.Generic.List[object]]::new()
$ParentConflicts = [System.Collections.Generic.List[object]]::new()
$AmbiguousSelf = [System.Collections.Generic.List[object]]::new()

$TotalInserted = 0
# Passes whose Bulk result could not be parsed - see the guard in the write
# block. Tracked so the summary can say the insert total is a FLOOR rather than
# letting it read as exact.
$UnparseablePasses = 0
$TotalParented = 0
$TotalInsertFailed = 0
$TotalUpdateFailed = 0

for ($Pass = 1; $Pass -le $MaxPasses; $Pass++) {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " PASS $Pass" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    if ($Pass -gt 1) {
        # Re-read: the previous pass's inserts are what make this pass's
        # parents resolvable.
        $AccountIndex = Get-OrgAccountIndex -Org $OrgAlias -Version $ApiVersion
    }

    $InsertRows = [System.Collections.Generic.List[object]]::new()
    $UpdateRows = [System.Collections.Generic.List[object]]::new()
    $StillPending = [System.Collections.Generic.List[object]]::new()
    $QueuedUpdateIds = @{}

    # The review lists ACCUMULATE across passes - they are never cleared. A row
    # is only ever added to one of them at the moment it is dropped from
    # $Pending, so it can be reported at most once; clearing per pass would
    # mean the final CSVs only ever showed whatever the last pass happened to
    # find, silently discarding everything reported earlier.
    $UnresolvedAtPassStart = $UnresolvedParents.Count
    $ConflictsAtPassStart = $ParentConflicts.Count
    $AmbiguousAtPassStart = $AmbiguousSelf.Count

    foreach ($Row in $Pending) {
        $NameKey = Get-NormalizedName -Name $Row.Name
        $ParentKey = Get-NormalizedName -Name $Row.ParentName

        # --- resolve the parent, if this row has one -------------------
        $ParentId = ""
        $ParentResolvable = $true

        if ($ParentKey) {
            if ($ExportNameCounts.ContainsKey($ParentKey) -and $ExportNameCounts[$ParentKey] -gt 1) {
                # The export itself defines 2+ different Accounts with this
                # name. No amount of loading makes it resolvable.
                $ParentResolvable = $false
            }
            else {
                $ParentAccount = Get-UniqueOrgAccount -Index $AccountIndex -Name $Row.ParentName

                if ($null -eq $ParentAccount) {
                    if ($AccountIndex.ContainsKey($ParentKey)) {
                        # Present but duplicated in the target org.
                        $ParentResolvable = $false
                    }
                    else {
                        # Simply not created yet - try again next pass.
                        $StillPending.Add($Row)
                        continue
                    }
                }
                else {
                    $ParentId = $ParentAccount.Id
                }
            }
        }

        if (-not $ParentResolvable) {
            $UnresolvedParents.Add([PSCustomObject]@{
                AccountName  = $Row.Name
                ParentName   = $Row.ParentName
                AncestorPath = $Row.AncestorPath
                Reason       = "Parent name is shared by more than one Account - refusing to guess"
                Action       = if ($StrictHierarchy) { "Skipped entirely (-StrictHierarchy)" } else { "Insert without a parent" }
                SourceRow    = $Row.SourceRow
            })

            if ($StrictHierarchy) { continue }

            $ParentId = ""
        }

        # --- does this Account already exist? --------------------------
        $Existing = $null

        if ($AccountIndex.ContainsKey($NameKey)) {

            # THE MANY-PLANNED-TO-ONE-EXISTING TRAP.
            # When the export defines 2+ DISTINCT Accounts sharing a name (14
            # of them: "Office of the Inspector General" under four different
            # departments, and so on) but the target org holds fewer records
            # under that name, there is no way to tell which planned row the
            # existing record is. Matching by name anyway makes every one of
            # those planned rows resolve to the SAME Account and queue its own
            # parent link for it - 14 Accounts got 2-4 conflicting ParentId
            # writes each in the first dry run, last-write-wins, with nothing
            # in the output to show a choice had been made.
            #
            # An earlier seed (Build-ProdAccountSeed.ps1) deduped these by
            # name, which is why the org has one where production has several.
            # Reported, never guessed.
            if ($ExportNameCounts[$NameKey] -gt 1 -and $AccountIndex[$NameKey].Count -lt $ExportNameCounts[$NameKey]) {
                $AmbiguousSelf.Add([PSCustomObject]@{
                    AccountName  = $Row.Name
                    ParentName   = $Row.ParentName
                    AncestorPath = $Row.AncestorPath
                    Reason       = "Export defines $($ExportNameCounts[$NameKey]) distinct Accounts with this name but the org has $($AccountIndex[$NameKey].Count) - cannot tell which is which"
                    Action       = "Skipped - no parent set"
                    SourceRow    = $Row.SourceRow
                })
                continue
            }

            $Existing = Get-UniqueOrgAccount -Index $AccountIndex -Name $Row.Name

            if ($null -eq $Existing) {
                # The name is duplicated in the target org, so we can't tell
                # which record this planned row corresponds to. Inserting
                # another would deepen the problem.
                $AmbiguousSelf.Add([PSCustomObject]@{
                    AccountName  = $Row.Name
                    ParentName   = $Row.ParentName
                    AncestorPath = $Row.AncestorPath
                    Reason       = "$($AccountIndex[$NameKey].Count) Accounts in the org already share this name"
                    Action       = "Skipped - resolve the duplicates, then re-run"
                    SourceRow    = $Row.SourceRow
                })
                continue
            }
        }

        if ($null -eq $Existing) {
            # ParentId is ALWAYS present, empty when there is none. Every row
            # in a pass must carry an identical property set: ConvertTo-Csv
            # derives its header from the FIRST object only, so a pass whose
            # first row happened to be parentless would silently drop the
            # ParentId of every other row in the file - a wrong load with no
            # error anywhere. Bulk API 2.0 reads an empty value as "not
            # supplied", which is exactly right for a root.
            # OwnerId, from the export's "Account Owner" DISPLAY NAME. Blank
            # where that name has no single active User, which leaves the record
            # on the loading user - the org default for an insert. Deliberately
            # NOT the migration's fallback owner: this bootstrap recreates a
            # starting universe of Accounts that the migration does not own, so
            # inventing an owner for them would misrepresent the baseline.
            $OwnerId = ""
            if ($Row.OwnerName -and $OwnerIdByName.ContainsKey($Row.OwnerName)) {
                $OwnerId = $OwnerIdByName[$Row.OwnerName]
                $OwnerResolvedCount++
            }
            elseif ($Row.OwnerName) {
                $OwnerUnresolvedCount++
            }

            $InsertRows.Add([PSCustomObject][ordered]@{
                Name         = $Row.Name
                RecordTypeId = $RecordTypeIdByName[(Get-NormalizedName -Name $Row.RecordType)]
                ParentId     = $ParentId
                OwnerId      = $OwnerId
            })
            continue
        }

        # --- exists: only ever FILL IN a blank parent ------------------
        if (-not $ParentId) { continue }

        if ($Existing.ParentId -eq $ParentId) { continue }

        if ($Existing.ParentId) {
            $ParentConflicts.Add([PSCustomObject]@{
                AccountName      = $Row.Name
                AccountId        = $Existing.Id
                CurrentParentId  = $Existing.ParentId
                ExportParentName = $Row.ParentName
                ExportParentId   = $ParentId
                Reason           = "Already parented to a different Account - existing hierarchy wins"
                Action           = "Left unchanged"
                SourceRow        = $Row.SourceRow
            })
            continue
        }

        # Belt and braces: $AccountIndex is a snapshot taken at the top of the
        # pass, so two planned rows resolving to the same record would both see
        # a blank ParentId and both queue an update. The mapping guard above
        # should already have caught every such case; this makes it impossible
        # for a bulk file to contain the same Id twice regardless.
        if ($QueuedUpdateIds.ContainsKey($Existing.Id)) {
            if ($QueuedUpdateIds[$Existing.Id] -ne $ParentId) {
                $ParentConflicts.Add([PSCustomObject]@{
                    AccountName      = $Row.Name
                    AccountId        = $Existing.Id
                    CurrentParentId  = $QueuedUpdateIds[$Existing.Id]
                    ExportParentName = $Row.ParentName
                    ExportParentId   = $ParentId
                    Reason           = "A different planned row already claimed this Account with another parent in the same pass"
                    Action           = "Left unchanged - first claim kept"
                    SourceRow        = $Row.SourceRow
                })
            }
            continue
        }

        $QueuedUpdateIds[$Existing.Id] = $ParentId

        $UpdateRows.Add([PSCustomObject]@{
            Id       = $Existing.Id
            ParentId = $ParentId
        })
    }

    $UnresolvedThisPass = $UnresolvedParents.Count - $UnresolvedAtPassStart
    $ConflictsThisPass = $ParentConflicts.Count - $ConflictsAtPassStart
    $AmbiguousThisPass = $AmbiguousSelf.Count - $AmbiguousAtPassStart

    Write-Host ""
    Write-Host ("{0,-40} {1,8:N0}" -f "Inserts this pass", $InsertRows.Count)
    Write-Host ("{0,-40} {1,8:N0}" -f "Parent links this pass", $UpdateRows.Count)
    Write-Host ("{0,-40} {1,8:N0}" -f "Waiting on a parent (next pass)", $StillPending.Count)
    Write-Host ("{0,-40} {1,8:N0}" -f "Unresolvable parent (reported)", $UnresolvedThisPass)
    Write-Host ("{0,-40} {1,8:N0}" -f "Ambiguous in target org (skipped)", $AmbiguousThisPass)
    Write-Host ("{0,-40} {1,8:N0}" -f "Parent conflicts (left alone)", $ConflictsThisPass)

    $InsertFile = Join-Path $RunDirectory ("pass-{0:D2}-insert.csv" -f $Pass)
    $UpdateFile = Join-Path $RunDirectory ("pass-{0:D2}-parent-update.csv" -f $Pass)

    if ($InsertRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $InsertRows.ToArray() -Path $InsertFile }
    if ($UpdateRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $UpdateRows.ToArray() -Path $UpdateFile }

    $PassSummaries.Add([PSCustomObject]@{
        Pass               = $Pass
        Inserts            = $InsertRows.Count
        ParentLinks        = $UpdateRows.Count
        WaitingOnParent    = $StillPending.Count
        UnresolvableParent = $UnresolvedThisPass
        AmbiguousInOrg     = $AmbiguousThisPass
        ParentConflicts    = $ConflictsThisPass
    })

    if ($InsertRows.Count -eq 0 -and $UpdateRows.Count -eq 0) {
        Write-Host ""
        Write-Host "Nothing left to do - the tree has settled." -ForegroundColor Green

        if ($StillPending.Count -gt 0) {
            # Rows still waiting with nothing left to create them means a cycle
            # or a parent that isn't in the export at all.
            Write-Host ""
            Write-Host "$($StillPending.Count) row(s) are still waiting on a parent that will never arrive." -ForegroundColor Yellow
            Write-Host "Written to the review CSV as orphans." -ForegroundColor Yellow

            foreach ($Row in $StillPending) {
                $UnresolvedParents.Add([PSCustomObject]@{
                    AccountName  = $Row.Name
                    ParentName   = $Row.ParentName
                    AncestorPath = $Row.AncestorPath
                    Reason       = "Parent Account never appeared in the org (missing from the export, or a cycle)"
                    Action       = "Not created"
                    SourceRow    = $Row.SourceRow
                })
            }
        }

        break
    }

    if ($PlanOnly) {
        Write-Host ""
        Write-Host "-PlanOnly: stopping after the first pass. Later passes can't be" -ForegroundColor Green
        Write-Host "planned without actually creating this pass's parents." -ForegroundColor Green
        break
    }

    # --- write ---------------------------------------------------------

    if ($InsertRows.Count -gt 0) {
        Write-Host ""
        Write-Host "Inserting $($InsertRows.Count) Account(s)..." -ForegroundColor Yellow

        $InsertResult = Invoke-BulkCsv -Subcommand "import" -CsvFile $InsertFile -Org $OrgAlias -Version $ApiVersion -Wait $WaitMinutes
        $Counts = Get-BulkCounts -Result $InsertResult

        # UNPARSEABLE RESULT GUARD. Get-BulkCounts knows two JSON shapes; the CLI
        # has at least one more. On 2026-08-13 pass 2 submitted 336 Accounts and
        # this reported "inserted 0, failed 0 (job )" - no job id, no counts -
        # while all 336 had in fact loaded. The run then under-reported its total
        # by 334 (said 249, actually 583).
        #
        # Under-reporting an INSERT is the dangerous direction: an operator who
        # believes nothing loaded re-runs the pass and creates duplicate
        # Accounts, which nothing here would catch (bootstrapped Accounts carry
        # no external ID, so they cannot be deduplicated afterwards by key).
        # So say plainly that the count is unknown rather than printing a zero
        # that looks like a fact.
        $Unparseable = ($Counts.Processed -eq 0 -and -not $Counts.JobId)

        if ($Unparseable) {
            Write-Host ("  !! Could not read the job result for this pass. {0:N0} row(s) were submitted; " -f $InsertRows.Count) -ForegroundColor Red
            Write-Host "     how many landed is UNKNOWN from here - the CLI returned a shape this script" -ForegroundColor Red
            Write-Host "     does not recognise. They may well have inserted." -ForegroundColor Red
            Write-Host "     DO NOT re-run this pass before checking the org: a second run would create" -ForegroundColor Red
            Write-Host "     duplicate Accounts, and bootstrapped Accounts carry no external ID to dedupe on." -ForegroundColor Red
            Write-Host ("     Check with: sf data query -q ""SELECT COUNT() FROM Account"" --target-org {0}" -f $OrgAlias) -ForegroundColor DarkGray
            $UnparseablePasses++
        }
        else {
            $Succeeded = $Counts.Processed - $Counts.Failed
            $TotalInserted += $Succeeded
            $TotalInsertFailed += $Counts.Failed

            Write-Host ("  inserted {0:N0}, failed {1:N0} (job {2})" -f $Succeeded, $Counts.Failed, $Counts.JobId)

            if ($Counts.Failed -gt 0) {
                Write-Host "  Row failures - see the job result via: sf data bulk results --job-id $($Counts.JobId) --target-org $OrgAlias" -ForegroundColor Yellow
            }
        }
    }

    if ($UpdateRows.Count -gt 0) {
        Write-Host ""
        Write-Host "Setting $($UpdateRows.Count) parent link(s)..." -ForegroundColor Yellow

        $UpdateResult = Invoke-BulkCsv -Subcommand "update" -CsvFile $UpdateFile -Org $OrgAlias -Version $ApiVersion -Wait $WaitMinutes
        $Counts = Get-BulkCounts -Result $UpdateResult

        $Succeeded = $Counts.Processed - $Counts.Failed
        $TotalParented += $Succeeded
        $TotalUpdateFailed += $Counts.Failed

        Write-Host ("  parented {0:N0}, failed {1:N0} (job {2})" -f $Succeeded, $Counts.Failed, $Counts.JobId)

        if ($Counts.Failed -gt 0) {
            Write-Host "  Row failures - see the job result via: sf data bulk results --job-id $($Counts.JobId) --target-org $OrgAlias" -ForegroundColor Yellow
        }
    }

    # Everything acted on this pass is done; only the waiting rows carry over.
    # Rows that were inserted this pass need one more visit so their own
    # children can be parented - that happens naturally because their children
    # are in $StillPending.
    $Pending = $StillPending

    if ($Pending.Count -eq 0) {
        Write-Host ""
        Write-Host "All planned Accounts have been processed." -ForegroundColor Green
        break
    }

    if ($Pass -eq $MaxPasses) {
        Write-Host ""
        Write-Host "Reached -MaxPasses ($MaxPasses) with $($Pending.Count) row(s) still pending." -ForegroundColor Red
        Write-Host "Re-run to continue; the script is idempotent." -ForegroundColor Yellow
    }
}

# ============================================================
# REVIEW OUTPUT
# ============================================================

$SummaryFile = Join-Path $RunDirectory "pass-summary.csv"
$PassSummaries | Export-Csv -LiteralPath $SummaryFile -NoTypeInformation -Encoding UTF8

if ($UnresolvedParents.Count -gt 0) {
    $UnresolvedParents | Export-Csv -LiteralPath (Join-Path $RunDirectory "review-unresolvable-parents.csv") -NoTypeInformation -Encoding UTF8
}

if ($AmbiguousSelf.Count -gt 0) {
    $AmbiguousSelf | Export-Csv -LiteralPath (Join-Path $RunDirectory "review-ambiguous-in-org.csv") -NoTypeInformation -Encoding UTF8
}

if ($ParentConflicts.Count -gt 0) {
    $ParentConflicts | Export-Csv -LiteralPath (Join-Path $RunDirectory "review-parent-conflicts.csv") -NoTypeInformation -Encoding UTF8
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host (" ACCOUNT BOOTSTRAP {0}" -f $(if ($PlanOnly) { "PLAN COMPLETE" } else { "COMPLETE" })) -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

$PassSummaries | Format-Table -AutoSize

if (-not $PlanOnly) {
    if ($UnparseablePasses -gt 0) {
        Write-Host ("{0,-40} {1,8:N0}  <- AT LEAST this many; see below" -f "Accounts inserted", $TotalInserted) -ForegroundColor Yellow
    }
    else {
        Write-Host ("{0,-40} {1,8:N0}" -f "Accounts inserted", $TotalInserted)
    }
    Write-Host ("{0,-40} {1,8:N0}" -f "Parent links set", $TotalParented)

    if ($UnparseablePasses -gt 0) {
        Write-Host ""
        Write-Host ("  !! {0} pass(es) returned a Bulk result this script could not read, so the" -f $UnparseablePasses) -ForegroundColor Red
        Write-Host "     'Accounts inserted' figure above is a FLOOR, not a total. The verification" -ForegroundColor Red
        Write-Host "     line below is measured against the org and is the number to trust." -ForegroundColor Red
    }

    if ($TotalInsertFailed -gt 0 -or $TotalUpdateFailed -gt 0) {
        Write-Host ("{0,-40} {1,8:N0}" -f "Insert row failures", $TotalInsertFailed) -ForegroundColor Red
        Write-Host ("{0,-40} {1,8:N0}" -f "Parent-link row failures", $TotalUpdateFailed) -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "Verifying final state..." -ForegroundColor Cyan

    $FinalIndex = Get-OrgAccountIndex -Org $OrgAlias -Version $ApiVersion
    $FinalTotal = 0
    $FinalParented = 0

    foreach ($Key in $FinalIndex.Keys) {
        foreach ($Account in $FinalIndex[$Key]) {
            $FinalTotal++
            if ($Account.ParentId) { $FinalParented++ }
        }
    }

    Write-Host ""
    Write-Host ("{0,-40} {1,8:N0}" -f "Accounts in $OrgAlias now", $FinalTotal)
    Write-Host ("{0,-40} {1,8:N0}" -f "...with a parent Account", $FinalParented)
}

Write-Host ""
Write-Host "Run output:" -ForegroundColor Cyan
Write-Host $RunDirectory

if ($PlanOnly) {
    Write-Host ""
    Write-Host "This was a dry run. Re-run without -PlanOnly to apply it." -ForegroundColor Green
}

}
finally {
    Stop-ScriptLog
}

