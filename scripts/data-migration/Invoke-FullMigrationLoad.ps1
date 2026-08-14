#Requires -Version 5.1

<#
    THE FULL MIGRATION LOAD
    =======================
    Runs every transform and every load, in dependency order, as one operation.

    WHY THIS EXISTS
      The load order is a hard dependency chain - parents before children,
      Opportunity before Application, Impediment before its junction, Notes dead
      last - and until now it lived only in prose (docs/engineering/ARCHITECTURE.md "Load order")
      and a checklist a human walked by hand. That is fine for a developer who
      has read both. It is not fine for the Operations team, who will run this
      against QA, Full and eventually production, and for whom "run these
      eighteen commands in exactly this order" is a defect waiting to happen.

      Getting the order wrong does not fail loudly. It silently WITHHOLDS rows:
      every transform skips records whose parent isn't in the org yet, so a
      mis-ordered run produces a smaller migration and a clean-looking summary.
      That is the failure this script exists to prevent.

    WHAT IT DOES NOT DO
      It does not reset the org. Invoke-SandboxFactoryReset.ps1 is deliberately
      separate: it is destructive, and it is blocked from production entirely,
      whereas this script legitimately targets production. Fusing them would
      mean the production-capable script contained a delete path.

      It does not decide anything. Every transform and loader keeps its own
      preflight, its own review CSVs and its own confirmation; this only
      sequences them.

    HOW A RUN IS APPROVED
      -Confirmation "LOAD" is passed through to every load step, so the whole
      sequence is approved once rather than eighteen times. Against production
      -ProductionConfirmation <alias> is ALSO required, by every step, and is
      deliberately not stored anywhere - see the notes on that parameter.

      -PlanOnly runs every TRANSFORM and no loads. Transforms are read-only, so
      this doubles as the readiness check: it proves each script runs, queries
      the org successfully, and reports exactly how many rows each step would
      load, without writing anything.

    RESUMING
      Steps run as child processes and the sequence stops at the first failure,
      because everything after a failed step would silently withhold rows that
      depend on it. -StartAtStep resumes from a named step once the cause is
      fixed; -OnlySteps runs a subset. Both take the Name column printed in the
      plan.
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    [string]$OrgAlias = "",

    # Approve every load step in the sequence. Same token the individual
    # scripts take: -Confirmation "LOAD".
    [string]$Confirmation = "",

    # Required IN ADDITION to -Confirmation when -Environment Prod. Two separate
    # tokens on purpose: an operator who automated a sandbox run must not be
    # able to retarget it at production by changing -Environment alone.
    #
    # Do not bake this into a saved script or a CI variable. A production
    # migration is a scheduled, supervised event, not a job that can fire on its
    # own.
    [string]$ProductionConfirmation = "",

    # Run every transform, load nothing. Read-only, and the readiness check:
    # proves each script runs and reports what it would load.
    [switch]$PlanOnly,

    # Resume from a named step (see the Name column in the plan).
    [string]$StartAtStep = "",

    # Comma-separated subset of step names to run.
    [string]$OnlySteps = "",

    # Rebuild the Account tree from the production export first. Sandbox only -
    # in production the Accounts already exist and this would be wrong.
    [switch]$BootstrapAccounts,

    # Keep going after a failed step. OFF by default: everything downstream of a
    # failure withholds rows that depend on it, so continuing usually produces a
    # quietly incomplete migration rather than an obvious error.
    [switch]$ContinueOnError
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")
. (Join-Path $PSScriptRoot "Common.LoadReport.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Invoke-FullMigrationLoad"

# When this run began. Used to tell a CSV this run produced from one left over
# by an earlier run - see the staleness check in the step loop.
$RunStart = Get-Date

# =============================================================================
# THE SEQUENCE
# =============================================================================
# Order is the dependency chain from docs/engineering/ARCHITECTURE.md. Each entry is data, not
# code, so adding an object is a table edit.
#
#   Name        short handle for -StartAtStep / -OnlySteps
#   Build       transform script (read-only; writes a CSV)
#   Object      Salesforce object for the load step
#   Csv         file in data/salesforce-loads/ the transform produces
#   Operation   Upsert (default) | Update | Insert
#   Loader      Standard (Invoke-SalesforceLoad.ps1) | Notes (Invoke-NotesLoad.ps1)
#   TriggerOff  TriggerControls__c record to disable for the load
#   Why         one line explaining the position, printed in the plan
#   ExpectedFailures
#               error substrings that mark a row failure as a KNOWN, ACCEPTED
#               outcome for this object. Anything else is a real failure and
#               still halts. Kept here, next to the object, rather than inside
#               the loader - the policy is per-object and reviewable in one
#               place. See the classification block in Invoke-SalesforceLoad.ps1.
$Steps = @(
    [ordered]@{
        Name = "Impediment"; Build = "Build-ImpedimentLoad.ps1"
        Object = "LDGCRM_Impediment__c"; Csv = "LDGCRM_Impediment__c-upsert.csv"
        Why = "Independent parent - no lookups, so it can go first."
    }
    [ordered]@{
        Name = "Account"; Build = "Build-AccountReconciliation.ps1"
        Object = "Account"; Csv = "Account-update.csv"; Operation = "Update"
        Why = "UPDATE, not upsert - Accounts pre-exist and are matched, never created."
    }
    [ordered]@{
        Name = "PartnerAccount"; Build = "Build-PartnerAccountLoad.ps1"
        Object = "LDGCRM_Partner_Account__c"; Csv = "LDGCRM_Partner_Account__c-upsert.csv"
        Why = "Master-Detail child of Account - needs Account reconciled first."
        # Parent Account is one of the unmatched Airtable rows. Documented in
        # AIRTABLE-DATA-QUALITY-REQUESTS.md; 2 of 94 on the 2026-08-13 reload,
        # ~20 of 94 before the Account work.
        ExpectedFailures = @("Foreign key external ID")
    }
    [ordered]@{
        Name = "Contact"; Build = "Build-ContactLoad.ps1"
        Object = "Contact"; Csv = "Contact-upsert.csv"; TriggerOff = "Contact"
        Why = "Disables FCIC's Contact trigger, which creates a junk Account per blank AccountId."
        # The org's first+last-name duplicate rule. Not in this repo's metadata
        # (the manifest is app-scoped), so it is invisible to any amount of
        # reading force-app. Catches the same person under two email addresses -
        # 12 of 1,882 on the 2026-08-13 reload.
        ExpectedFailures = @("DUPLICATES_DETECTED")
    }
    [ordered]@{
        Name = "Opportunity"; Build = "Build-OpportunityLoad.ps1"
        Object = "Opportunity"; Csv = "Opportunity-upsert.csv"
        Why = "Must precede Application - an unresolvable Opportunity lookup fails the whole row."
    }
    [ordered]@{
        Name = "Application"; Build = "Build-ApplicationLoad.ps1"
        Object = "LDGCRM_application__c"; Csv = "LDGCRM_application__c-upsert.csv"
        Why = "Needs Partner Account (required) and Opportunity (optional but fatal if dangling)."
    }
    [ordered]@{
        # NAMED FOR THE FIELD IT FILLS, NOT FOR RECORDS IT CREATES - it creates
        # none. The previous name, "BrokerParent", read as "load the broker
        # parents", which invites the reasonable objection that parents should
        # surely be loaded BEFORE their children. They are: a broker parent IS
        # an ordinary Application, created by the Application step above along
        # with everything else. This step only sets a pointer on the child.
        Name = "PopulateBrokerParent"; Build = ""
        Object = "LDGCRM_application__c"; Csv = "LDGCRM_application__c-broker-parent-upsert.csv"
        Why = "SECOND PASS - sets LDGCRM_Broker_App_Parent__c on Applications the step above already created. Creates nothing; Bulk can't resolve a self-lookup inside its own batch."
    }
    [ordered]@{
        Name = "OpportunityImpediment"; Build = "Build-OpportunityImpedimentLoad.ps1"
        Object = "LDGCRM_Opportunity_Impediment__c"; Csv = "LDGCRM_Opportunity_Impediment__c-upsert.csv"
        Why = "Two Master-Details - both Impediment and Opportunity must already exist."
    }
    [ordered]@{
        Name = "ApplicationContact"; Build = "Build-ApplicationContactLoad.ps1"
        Object = "LDGCRM_Application_Contact__c"; Csv = "LDGCRM_Application_Contact__c-upsert.csv"
        Why = "Junction - needs Application and Contact."
    }
    [ordered]@{
        Name = "OpportunityContactRole"; Build = "Build-OpportunityContactRoleLoad.ps1"
        Object = "OpportunityContactRole"; Csv = "OpportunityContactRole-insert.csv"; Operation = "Insert"
        Why = "INSERT + read-then-diff - Salesforce forbids External IDs on this object."
    }
    [ordered]@{
        Name = "Notes"; Build = "Build-NotesLoad.ps1"
        Object = "ContentNote"; Csv = "ContentNote-staging.csv"; Loader = "Notes"
        Why = "LAST - a note attaches to a record that must already exist. Loads over REST, not Bulk."
    }
)

function Get-StepProperty {
    param($Step, [string]$Key, $Default = "")
    if ($Step.Contains($Key) -and $Step[$Key]) { return $Step[$Key] }
    return $Default
}

function Invoke-PreflightChecks {
    <#
        Everything that should stop a run BEFORE the first row is written.

        Each check is cheap and read-only. They exist because every one of them
        has actually gone wrong at least once in this migration, and all of them
        fail SILENTLY at load time rather than loudly: a stale Airtable export
        migrates yesterday's data, a missing Market Segment leaves the
        before-save Flows with nothing to assign, an unresolvable fallback owner
        aborts halfway through the sequence rather than at the start.

        Returns a hashtable of findings; the caller decides whether to stop.
    #>
    param([string]$Org, [string]$Version, [string]$Env)

    $Findings = [ordered]@{ Blocking = @(); Warning = @() }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " PRE-FLIGHT" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # 1. Airtable export present, and how stale. The whole migration reads these
    #    files; loading from a week-old pull is the quietest possible mistake.
    $ExportDir = Join-Path (Get-RepoRoot) "data\airtable-exports"
    $Exports = @(Get-ChildItem -Path $ExportDir -Filter *.json -ErrorAction SilentlyContinue)

    if ($Exports.Count -eq 0) {
        $Findings.Blocking += "No Airtable export found in $ExportDir. Run Get-AirtableExport.ps1 first."
        Write-Host "  Airtable export        MISSING" -ForegroundColor Red
    }
    else {
        $Newest = ($Exports | Sort-Object LastWriteTime | Select-Object -Last 1)
        $AgeDays = [math]::Round(((Get-Date) - $Newest.LastWriteTime).TotalDays, 1)
        Write-Host ("  Airtable export        {0} file(s), newest {1} day(s) old" -f $Exports.Count, $AgeDays)
        if ($AgeDays -gt 7) {
            $Findings.Warning += "Airtable export is $AgeDays days old. Re-run Get-AirtableExport.ps1 unless you deliberately want this snapshot."
        }
    }

    # 2. Market Segment. Not loaded by this pipeline and not recreated by it, but
    #    three before-save Flows derive from it - if it is empty, every Account,
    #    Opportunity and Application loads with a blank segment and nothing
    #    errors.
    $Segments = @(Invoke-SalesforceQuery -Soql "SELECT Id FROM LDGCRM_Market_Segment__c" -OrgAlias $Org -ApiVersion $Version).Count
    Write-Host ("  Market Segments        {0}" -f $Segments)
    if ($Segments -eq 0) {
        $Findings.Blocking += "No LDGCRM_Market_Segment__c records. The before-save Flows have nothing to assign; every downstream record would load with a blank segment."
    }

    # 3. Fallback owner. Every transform resolves it and throws if it can't -
    #    better to find that here than eight steps in.
    try {
        $OwnerId = Resolve-FallbackOwnerId -Email "peter.marks@gsa.gov" -OrgAlias $Org -ApiVersion $Version
        Write-Host ("  Fallback owner         resolved ({0})" -f $OwnerId)
    }
    catch {
        $Findings.Blocking += "Fallback owner did not resolve: $($_.Exception.Message)"
        Write-Host "  Fallback owner         UNRESOLVED" -ForegroundColor Red
    }

    # 4. The FCIC trigger kill switch the Contact step depends on. If the record
    #    is missing, that step fails at the point it tries to flip it - after
    #    several other objects have already loaded.
    $Controls = @(Invoke-SalesforceQuery -Soql "SELECT Id, On__c FROM TriggerControls__c WHERE Name = 'Contact'" -OrgAlias $Org -ApiVersion $Version)
    if ($Controls.Count -eq 1) {
        Write-Host ("  Contact trigger switch present (currently On__c={0})" -f $Controls[0].On__c)
    }
    else {
        $Findings.Blocking += "Expected exactly one TriggerControls__c record named 'Contact', found $($Controls.Count). The Contact step cannot bypass the FCIC trigger without it, and loading Contact with that trigger active creates a junk Account per blank AccountId."
        Write-Host "  Contact trigger switch NOT USABLE" -ForegroundColor Red
    }

    # 5. Notes need the related list on the parent layouts or they load
    #    successfully and are invisible. Layout metadata isn't queryable here, so
    #    this is a reminder rather than a check - stated because it has already
    #    been missed once.
    Write-Host "  Note related lists     not checkable via API - confirm RelatedContentNoteList" -ForegroundColor DarkGray
    Write-Host "                         is on the Partner Account and Application layouts" -ForegroundColor DarkGray

    return $Findings
}

function Save-RestorePoint {
    <#
        Captures what the org looks like BEFORE the load, for verification
        afterwards and as the basis of any rollback.

        WHY A PRE-IMAGE AND NOT JUST COUNTS: undoing an INSERT is easy - delete
        by external ID. Undoing an UPDATE is not, and this pipeline does update
        records it does not own. Build-AccountReconciliation.ps1 writes
        LDGCRM_External_ID__c, Market Segment and Type onto Accounts that existed
        long before the migration; the ownership pass overwrites OwnerId. Once
        those are overwritten the previous values are gone unless something
        wrote them down first. Nothing did, until this.

        Deleting a migrated record does NOT restore an updated one. That
        asymmetry is the single most important thing to understand about rolling
        this back.
    #>
    param([string]$Org, [string]$Version, [string]$Directory)

    Write-Host ""
    Write-Host "Capturing restore point..." -ForegroundColor Cyan

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null

    # Pre-image of the one object the migration UPDATES rather than creates.
    # Everything else it creates outright, and creations are undone by deleting.
    $Accounts = @(Invoke-SalesforceQuery `
        -Soql ("SELECT Id, Name, LDGCRM_External_ID__c, Type, OwnerId, " +
               "LDGCRM_Market_Segment__c FROM Account") `
        -OrgAlias $Org -ApiVersion $Version)

    $AccountFile = Join-Path $Directory "restore-point-Account.csv"
    $Accounts | Select-Object Id, Name, LDGCRM_External_ID__c, Type, OwnerId, LDGCRM_Market_Segment__c |
        Export-Csv -LiteralPath $AccountFile -NoTypeInformation -Encoding UTF8
    Write-Host ("  Account pre-image      {0} record(s) -> {1}" -f $Accounts.Count, (Split-Path -Leaf $AccountFile))

    # Baseline counts for every object the sequence touches, so the post-load
    # check compares against measured reality rather than a number in a doc.
    $Objects = @(
        "Account", "LDGCRM_Partner_Account__c", "Contact", "Opportunity",
        "LDGCRM_application__c", "LDGCRM_Impediment__c",
        "LDGCRM_Opportunity_Impediment__c", "LDGCRM_Application_Contact__c",
        "OpportunityContactRole", "LDGCRM_Market_Segment__c"
    )

    # WHICH external IDs were already here, not just how many.
    #
    # A count cannot answer the only question a rollback has to get right:
    # did THIS run create this record, or was it already in the org? Deleting
    # by external ID alone is safe in a sandbox, where the tagged set and the
    # migration's own output are the same thing - and wrong in production,
    # where a second run would delete the first run's records. The difference
    # between "created by this run" and "already present" is exactly the set
    # captured here, and it can only be captured BEFORE the load.
    #
    # This costs no extra queries: the tagged count below was already reading
    # these rows and discarding everything but the row count.
    $Baseline = [System.Collections.Generic.List[object]]::new()
    foreach ($Object in $Objects) {
        $Total = @(Invoke-SalesforceQuery -Soql "SELECT Id FROM $Object" -OrgAlias $Org -ApiVersion $Version).Count
        $Tagged = 0
        try {
            $Existing = @(Invoke-SalesforceQuery `
                -Soql "SELECT Id, LDGCRM_External_ID__c FROM $Object WHERE LDGCRM_External_ID__c != null" `
                -OrgAlias $Org -ApiVersion $Version)
            $Tagged = $Existing.Count

            # Written even when empty: an empty file is the positive statement
            # "nothing was tagged here before the run", which is what lets a
            # rollback delete the whole tagged set with confidence. A MISSING
            # file has to be read as "unknown", and unknown must not authorise
            # a delete.
            $Existing | Select-Object Id, LDGCRM_External_ID__c |
                Export-Csv -LiteralPath (Join-Path $Directory "external-ids-$Object.csv") -NoTypeInformation -Encoding UTF8
        }
        catch { $Tagged = -1 }   # object has no external ID field

        $Baseline.Add([PSCustomObject]@{ Object = $Object; Total = $Total; ExternalIdTagged = $Tagged })
    }

    $Captured = @($Baseline | Where-Object { $_.ExternalIdTagged -ge 0 })
    Write-Host ("  Pre-run external IDs   {0} object(s), {1:N0} tagged record(s) -> external-ids-*.csv" -f `
        $Captured.Count, (($Captured | Measure-Object -Property ExternalIdTagged -Sum).Sum))

    $BaselineFile = Join-Path $Directory "baseline-counts.csv"
    $Baseline | Export-Csv -LiteralPath $BaselineFile -NoTypeInformation -Encoding UTF8
    Write-Host ("  Baseline counts        {0} object(s) -> {1}" -f $Baseline.Count, (Split-Path -Leaf $BaselineFile))

    # HOW MANY FCIC JUNK ACCOUNTS ALREADY EXIST.
    #
    # The post-load check asks whether the Contact trigger bypass held, and it
    # used to answer that by testing for ZERO FCIC_Individual Accounts. That is
    # wrong in any org where the trigger has ever fired before: Dev carries 4
    # from an 18-row Contact test batch on 2026-08-13, and they carry no
    # external ID, so the factory reset deliberately leaves them alone. The
    # check would therefore have reported a bypass failure on every single run,
    # for ever - and a check that cries wolf every run is one nobody reads,
    # which is worse than not having it.
    #
    # What actually indicates a bypass failure is the DELTA, so record the
    # starting figure here. Kept as a file rather than added to $Baseline
    # because the post-load loop treats every row there as a queryable object.
    $JunkBefore = @(Invoke-SalesforceQuery `
        -Soql "SELECT Id FROM Account WHERE RecordType.DeveloperName = 'FCIC_Individual'" `
        -OrgAlias $Org -ApiVersion $Version).Count

    Set-Content -LiteralPath (Join-Path $Directory "fcic-junk-baseline.txt") -Value $JunkBefore -Encoding ASCII
    Write-Host ("  FCIC junk Accounts     {0} already present (pre-existing, not deleted by a reset)" -f $JunkBefore)

    return $Baseline
}

function Invoke-PostLoadValidation {
    <#
        Checks the things that go wrong QUIETLY. Success counts are not
        evidence: every serious defect in this migration passed its load and was
        found afterwards by looking at something else.
    #>
    param([string]$Org, [string]$Version, $Baseline, [string]$Directory)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " POST-LOAD VALIDATION" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # Problems FAIL the run (exit 1). Notices are known, currently-expected
    # incompletenesses - reported just as loudly, but they must not turn every
    # run red, because a run that is always red stops being read.
    $Problems = [System.Collections.Generic.List[string]]::new()
    $Notices = [System.Collections.Generic.List[string]]::new()

    # 1. Counts, before vs after.
    Write-Host ""
    Write-Host ("  {0,-34} {1,8} {2,8} {3,8}" -f "OBJECT", "BEFORE", "AFTER", "DELTA")
    $After = [System.Collections.Generic.List[object]]::new()

    foreach ($Row in $Baseline) {
        $Total = @(Invoke-SalesforceQuery -Soql "SELECT Id FROM $($Row.Object)" -OrgAlias $Org -ApiVersion $Version).Count
        $Delta = $Total - $Row.Total
        Write-Host ("  {0,-34} {1,8:N0} {2,8:N0} {3,8}" -f $Row.Object, $Row.Total, $Total, ("{0:+#;-#;0}" -f $Delta))
        $After.Add([PSCustomObject]@{ Object = $Row.Object; Before = $Row.Total; After = $Total; Delta = $Delta })
    }

    $After | Export-Csv -LiteralPath (Join-Path $Directory "post-load-counts.csv") -NoTypeInformation -Encoding UTF8

    # 2. Junk FCIC Accounts. The Contact trigger creates one Account per Contact
    #    inserted with a blank AccountId; the bypass is supposed to stop that.
    #    An Account delta far above what the reconciliation explains is the tell.
    #    Measured as a DELTA against the pre-run figure, not against zero - an
    #    org where the trigger has fired before keeps those Accounts for ever
    #    (they carry no external ID, so no reset removes them). See the note in
    #    Save-RestorePoint.
    $Junk = @(Invoke-SalesforceQuery `
        -Soql "SELECT Id FROM Account WHERE RecordType.DeveloperName = 'FCIC_Individual'" `
        -OrgAlias $Org -ApiVersion $Version).Count

    $JunkBaselineFile = Join-Path $Directory "fcic-junk-baseline.txt"
    $JunkBefore = if (Test-Path -LiteralPath $JunkBaselineFile) {
        [int](Get-Content -LiteralPath $JunkBaselineFile -Raw).Trim()
    } else { 0 }

    $JunkNew = $Junk - $JunkBefore
    Write-Host ""
    Write-Host ("  FCIC_Individual Accounts (junk)        {0} now, {1} before, {2} new" -f $Junk, $JunkBefore, ("{0:+#;-#;0}" -f $JunkNew))
    if ($JunkNew -gt 0) {
        $Problems.Add("$JunkNew NEW FCIC_Individual Account(s) were created during this run - the Contact trigger bypass did not hold.")
    }

    # 3. The trigger switch must be back ON. Leaving it off silently breaks
    #    another team's app in a shared org.
    $Controls = @(Invoke-SalesforceQuery -Soql "SELECT On__c FROM TriggerControls__c WHERE Name = 'Contact'" -OrgAlias $Org -ApiVersion $Version)
    if ($Controls.Count -eq 1) {
        Write-Host ("  TriggerControls__c Contact.On__c       {0}" -f $Controls[0].On__c)
        if (-not $Controls[0].On__c) { $Problems.Add("TriggerControls__c 'Contact' is still OFF. Restore it - another app depends on that trigger.") }
    }

    # 4. Nothing may be owned by an inactive user: Salesforce refuses to ASSIGN
    #    one, so any hit means an owner was deactivated mid-run or the resolver
    #    regressed.
    foreach ($Object in @("Opportunity", "Contact", "LDGCRM_application__c")) {
        $Inactive = @(Invoke-SalesforceQuery `
            -Soql "SELECT Id FROM $Object WHERE Owner.IsActive = false AND LDGCRM_External_ID__c != null" `
            -OrgAlias $Org -ApiVersion $Version).Count
        Write-Host ("  {0,-38} {1} record(s) owned by an inactive user" -f $Object, $Inactive)
        if ($Inactive -gt 0) { $Problems.Add("$Object has $Inactive migrated record(s) owned by an inactive user.") }
    }

    # 5. Market Segment comes from before-save Flows. Blank across the board
    #    means the Flows did not fire, which no load error would have reported.
    foreach ($Object in @("Opportunity", "LDGCRM_application__c")) {
        $Blank = @(Invoke-SalesforceQuery `
            -Soql "SELECT Id FROM $Object WHERE LDGCRM_Market_Segment__c = null AND LDGCRM_External_ID__c != null" `
            -OrgAlias $Org -ApiVersion $Version).Count
        Write-Host ("  {0,-38} {1} migrated record(s) with no Market Segment" -f $Object, $Blank)
    }

    # 6. WROTE-WHAT-WE-INTENDED, for the two fields that can go empty in silence.
    #
    #    Both are sourced from the Issuer Strings table, which is newer than the
    #    rest of the pipeline and has two failure modes that produce a load the
    #    Bulk API calls a complete success:
    #      - the export is missing/stale, so the source is simply absent;
    #      - the email match that finds Partner Portal Admins stops resolving.
    #    In both cases the CSV is written, every row loads, and a field is just
    #    blank. Nothing in a success count would show it.
    #
    #    Checked against the LOAD FILE rather than a hard-coded expectation, so
    #    the check re-baselines itself every time Airtable changes instead of
    #    going stale and being ignored - which is how a check like this dies.
    #
    #    THE COMPARISON IS DELIBERATELY ONE-SIDED: only actual < intended is a
    #    problem. actual > intended is normal and must not fail the run - an
    #    upsert never deletes, so the org keeps rows from earlier runs whose
    #    Airtable source has since been withheld (e.g. its Application became
    #    unloadable). Measured 2026-08-13: 664 admin flags in the org against 573
    #    in the current file, purely from a larger earlier load.
    $LoadDirectory = Get-SalesforceLoadDirectory

    $ApplicationCsv = Join-Path $LoadDirectory "LDGCRM_application__c-upsert.csv"
    if (Test-Path -LiteralPath $ApplicationCsv) {
        $AppRows = @(Import-Csv -LiteralPath $ApplicationCsv)
        $HasTeamColumn = $AppRows.Count -gt 0 -and
            ($AppRows[0].PSObject.Properties.Name -contains "LDGCRM_P3_Team_UUID__c")

        if ($HasTeamColumn) {
            $IntendedTeam = @($AppRows | Where-Object { $_.LDGCRM_P3_Team_UUID__c }).Count
            $ActualTeam = @(Invoke-SalesforceQuery `
                -Soql ("SELECT Id FROM LDGCRM_application__c " +
                       "WHERE LDGCRM_P3_Team_UUID__c != null AND LDGCRM_External_ID__c != null") `
                -OrgAlias $Org -ApiVersion $Version).Count
            Write-Host ("  Partner Portal Team UUID               {0} intended, {1} in the org" -f $IntendedTeam, $ActualTeam)
            if ($ActualTeam -lt $IntendedTeam) {
                $Problems.Add("Partner Portal Team UUID is set on only $ActualTeam Application(s) but $IntendedTeam were submitted - $($IntendedTeam - $ActualTeam) did not land.")
            }
        }
        else {
            # Not a regression - the transform withholds these columns while the
            # fields are still unique=true. Reported so a run cannot look
            # complete while two fields are empty org-wide.
            Write-Host "  Partner Portal Team                    WITHHELD from the load (see notice below)" -ForegroundColor Yellow
            $Notices.Add("Partner Portal Team Name/UUID were NOT loaded: Build-ApplicationLoad.ps1 withholds both columns while they are unique=true in this org. Every Application will have them empty. Needs a CHANGE SET setting Unique = false on both, then a plain re-run. Not a regression.")
        }
    }

    $JunctionCsv = Join-Path $LoadDirectory "LDGCRM_Application_Contact__c-upsert.csv"
    if (Test-Path -LiteralPath $JunctionCsv) {
        $JunctionRows = @(Import-Csv -LiteralPath $JunctionCsv)
        $IntendedAdmin = @($JunctionRows | Where-Object { $_.LGDCRM_P3_Partner_Portal_Admin__c -eq "true" }).Count
        $ActualAdmin = @(Invoke-SalesforceQuery `
            -Soql ("SELECT Id FROM LDGCRM_Application_Contact__c " +
                   "WHERE LGDCRM_P3_Partner_Portal_Admin__c = true AND LDGCRM_External_ID__c != null") `
            -OrgAlias $Org -ApiVersion $Version).Count
        Write-Host ("  Partner Portal Admin flag              {0} intended, {1} in the org" -f $IntendedAdmin, $ActualAdmin)

        if ($ActualAdmin -lt $IntendedAdmin) {
            $Problems.Add("Partner Portal Admin is set on only $ActualAdmin junction row(s) but $IntendedAdmin were submitted - $($IntendedAdmin - $ActualAdmin) did not land.")
        }
        if ($IntendedAdmin -eq 0 -and $JunctionRows.Count -gt 0) {
            # Both sources silent at once means the source broke, not that
            # nobody administers anything.
            $Problems.Add("No Application-Contact row was flagged Partner Portal Admin. Both sources (Contacts.Roles and Issuer Strings' Partner Portal Admin Email) came back empty - check the Airtable export is current and includes Issuer Strings.")
        }
    }

    return [PSCustomObject]@{ Problems = $Problems; Notices = $Notices }
}

function New-StepRecord {
    <#
        One step's line in the run report: what it loaded, plus everything its
        transform wrote to logs/ while it was running.

        BUILT HERE RATHER THAN AT EACH `$Results.Add` SITE because the loop has
        six different exits (transform failed, plan-only, no rows, expected
        partial, load failed, loaded) and the report must be identical from all
        of them. A step that failed is the one whose findings matter most, and
        it is also the easiest to forget.

        -Since is the moment before the transform started. Everything the step
        wrote falls between that and now, which is how review CSVs are
        attributed to a step without touching a single transform - see
        Get-LoadRunFindings.
    #>
    param(
        [Parameter(Mandatory = $true)]$Step,
        [int]$Rows = 0,
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][datetime]$Since,
        [string]$StepResultFile = ""
    )

    $Findings = @()
    try { $Findings = @(Get-LoadRunFindings -Since $Since -Until (Get-Date) -StepName $Step.Name) }
    catch {
        # A reporting failure must never change the outcome of a load.
        Write-Host ("  (could not collect review output for {0}: {1})" -f $Step.Name, $_.Exception.Message) -ForegroundColor DarkGray
    }

    $StepResult = $null
    if ($StepResultFile -and (Test-Path -LiteralPath $StepResultFile)) {
        try { $StepResult = (Get-Content -LiteralPath $StepResultFile -Raw | ConvertFrom-Json) }
        catch { $StepResult = $null }
    }

    return [PSCustomObject]@{
        Step       = $Step.Name
        Object     = $Step.Object
        Rows       = $Rows
        Result     = $Result
        StepResult = $StepResult
        Findings   = $Findings
    }
}

function Invoke-ChildScript {
    <#
        Runs a pipeline script in its own process and returns the exit code.

        CHILD PROCESS, NOT DOT-SOURCED, for the same reasons the factory reset
        uses one: a failure must not take down this orchestrator's transcript or
        summary, and each script keeps its own log file rather than smearing
        eighteen runs into one.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    Write-Host ""
    Write-Host ("  > {0} {1}" -f (Split-Path -Leaf $ScriptPath), ($Arguments -join " ")) -ForegroundColor DarkGray

    # Out-Host, not a bare call: a child process writes its stdout to the
    # PIPELINE, so without this the function returns every line the child
    # printed AND the exit code, and the caller's "-ne 0" test compares an
    # array. That made a successful step report "TRANSFORM FAILED (exit <the
    # entire transcript>)" - caught on the first smoke test.
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments | Out-Host

    return $LASTEXITCODE
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " FULL MIGRATION LOAD" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$OrgInfo = Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias

# --- select the steps to run ------------------------------------------------
$Selected = @($Steps)

if ($OnlySteps) {
    $Wanted = @($OnlySteps -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $Selected = @($Steps | Where-Object { $Wanted -contains $_.Name })

    $Unknown = @($Wanted | Where-Object { $Steps.Name -notcontains $_ })
    if ($Unknown.Count -gt 0) {
        throw "Unknown step name(s): $($Unknown -join ', '). Valid: $($Steps.Name -join ', ')"
    }
}
elseif ($StartAtStep) {
    $Index = [array]::IndexOf(@($Steps.Name), $StartAtStep)
    if ($Index -lt 0) {
        throw "Unknown step '$StartAtStep'. Valid: $($Steps.Name -join ', ')"
    }
    $Selected = @($Steps[$Index..($Steps.Count - 1)])
}

Write-Host ""
Write-Host "Plan ($($Selected.Count) of $($Steps.Count) steps):" -ForegroundColor Cyan
Write-Host ""
$Position = 0
foreach ($Step in $Selected) {
    $Position++
    $Operation = Get-StepProperty -Step $Step -Key "Operation" -Default "Upsert"
    Write-Host ("  {0,2}. {1,-24} {2,-8} {3}" -f $Position, $Step.Name, $Operation, $Step.Object)
    Write-Host ("      {0}" -f $Step.Why) -ForegroundColor DarkGray
}

if ($PlanOnly) {
    Write-Host ""
    Write-Host "-PlanOnly: transforms will run (read-only); NOTHING will be loaded." -ForegroundColor Yellow
}
elseif ($Environment -eq "Prod") {
    Write-Host ""
    Write-Host "*** TARGET IS PRODUCTION. REAL PARTNER DATA. ***" -ForegroundColor Red
    Write-Host "Every step requires -ProductionConfirmation in addition to -Confirmation." -ForegroundColor Red
}

# --- PRE-FLIGHT -------------------------------------------------------------
# The run directory Start-ScriptLog created. Every step - transform, loader,
# notes loader - inherits it through $env:LDGCRM_RUN_DIRECTORY, so this one
# folder ends up holding the whole load: transcripts, review CSVs, bulk failure
# rows, the restore point and the report. See Common.ps1's "one directory per
# run" block.
$RunDirectory = Get-LogDirectory -Category "data-migration"

$Findings = Invoke-PreflightChecks -Org $OrgAlias -Version "67.0" -Env $Environment

if ($Findings.Warning.Count -gt 0) {
    Write-Host ""
    foreach ($Warning in $Findings.Warning) { Write-Host "  WARNING: $Warning" -ForegroundColor Yellow }
}

if ($Findings.Blocking.Count -gt 0) {
    Write-Host ""
    Write-Host "PRE-FLIGHT FAILED - nothing was run:" -ForegroundColor Red
    foreach ($Problem in $Findings.Blocking) { Write-Host "  - $Problem" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "Pre-flight passed." -ForegroundColor Green

# The restore point is captured even on -PlanOnly: it is read-only, and having
# one from a dry run costs nothing and is occasionally exactly what you want.
$Baseline = Save-RestorePoint -Org $OrgAlias -Version "67.0" -Directory $RunDirectory

# --- optional Account bootstrap --------------------------------------------
# Deliberately not a step in the table: it rebuilds a baseline the migration
# does not own, it is sandbox-only, and it has its own confirmation token.
if ($BootstrapAccounts) {
    if ($Environment -eq "Prod") {
        throw ("SAFETY STOP: -BootstrapAccounts inserts Accounts from a production export. " +
               "In production those Accounts already exist - running it there would duplicate them. " +
               "Nothing was run.")
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " STEP 0: Account bootstrap" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    if ($PlanOnly) {
        $Code = Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "Invoke-AccountBootstrap.ps1") `
            -Arguments @("-Environment", $Environment, "-PlanOnly")
    }
    else {
        $BootstrapArgs = @("-Environment", $Environment)
        if ($Confirmation) { $BootstrapArgs += @("-Confirmation", "BOOTSTRAP") }
        $Code = Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "Invoke-AccountBootstrap.ps1") `
            -Arguments $BootstrapArgs
    }

    if ($Code -ne 0 -and -not $ContinueOnError) {
        throw "Account bootstrap failed (exit $Code). Nothing further was run."
    }
}

# --- run the sequence -------------------------------------------------------
$Results = [System.Collections.Generic.List[object]]::new()
$LoadDir = Get-SalesforceLoadDirectory
$Position = 0
$Failed = $false
# Set when a step loaded with expected partial failures. Reported prominently,
# but deliberately does NOT make the run exit non-zero - see the summary.
$Partial = $false

foreach ($Step in $Selected) {
    $Position++

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host (" STEP {0}/{1}: {2}" -f $Position, $Selected.Count, $Step.Name) -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    $BuildScript = Get-StepProperty -Step $Step -Key "Build"
    $TransformCode = 0

    # Marks the boundary a freshly-written CSV must fall on the far side of.
    # Taken BEFORE the transform runs - see the staleness check below.
    $TransformStart = Get-Date

    # PopulateBrokerParent has no transform of its own - Build-ApplicationLoad.ps1
    # produces its file as a side effect, which is the whole point of
    # generating it automatically rather than as a separate script.
    if ($BuildScript) {
        $TransformCode = Invoke-ChildScript `
            -ScriptPath (Join-Path $PSScriptRoot $BuildScript) `
            -Arguments @("-Environment", $Environment)
    }
    else {
        Write-Host "  (no transform - its file is produced by an earlier step)" -ForegroundColor DarkGray
    }

    $CsvPath = Join-Path $LoadDir $Step.Csv
    $RowCount = 0
    $Stale = $false

    if (Test-Path -LiteralPath $CsvPath) {
        # A TRANSFORM THAT WRITES NOTHING LEAVES THE LAST RUN'S FILE BEHIND.
        #
        # Every Build-*.ps1 skips writing its CSV when it has no rows to emit
        # ("No Account records need updating - nothing written to ...") rather
        # than truncating it. So the file at the expected path may belong to a
        # previous run, and counting it reports rows this run did not produce -
        # or, worse, LOADS them. Caught 2026-08-13 on a -PlanOnly run that
        # reported 587 Account rows and 503 OpportunityContactRole rows from
        # files dated the previous day, while both transforms had just printed
        # a count of zero.
        #
        # Stale data in an Account update file is stale Salesforce Ids, which
        # after a factory reset point at deleted records. That fails loudly.
        # The quiet case is -StartAtStep / -OnlySteps, where an operator
        # resuming a failed run re-loads an older file believing it is current
        # - which is the resume path the Operations team will actually use.
        #
        # Only applies where the transform that OWNS the file ran in this
        # invocation. PopulateBrokerParent's file is written by the Application
        # step, so on a -StartAtStep PopulateBrokerParent resume it is
        # legitimately older than this run; that is reported, not suppressed.
        $Written = (Get-Item -LiteralPath $CsvPath).LastWriteTime

        if ($BuildScript -and $Written -lt $TransformStart) {
            $Stale = $true
            Write-Host ""
            Write-Host ("  {0} was NOT written by this run (last written {1:yyyy-MM-dd HH:mm})." -f $Step.Csv, $Written) -ForegroundColor Yellow
            Write-Host "  The transform produced no rows, so the file on disk belongs to an earlier" -ForegroundColor Yellow
            Write-Host "  run. Treating this step as zero rows rather than loading it." -ForegroundColor Yellow
        }
        else {
            $RowCount = @(Import-Csv -LiteralPath $CsvPath).Count
            if (-not $BuildScript -and $Written -lt $RunStart) {
                Write-Host ("  NOTE: {0} predates this run (last written {1:yyyy-MM-dd HH:mm}) - its" -f $Step.Csv, $Written) -ForegroundColor Yellow
                Write-Host "  transform did not run in this invocation. Confirm it is the file you want." -ForegroundColor Yellow
            }
        }
    }

    if ($TransformCode -ne 0) {
        $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart `
            -Result "TRANSFORM FAILED (exit $TransformCode)"))
        $Failed = $true
        if (-not $ContinueOnError) { break }
        continue
    }

    if ($PlanOnly) {
        $Outcome = if ($Stale) { "no rows (stale file ignored)" } else { "planned (not loaded)" }
        $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart -Result $Outcome))
        continue
    }

    if ($RowCount -eq 0) {
        $Outcome = if ($Stale) { "skipped (no rows; stale file ignored)" } else { "skipped (no rows)" }
        Write-Host "  Nothing to load - transform produced no rows." -ForegroundColor Yellow
        $Results.Add((New-StepRecord -Step $Step -Rows 0 -Since $TransformStart -Result $Outcome))
        continue
    }

    # --- load --------------------------------------------------------------
    # Where the load step reports what it did, in machine-readable form. The
    # child's exit code carries three states; this carries the counts, the
    # per-error classification and the job id. See -StepResultPath in
    # Invoke-SalesforceLoad.ps1.
    $StepResultFile = Join-Path $RunDirectory "step-result-$($Step.Name).json"

    if ((Get-StepProperty -Step $Step -Key "Loader" -Default "Standard") -eq "Notes") {
        $LoadArgs = @("-Environment", $Environment, "-StepResultPath", $StepResultFile)
        if ($Confirmation) { $LoadArgs += @("-Confirmation", $Confirmation) }
        if ($ProductionConfirmation) { $LoadArgs += @("-ProductionConfirmation", $ProductionConfirmation) }

        $LoadCode = Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "Invoke-NotesLoad.ps1") -Arguments $LoadArgs
    }
    else {
        $LoadArgs = @(
            "-Environment", $Environment,
            "-ObjectApiName", $Step.Object,
            "-CsvFile", $CsvPath,
            "-Operation", (Get-StepProperty -Step $Step -Key "Operation" -Default "Upsert"),
            "-StepResultPath", $StepResultFile
        )
        $TriggerOff = Get-StepProperty -Step $Step -Key "TriggerOff"
        if ($TriggerOff) { $LoadArgs += @("-DisableTriggerControl", $TriggerOff) }
        if ($Confirmation) { $LoadArgs += @("-Confirmation", $Confirmation) }
        if ($ProductionConfirmation) { $LoadArgs += @("-ProductionConfirmation", $ProductionConfirmation) }

        $ExpectedFailures = @(Get-StepProperty -Step $Step -Key "ExpectedFailures" -Default @())
        foreach ($Pattern in $ExpectedFailures) {
            $LoadArgs += @("-ExpectedFailurePatterns", $Pattern)
        }

        $LoadCode = Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "Invoke-SalesforceLoad.ps1") -Arguments $LoadArgs
    }

    # Exit 2 = loaded, with failures that all match this object's known causes
    # and sit within the allowance. A correct outcome, so the sequence CONTINUES -
    # this is the whole point of the expected-partial work. Before it, the run
    # halted here and an operator had to diagnose and resume by hand; that
    # happened twice in the 2026-08-13 reload, both times on a correct load.
    if ($LoadCode -eq 2) {
        $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart `
            -Result "PARTIAL (expected failures)" -StepResultFile $StepResultFile))
        $Partial = $true
        continue
    }

    if ($LoadCode -ne 0) {
        $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart `
            -Result "LOAD FAILED (exit $LoadCode)" -StepResultFile $StepResultFile))
        $Failed = $true
        if (-not $ContinueOnError) { break }
        continue
    }

    $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart `
        -Result "loaded" -StepResultFile $StepResultFile))
}

# --- summary ----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " FULL MIGRATION LOAD - SUMMARY" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("  {0,-24} {1,8} {2}" -f "STEP", "ROWS", "RESULT")
foreach ($Result in $Results) {
    $Colour = if ($Result.Result -like "*FAILED*") { "Red" }
              elseif ($Result.Result -like "PARTIAL*") { "Yellow" }
              elseif ($Result.Result -eq "loaded") { "Green" }
              else { "Gray" }
    Write-Host ("  {0,-24} {1,8:N0} {2}" -f $Result.Step, $Result.Rows, $Result.Result) -ForegroundColor $Colour
}
Write-Host ""

if ($Partial) {
    Write-Host "PARTIAL steps loaded successfully with SOME rows rejected, and every" -ForegroundColor Yellow
    Write-Host "rejection matched a known cause for that object (parent Account not" -ForegroundColor Yellow
    Write-Host "reconciled, org duplicate rule). That is the documented correct outcome," -ForegroundColor Yellow
    Write-Host "not a failure - the sequence continued rather than stopping." -ForegroundColor Yellow
    Write-Host "Per-row detail: <object>-<jobid>-failed-records.csv in this run's directory." -ForegroundColor DarkGray
    Write-Host ""
}

# --- post-load validation ---------------------------------------------------
# Runs before the report so its findings can go INTO the report. Skipped on
# -PlanOnly (nothing was written to validate) and after a failure (the org is
# half-loaded by definition, so every check would fire and none would mean
# anything).
$Validation = $null
$Problems = @()

if (-not $PlanOnly -and -not $Failed) {
    $Validation = Invoke-PostLoadValidation -Org $OrgAlias -Version "67.0" -Baseline $Baseline -Directory $RunDirectory
    $Problems = @($Validation.Problems)
    $Notices = @($Validation.Notices)

    Write-Host ""
    if ($Problems.Count -gt 0) {
        Write-Host "POST-LOAD VALIDATION FOUND PROBLEMS:" -ForegroundColor Red
        foreach ($Problem in $Problems) { Write-Host "  - $Problem" -ForegroundColor Red }
        Write-Host ""
        Write-Host "The load itself reported success. These are the quiet failures." -ForegroundColor Yellow
    }
    else {
        Write-Host "Post-load validation passed." -ForegroundColor Green
    }

    if ($Notices.Count -gt 0) {
        Write-Host ""
        Write-Host "KNOWN INCOMPLETE - loaded correctly, but data is still missing:" -ForegroundColor Yellow
        foreach ($Notice in $Notices) { Write-Host "  - $Notice" -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "These do not fail the run. They are waiting on something outside this repo." -ForegroundColor DarkGray
    }
}

# --- the run report ---------------------------------------------------------
# WRITTEN ON EVERY PATH, INCLUDING A FAILED ONE. A run that stopped at step
# four is precisely the run whose report is worth reading: it shows what the
# first three steps withheld, which is usually why the fourth failed. Writing
# it only on success would remove it exactly when it is needed.
#
# Wrapped, because a defect in reporting must not be able to change the outcome
# of a load. If this throws, the run keeps its own verdict and the operator
# still has every underlying file.
try {
    $ReportText = Write-LoadRunReport `
        -RunDirectory $RunDirectory `
        -Steps $Results `
        -Validation $Validation `
        -Header @{
            Environment = $Environment
            Org         = $OrgAlias
            Started     = $RunStart
            Mode        = if ($PlanOnly) { "PLAN ONLY - nothing was loaded" } else { "LOAD" }
        }

    Write-Host ""
    Write-Host $ReportText
}
catch {
    Write-Host ""
    Write-Host "Could not write the run report: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "The run's own result stands; every underlying file is still in $RunDirectory" -ForegroundColor DarkGray
}

if ($Failed) {
    $LastStep = $Results[$Results.Count - 1].Step
    Write-Host ""
    Write-Host "The sequence STOPPED at '$LastStep'." -ForegroundColor Red
    Write-Host "Everything after it would withhold rows that depend on that step, which is why" -ForegroundColor Yellow
    Write-Host "it did not continue. Fix the cause, then resume with:" -ForegroundColor Yellow
    Write-Host ("  Invoke-FullMigrationLoad.ps1 -Environment {0} -StartAtStep {1}" -f $Environment, $LastStep) -ForegroundColor DarkGray
    exit 1
}

if ($PlanOnly) {
    Write-Host "-PlanOnly: nothing was loaded. Re-run without it (and with -Confirmation `"LOAD`") to apply." -ForegroundColor Yellow
    Write-Host "Restore point and baseline counts: $RunDirectory" -ForegroundColor DarkGray
}
else {
    Write-Host "This is NOT a full verification. Walk docs/operations/RELOAD-QA-CHECKLIST.md - success" -ForegroundColor Cyan
    Write-Host "counts are not the same as correct data." -ForegroundColor Cyan

    if ($Problems.Count -gt 0) { exit 1 }
}

}
finally {
    Stop-ScriptLog
}
