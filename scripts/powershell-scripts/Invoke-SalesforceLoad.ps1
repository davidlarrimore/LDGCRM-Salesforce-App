#Requires -Version 5.1

<#
    Chunk 5 of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md) - the actual load step. Wraps `sf data
    upsert bulk` / `sf data update bulk` (Bulk API 2.0) around a CSV produced
    by one of this directory's Build-*.ps1 transform scripts.

    Uses the Salesforce CLI rather than the headless Data Loader CLI: `sf` is
    already installed, authenticated, and used by every other script in this
    repo, whereas Data Loader CLI isn't installed anywhere in this environment
    and current versions need Java 11+ (this machine only has Java 8). Both
    tools sit on Bulk API underneath and resolve lookups the same way (a CSV
    column named "RelationshipName.LDGCRM_External_ID__c" resolves the parent
    by external ID at load time), so nothing about how the Build-*.ps1 scripts
    write their CSVs depends on which loader actually runs them.

    -Operation Upsert (default) is for every object except Account: the CSV's
    key column is the external ID field (LDGCRM_External_ID__c by default).
    -Operation Update is for Account specifically (see
    Build-AccountReconciliation.ps1): the CSV's key column must be named "Id".
    -Operation Insert is a pure Bulk API 2.0 insert (`sf data import bulk`) -
    no key column at all, used for seeding brand-new records that don't have
    an external ID yet (see Build-ProdAccountSeed.ps1).

    This writes to gsa-peo. Per sfdx-sandbox-ops: preflight counts are shown,
    and nothing is sent to Salesforce until you type LOAD to confirm.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ObjectApiName,

    [Parameter(Mandatory = $true)]
    [string]$CsvFile,

    [ValidateSet("Upsert", "Update", "Insert")]
    [string]$Operation = "Upsert",

    [string]$ExternalIdField = "LDGCRM_External_ID__c",

    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (powershell-scripts/Common.Orgs.ps1).
    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",
    [int]$WaitMinutes = 30,

    # Approve the load without a prompt: -Confirmation "LOAD". A token rather
    # than a -Force switch, so the approval states what it approves and can't be
    # copy-pasted between scripts that expect different tokens. See
    # Assert-LdgcrmTypedConfirmation.
    [string]$Confirmation = "",

    # Separate, additional token required only when -Environment Prod. Two
    # distinct flags on purpose: an operator who automated a sandbox load
    # cannot retarget it at production by changing -Environment alone.
    [string]$ProductionConfirmation = "",

    <#
        Name of a TriggerControls__c custom-setting record to switch OFF for
        the duration of this load, then switch back on. See the big
        "TRIGGER BYPASS" comment block below before using it.
    #>
    [string]$DisableTriggerControl = "",

    <#
        EXPECTED-PARTIAL HANDLING (added 2026-08-13). See the block below.

        Substrings that mark a row failure as a KNOWN, ACCEPTED outcome for this
        object. A failure whose error contains any of these is "expected"; any
        other failure is a real one and still fails the load.

        Deliberately per-object and supplied by the caller, not a global list
        baked in here: DUPLICATES_DETECTED is the documented correct outcome on
        Contact and would be a brand-new problem on Application.
    #>
    [string[]]$ExpectedFailurePatterns = @(),

    # Ceiling on expected failures, as a fraction of the submitted rows. Even a
    # known cause at unusual volume means something changed upstream.
    [double]$ExpectedFailureMaxFraction = 0.05,

    # Absolute floor for that ceiling, so a small batch is not failed by
    # arithmetic (2 of 94 is 2.1% and fine; 2 of 20 would be 10% and is also
    # fine). Effective allowance = max(this, fraction x rows).
    [int]$ExpectedFailureMinCount = 20,

    <#
        Where to write this step's machine-readable result (JSON).

        WHY THIS EXISTS. This script runs as a CHILD PROCESS of
        Invoke-FullMigrationLoad.ps1, so everything it prints - including the
        expected-vs-unexpected classification below, which is the single most
        useful thing it computes - lands in its own transcript and reaches the
        orchestrator only as an exit code: 0, 1 or 2. Three bits. The
        orchestrator's summary could therefore say "PARTIAL (expected
        failures)" but never how many, on what, or why, and an operator wanting
        that had to open a second transcript per object.

        This file is how the detail gets back. It is written in a `finally`, so
        a step that throws still reports what it knew - a failed step is
        precisely when the summary matters most.

        Empty (the default) means "nobody is collecting", and nothing is
        written: running this script by hand stays exactly as it was.
    #>
    [string]$StepResultPath = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Invoke-SalesforceLoad-$ObjectApiName"

# =============================================================================
# TRIGGER BYPASS (-DisableTriggerControl) - READ THIS BEFORE USING IT
# =============================================================================
# WHAT IT IS
#   gsa-peo hosts an unrelated app, FCIC, whose Apex trigger
#   GSA_FCIC_ContactTrigger fires on EVERY Contact insert/update. Its
#   before-insert path calls getContactsWithBlankAccounts() and then
#   createAccount(), which creates a brand-new Account - named after the
#   person and hard-coded to the FCIC_Individual Account record type - for
#   every Contact inserted with a blank AccountId. It also runs a
#   dedupContact() routine over the inserted rows.
#
# WHY THAT MATTERS TO THIS MIGRATION
#   371 of the 1,487 migrated Contacts have no resolvable Account (most
#   because their Airtable Account is one of the unreconciled duplicates - see
#   docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md). Loading them with the trigger
#   active creates 371 junk Accounts in an org where Account counts are already
#   a moving target and where this migration's own Account reconciliation
#   depends on those counts being meaningful. A 18-row test batch created 4
#   such Accounts (org total 1,346 -> 1,350), which is how this was found.
#
# WHY A BYPASS IS THE RIGHT ANSWER AND NOT A HACK
#   The FCIC app ships its own kill switch for exactly this: a TriggerControls__c
#   custom setting keyed by object name, and the trigger's first statement is
#   `if(contactTriggersAreOn)`. Using it is the supported, intended mechanism -
#   not a workaround. Records are: Task, Case, Contact, LiveChatTranscript.
#
# THE RULES
#   1. This flips a setting owned by ANOTHER APP. Only use it with explicit
#      human sign-off for the specific load (user-confirmed 2026-08-13 for
#      Contact).
#   2. The original value is captured first and restored in a `finally` block,
#      so it is restored even if the load throws or the CLI dies mid-job.
#   3. The restore is VERIFIED by re-querying, not assumed. If verification
#      fails the script screams - leaving FCIC's trigger disabled would
#      silently break the other app for everyone else using this sandbox.
#   4. It is OFF by default. Never make it the default.
#
# WHAT IT DOES NOT COVER
#   The other active Contact trigger, purecloud.ContactWebHookv1, belongs to an
#   installed MANAGED package (Genesys PureCloud). Its body is hidden, it can't
#   be retrieved, and it has no equivalent kill switch. It still fires. It was
#   user-confirmed inert in this sandbox on 2026-08-13; re-confirm before any
#   production run, because a webhook on Contact insert is an outward-facing
#   side effect this pipeline cannot inspect.
# =============================================================================

function Get-TriggerControlState {
    param([string]$ControlName, [string]$Org, [string]$Version)

    $Rows = @(Invoke-SalesforceQuery `
        -Soql "SELECT Id, Name, On__c FROM TriggerControls__c WHERE Name = '$ControlName'" `
        -OrgAlias $Org -ApiVersion $Version)

    if ($Rows.Count -ne 1) {
        throw "Expected exactly 1 TriggerControls__c record named '$ControlName', found $($Rows.Count). Refusing to guess which one to change."
    }
    return $Rows[0]
}

function Set-TriggerControlState {
    param([string]$RecordId, [bool]$On, [string]$Org)

    $Value = if ($On) { "true" } else { "false" }
    $Result = & sf data update record `
        --sobject TriggerControls__c `
        --record-id $RecordId `
        --values "On__c=$Value" `
        --target-org $Org `
        --json

    if ($LASTEXITCODE -ne 0) {
        Write-Host $Result -ForegroundColor Red
        throw "Failed to set TriggerControls__c $RecordId On__c=$Value."
    }
}

function Invoke-SalesforceCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        # When set, a non-zero exit is RETURNED rather than thrown, so the
        # caller can inspect the result. Used only for the bulk load itself -
        # see Get-BulkFailureDetail for why.
        [switch]$TolerateNonZeroExit
    )

    Write-Host ""
    Write-Host "sf $($Arguments -join ' ')" -ForegroundColor DarkGray

    $RawResult = & sf @Arguments --json
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -ne 0 -and -not $TolerateNonZeroExit) {
        Write-Host $RawResult -ForegroundColor Red
        throw "Salesforce CLI command failed with exit code $ExitCode."
    }

    $Parsed = $null
    try { $Parsed = $RawResult | ConvertFrom-Json } catch { $Parsed = $null }

    if ($null -eq $Parsed) {
        Write-Host $RawResult -ForegroundColor Red
        throw "Could not parse the Salesforce CLI response (exit $ExitCode)."
    }

    return [PSCustomObject]@{ ExitCode = $ExitCode; Result = $Parsed }
}

function Get-BulkFailureDetail {
    <#
        Returns the per-row failures for a finished Bulk job.

        WHY THIS IS A SEPARATE CALL. When any row fails, `sf data upsert bulk`
        exits 1 and its JSON carries the job id but NOT the row errors - so the
        only way to find out WHY rows failed is to ask for the results
        afterwards. Without this the script could only report "it failed",
        which is exactly the ambiguity this whole feature exists to remove.

        `sf data bulk results` writes <jobid>-failed-records.csv into the CURRENT
        DIRECTORY. That file contains full record payloads - applicant names and
        emails - so it is written to a run-scoped folder under logs/ (gitignored)
        rather than left in the repo root, where it would be one `git add -A`
        away from being committed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$Org,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,

        # Prefixed onto the renamed result files so a run directory holding
        # several objects' failures is readable at a glance.
        [string]$Label = ""
    )

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    $Previous = Get-Location
    try {
        Set-Location -LiteralPath $OutputDirectory
        & sf data bulk results --job-id $JobId --target-org $Org | Out-Null
    }
    finally {
        Set-Location $Previous
    }

    # The CLI names its output after the JOB, which says nothing about what is
    # in it. Rename to <object>-<jobid>-... : the label makes the file findable,
    # and the job id is kept because it is what `sf data bulk results` needs to
    # fetch it again, AND because it keeps two steps that load the SAME object
    # apart - Application and PopulateBrokerParent both write LDGCRM_application__c, so
    # a label-only name would have the second silently overwrite the first.
    foreach ($Kind in @("failed", "success")) {
        $Written = Join-Path $OutputDirectory "$JobId-$Kind-records.csv"
        if ($Label -and (Test-Path -LiteralPath $Written)) {
            Move-Item -LiteralPath $Written -Destination (Join-Path $OutputDirectory "$Label-$JobId-$Kind-records.csv") -Force
        }
    }

    $FailedFile = if ($Label) {
        Join-Path $OutputDirectory "$Label-$JobId-failed-records.csv"
    } else {
        Join-Path $OutputDirectory "$JobId-failed-records.csv"
    }

    if (-not (Test-Path -LiteralPath $FailedFile)) { return @() }

    return @(Import-Csv -LiteralPath $FailedFile)
}

# What -StepResultPath will contain. Populated as the run proceeds and written
# once, in the `finally` - so an early throw still reports Outcome="error" with
# whatever was known by then, rather than writing nothing and leaving the
# orchestrator to infer everything from an exit code.
$StepResult = [ordered]@{
    Object          = $ObjectApiName
    Operation       = $Operation
    Org             = $OrgAlias
    Timestamp       = $Timestamp
    Outcome         = "error"      # ok | expected-partial | failed | error | declined
    Submitted       = 0
    Succeeded       = 0
    Failed          = 0
    ExpectedFailed  = 0
    UnexpectedFailed = 0
    Allowance       = 0
    JobId           = ""
    FailureDirectory = ""
    # One entry per DISTINCT error message: { Message, Count, Classification }.
    # Grouped here rather than in the orchestrator because this is where the
    # per-object ExpectedFailurePatterns live - the classification is not
    # reconstructable downstream without them.
    Errors          = @()
    ErrorMessage    = ""
}

function Save-StepResult {
    param([string]$Path, $Result)

    if (-not $Path) { return }

    try {
        $Directory = Split-Path -Parent $Path
        if ($Directory -and -not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        }
        # ConvertTo-Json's default -Depth is 2, which silently renders the
        # Errors array as System.Object[] strings.
        ($Result | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath $Path -Encoding UTF8
    }
    catch {
        # Never let reporting break a load. The step's own transcript remains
        # the authority; this file is a convenience for the orchestrator.
        Write-Host "  (could not write step result to $Path : $($_.Exception.Message))" -ForegroundColor DarkGray
    }
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " SALESFORCE LOAD: $ObjectApiName" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Target org alias: $OrgAlias"
Write-Host "Operation:        $Operation"
Write-Host "CSV file:         $CsvFile"
Write-Host ""

if (-not (Test-Path -LiteralPath $CsvFile)) {
    throw "CSV file not found: $CsvFile"
}

$Rows = @(Import-Csv -LiteralPath $CsvFile)
$StepResult.Submitted = $Rows.Count

if ($Rows.Count -eq 0) {
    Write-Host "CSV has no data rows. Nothing to load." -ForegroundColor Yellow
    $StepResult.Outcome = "ok"
    exit 0
}

if ($Operation -ne "Insert") {
    $KeyColumn = if ($Operation -eq "Update") { "Id" } else { $ExternalIdField }

    if (-not ($Rows[0].PSObject.Properties.Name -contains $KeyColumn)) {
        throw "CSV is missing the expected key column '$KeyColumn' for a $Operation operation."
    }
}

# ============================================================
# PREFLIGHT
# ============================================================

Write-Host "Checking the target org..." -ForegroundColor Cyan
Invoke-SalesforceCliJson -Arguments @("org", "display", "--target-org", $OrgAlias) | Out-Null

$CurrentCountResult = Invoke-SalesforceCliJson -Arguments @(
    "data", "query",
    "--target-org", $OrgAlias,
    "--api-version", $ApiVersion,
    "--query", "SELECT COUNT() FROM $ObjectApiName"
)
$CurrentCount = [int]$CurrentCountResult.Result.result.totalSize

Write-Host ""
Write-Host ("{0,-35} {1,10:N0}" -f "Rows in CSV", $Rows.Count)
Write-Host ("{0,-35} {1,10:N0}" -f "Existing $ObjectApiName records in $OrgAlias", $CurrentCount)
Write-Host ""

# ============================================================
# CONFIRMATION
# ============================================================

Write-Host "This will write $($Rows.Count) record(s) to $ObjectApiName in $OrgAlias." -ForegroundColor Yellow

if ($DisableTriggerControl) {
    Write-Host ""
    Write-Host "It will ALSO temporarily disable the '$DisableTriggerControl' TriggerControls__c" -ForegroundColor Yellow
    Write-Host "custom setting (a switch owned by the unrelated FCIC app) and restore it" -ForegroundColor Yellow
    Write-Host "afterwards. See the TRIGGER BYPASS block in this script for why." -ForegroundColor Yellow
}

# The production guard runs BEFORE the load confirmation, and was missing here
# entirely until 2026-08-13 - this script accepted -Environment Prod with only a
# single "LOAD" to clear, while the docs claimed production was gated twice. It
# is the most-used write script in the pipeline, so that was the worst place to
# be missing it.
if (-not (Assert-LdgcrmProductionConsent `
        -Environment $Environment `
        -Action "$Operation $($Rows.Count.ToString('N0')) row(s) into $ObjectApiName" `
        -ProductionConfirmation $ProductionConfirmation)) {
    $StepResult.Outcome = "declined"
    exit 0
}

if (-not (Assert-LdgcrmTypedConfirmation `
        -Token "LOAD" `
        -Provided $Confirmation `
        -Action "$Operation $($Rows.Count.ToString('N0')) row(s) into $ObjectApiName in $OrgAlias")) {
    Write-Host ""
    Write-Host "Load cancelled. Nothing was written." -ForegroundColor Yellow
    $StepResult.Outcome = "declined"
    exit 0
}

# ============================================================
# LOAD
# ============================================================

$LogDir = Get-LogDirectory -Category "data-migration"
$ResultFile = Join-Path $LogDir "Load-$ObjectApiName-$Timestamp.json"

# Capture the pre-load state BEFORE touching anything, so the restore below
# puts back what was actually there rather than assuming it was "on".
$TriggerControl = $null
$TriggerControlOriginalOn = $null
if ($DisableTriggerControl) {
    $TriggerControl = Get-TriggerControlState -ControlName $DisableTriggerControl -Org $OrgAlias -Version $ApiVersion
    $TriggerControlOriginalOn = [bool]$TriggerControl.On__c
    Write-Host ""
    Write-Host "TriggerControls__c '$DisableTriggerControl' is currently On__c=$TriggerControlOriginalOn (Id $($TriggerControl.Id))." -ForegroundColor Yellow

    if ($TriggerControlOriginalOn) {
        Write-Host "Disabling it for the duration of this load..." -ForegroundColor Yellow
        Set-TriggerControlState -RecordId $TriggerControl.Id -On $false -Org $OrgAlias
        Write-Host "Disabled." -ForegroundColor Yellow
    }
    else {
        Write-Host "Already off - leaving it alone (and leaving it off afterwards)." -ForegroundColor Yellow
    }
}

# "Insert" maps to the `data import bulk` command (not `data insert bulk` -
# the CLI names pure-insert bulk loads "import"); Upsert/Update map directly
# to their own same-named subcommands.
$SfSubcommand = if ($Operation -eq "Insert") { "import" } else { $Operation.ToLower() }

$LoadArguments = @(
    "data", $SfSubcommand,
    "bulk",
    "--sobject", $ObjectApiName,
    "--file", $CsvFile,
    "--target-org", $OrgAlias,
    "--api-version", $ApiVersion,
    "--wait", $WaitMinutes.ToString()
)

if ($Operation -eq "Upsert") {
    $LoadArguments += @("--external-id", $ExternalIdField)
}

# TolerateNonZeroExit: `sf data upsert bulk` exits 1 if ANY row fails, and for
# several objects a handful of failures is the documented correct outcome. The
# script must survive the exit to read WHY they failed - classification happens
# below, and a genuinely bad load still exits non-zero from there.
$LoadInvocation = Invoke-SalesforceCliJson -Arguments $LoadArguments -TolerateNonZeroExit
$LoadResult = $LoadInvocation.Result
$LoadResult | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultFile -Encoding UTF8

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " LOAD COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

$JobInfo = $LoadResult.result.jobInfo
$JobId = $null
$Processed = $null
$Failed = $null

if ($JobInfo) {
    # Shape used by `sf data upsert bulk`.
    $JobId = $JobInfo.id
    $Processed = [int]$JobInfo.numberRecordsProcessed
    $Failed = [int]$JobInfo.numberRecordsFailed
    Write-Host ("{0,-35} {1}" -f "Job ID", $JobId)
    Write-Host ("{0,-35} {1}" -f "State", $JobInfo.state)
    Write-Host ("{0,-35} {1:N0}" -f "Records processed", $Processed)
    Write-Host ("{0,-35} {1:N0}" -f "Records failed", $Failed)
}
elseif ($null -ne $LoadResult.result.processedRecords) {
    # Flat shape used by `sf data update bulk`.
    $JobId = $LoadResult.result.jobId
    $Processed = [int]$LoadResult.result.processedRecords
    $Failed = [int]$LoadResult.result.failedRecords
    Write-Host ("{0,-35} {1}" -f "Job ID", $JobId)
    Write-Host ("{0,-35} {1:N0}" -f "Records processed", $Processed)
    Write-Host ("{0,-35} {1:N0}" -f "Records successful", $LoadResult.result.successfulRecords)
    Write-Host ("{0,-35} {1:N0}" -f "Records failed", $Failed)
}
else {
    # Error shape: counts are absent, but the job id is present and is what
    # lets us go and ask for the failures.
    $JobId = $LoadResult.data.jobId
    Write-Host ("{0,-35} {1}" -f "Job ID", $JobId)
    Write-Host ("{0,-35} {1}" -f "CLI message", $LoadResult.message)
}

Write-Host ""
Write-Host "Full job result:" -ForegroundColor Cyan
Write-Host $ResultFile

# ============================================================
# EXPECTED-PARTIAL CLASSIFICATION
# ============================================================
# A load that reports failures is not automatically a broken load. Several
# objects have known failures as their CORRECT outcome - Partner Accounts whose
# parent Account is one of the unmatched Airtable rows, Contacts caught by the
# org's first+last-name duplicate rule. Before this, any failure exited non-zero
# and the orchestrator halted, so a correct run looked identical to a broken one
# and cost a manual diagnosis every time (twice in the 2026-08-13 reload).
#
# The rules, decided 2026-08-13:
#   1. A failure is EXPECTED only if its error matches one of this object's
#      -ExpectedFailurePatterns. Per-object on purpose.
#   2. Anything unmatched is a REAL failure -> non-zero exit, as before.
#   3. Expected failures are still capped at max(MinCount, Fraction x rows) -
#      a known cause at unusual volume means something upstream changed.
$LoadFailed = $false
$ExpectedPartial = $false

$StepResult.JobId = "$JobId"

if ($LoadInvocation.ExitCode -eq 0) {
    # Clean load. Recorded explicitly rather than left at the initial values,
    # because "0 failures" and "we never got far enough to know" must not look
    # the same in the report.
    $StepResult.Outcome = "ok"
    $StepResult.Succeeded = if ($null -ne $Processed -and $Processed -gt 0) { $Processed - [int]$Failed } else { $Rows.Count }
    $StepResult.Failed = 0
}

if ($LoadInvocation.ExitCode -ne 0) {
    if (-not $JobId) {
        Write-Host ""
        Write-Host "The load failed and no job id was returned, so the failures cannot be" -ForegroundColor Red
        Write-Host "classified. Treating as a real failure." -ForegroundColor Red
        $LoadFailed = $true
        $StepResult.ErrorMessage = "The load failed and no job id was returned, so the failures could not be classified."
    }
    else {
        # The run's own directory - not a bulk-results\<object>-<ts>\ folder of
        # its own. Get-LogDirectory resolves to the run directory when a run is
        # in progress, so an orchestrated load's failure rows land beside
        # everything else that load produced.
        $FailureDirectory = Get-LogDirectory -Category "data-migration"
        $FailedRows = @(Get-BulkFailureDetail -JobId $JobId -Org $OrgAlias `
            -OutputDirectory $FailureDirectory -Label $ObjectApiName)

        if ($null -eq $Failed -or $Failed -eq 0) { $Failed = $FailedRows.Count }

        $Unexpected = @($FailedRows | Where-Object {
            $Message = "$($_.sf__Error)"
            $Match = $false
            foreach ($Pattern in $ExpectedFailurePatterns) {
                if ($Pattern -and $Message -like "*$Pattern*") { $Match = $true; break }
            }
            -not $Match
        })

        $Allowance = [Math]::Max($ExpectedFailureMinCount, [int][Math]::Ceiling($Rows.Count * $ExpectedFailureMaxFraction))

        # --- feed the run report ------------------------------------------
        # Distinct error messages with counts, each already classified. The
        # orchestrator cannot redo this: ExpectedFailurePatterns is per-object
        # and is passed in, not stored anywhere the report could read later.
        #
        # Messages are normalised before grouping - Salesforce embeds the
        # offending record id in several of them ("Foreign key external ID:
        # recXYZ..."), which would otherwise turn one cause affecting 20 rows
        # into 20 causes affecting one row each, and bury the actual signal.
        $UnexpectedIds = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($Row in $Unexpected) { $UnexpectedIds.Add("$($Row.sf__Error)") | Out-Null }

        $StepResult.Succeeded = $Rows.Count - $FailedRows.Count
        $StepResult.Failed = $FailedRows.Count
        $StepResult.UnexpectedFailed = $Unexpected.Count
        $StepResult.ExpectedFailed = $FailedRows.Count - $Unexpected.Count
        $StepResult.Allowance = $Allowance
        $StepResult.FailureDirectory = $FailureDirectory
        $StepResult.Errors = @(
            $FailedRows |
                Group-Object { ConvertTo-NormalisedErrorMessage -Message "$($_.sf__Error)" } |
                Sort-Object Count -Descending |
                ForEach-Object {
                    [ordered]@{
                        Message        = $_.Name
                        Count          = $_.Count
                        Classification = if ($UnexpectedIds.Contains("$($_.Group[0].sf__Error)")) { "UNEXPECTED" } else { "expected" }
                    }
                }
        )

        Write-Host ""
        Write-Host "------------------------------------------------------------"
        Write-Host " FAILURE CLASSIFICATION"
        Write-Host "------------------------------------------------------------"
        Write-Host ("  {0,-33} {1:N0}" -f "Rows submitted", $Rows.Count)
        Write-Host ("  {0,-33} {1:N0}" -f "Rows failed", $FailedRows.Count)
        Write-Host ("  {0,-33} {1:N0}" -f "  ...matching a known cause", ($FailedRows.Count - $Unexpected.Count))
        Write-Host ("  {0,-33} {1:N0}" -f "  ...UNEXPECTED", $Unexpected.Count)
        Write-Host ("  {0,-33} {1:N0}" -f "Allowance for expected failures", $Allowance)
        Write-Host ("  Detail: {0}" -f $FailureDirectory)

        if ($ExpectedFailurePatterns.Count -eq 0) {
            Write-Host ""
            Write-Host "  No expected-failure patterns are configured for $ObjectApiName," -ForegroundColor Red
            Write-Host "  so every failure counts as real." -ForegroundColor Red
            $LoadFailed = $true
            # No patterns means the classifier above already marked every row
            # unexpected - only the explanation needs recording.
            $StepResult.ErrorMessage = "No expected-failure patterns are configured for $ObjectApiName, so all $($FailedRows.Count) failure(s) count as real."
        }
        elseif ($Unexpected.Count -gt 0) {
            Write-Host ""
            Write-Host "  $($Unexpected.Count) failure(s) do NOT match any known cause for this object." -ForegroundColor Red
            Write-Host "  That is a real failure, not an expected partial. First few:" -ForegroundColor Red
            $Unexpected | Select-Object -First 3 | ForEach-Object {
                Write-Host ("    {0}" -f ("$($_.sf__Error)" -replace '\s+', ' ')) -ForegroundColor Red
            }
            $LoadFailed = $true
            $StepResult.ErrorMessage = "$($Unexpected.Count) failure(s) do not match any known cause for $ObjectApiName."
        }
        elseif ($FailedRows.Count -gt $Allowance) {
            Write-Host ""
            Write-Host "  All failures match a known cause, but $($FailedRows.Count) exceeds the allowance of $Allowance." -ForegroundColor Red
            Write-Host "  A known cause at unusual volume means something upstream changed - stopping." -ForegroundColor Red
            $LoadFailed = $true
            $StepResult.ErrorMessage = "All failures match a known cause, but $($FailedRows.Count) exceeds the allowance of $Allowance - a known cause at unusual volume."
        }
        else {
            Write-Host ""
            Write-Host "  EXPECTED PARTIAL - every failure matches a known cause for this object," -ForegroundColor Yellow
            Write-Host "  and the count is within the allowance. This is a correct outcome." -ForegroundColor Yellow
            Write-Host "  $($Rows.Count - $FailedRows.Count) of $($Rows.Count) row(s) loaded." -ForegroundColor Green
            $ExpectedPartial = $true
            $StepResult.Outcome = "expected-partial"
        }
    }
}

if ($LoadFailed) {
    $StepResult.Outcome = "failed"
    throw "Load of $ObjectApiName failed. See the classification above."
}

# EXIT 2 = "loaded, with expected partial failures". A distinct code rather than
# 0, so a caller can tell a clean load from a partial one without parsing text -
# Invoke-FullMigrationLoad.ps1 maps it to PARTIAL and carries on. It is NOT a
# failure: the orchestrator's own exit code stays 0 when partials are all it saw
# (decided 2026-08-13), because a non-zero overall result is precisely what made
# a correct run look broken.
if ($ExpectedPartial) {
    exit 2
}

}
finally {
    # RESTORE THE TRIGGER CONTROL NO MATTER WHAT.
    # This lives in `finally` deliberately: if the load throws, the CLI dies,
    # or the operator interrupts, leaving FCIC's Contact trigger disabled would
    # silently break another team's app in a shared sandbox, with nothing to
    # indicate why. Restoring is more important than reporting the load result,
    # which is why this runs before Stop-ScriptLog.
    if ($DisableTriggerControl -and $TriggerControl -and $TriggerControlOriginalOn) {
        Write-Host ""
        Write-Host "Restoring TriggerControls__c '$DisableTriggerControl' to On__c=true..." -ForegroundColor Cyan
        try {
            Set-TriggerControlState -RecordId $TriggerControl.Id -On $true -Org $OrgAlias

            # VERIFY - never assume the write landed.
            $Verify = Get-TriggerControlState -ControlName $DisableTriggerControl -Org $OrgAlias -Version $ApiVersion
            if ([bool]$Verify.On__c) {
                Write-Host "Restored and verified: On__c=true." -ForegroundColor Green
            }
            else {
                Write-Host "!!! RESTORE VERIFICATION FAILED - On__c is still FALSE !!!" -ForegroundColor Red
                Write-Host "!!! The FCIC app's Contact trigger is DISABLED in $OrgAlias.  !!!" -ForegroundColor Red
                Write-Host "!!! Fix manually: Setup > Custom Settings > TriggerControls > Contact > On = true" -ForegroundColor Red
                Write-Host "!!! Or: sf data update record --sobject TriggerControls__c --record-id $($TriggerControl.Id) --values `"On__c=true`" --target-org $OrgAlias" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "!!! FAILED TO RESTORE TriggerControls__c '$DisableTriggerControl' !!!" -ForegroundColor Red
            Write-Host "!!! $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "!!! The FCIC app's Contact trigger is DISABLED in $OrgAlias - restore it manually:" -ForegroundColor Red
            Write-Host "!!! sf data update record --sobject TriggerControls__c --record-id $($TriggerControl.Id) --values `"On__c=true`" --target-org $OrgAlias" -ForegroundColor Red
        }
    }

    # Report what this step did, LAST but unconditionally. A step that threw is
    # exactly the one whose detail the run summary needs, and by this point
    # $StepResult carries whatever was established before the throw - including
    # Outcome="error" if it never got as far as classifying anything.
    Save-StepResult -Path $StepResultPath -Result $StepResult

    Stop-ScriptLog
}
