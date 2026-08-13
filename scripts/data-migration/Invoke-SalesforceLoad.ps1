#Requires -Version 5.1

<#
    Chunk 5 of the Airtable -> Salesforce data-migration pipeline (see
    docs/README.md) - the actual load step. Wraps `sf data
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

    # Empty = use the environment's registered alias (scripts/common/Common.Orgs.ps1).
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
    [string]$DisableTriggerControl = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
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
#   docs/AIRTABLE-DATA-QUALITY-REQUESTS.md). Loading them with the trigger
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
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "sf $($Arguments -join ' ')" -ForegroundColor DarkGray

    $RawResult = & sf @Arguments --json

    if ($LASTEXITCODE -ne 0) {
        Write-Host $RawResult -ForegroundColor Red
        throw "Salesforce CLI command failed with exit code $LASTEXITCODE."
    }

    return $RawResult | ConvertFrom-Json
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

if ($Rows.Count -eq 0) {
    Write-Host "CSV has no data rows. Nothing to load." -ForegroundColor Yellow
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
$CurrentCount = [int]$CurrentCountResult.result.totalSize

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
    exit 0
}

if (-not (Assert-LdgcrmTypedConfirmation `
        -Token "LOAD" `
        -Provided $Confirmation `
        -Action "$Operation $($Rows.Count.ToString('N0')) row(s) into $ObjectApiName in $OrgAlias")) {
    Write-Host ""
    Write-Host "Load cancelled. Nothing was written." -ForegroundColor Yellow
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

$LoadResult = Invoke-SalesforceCliJson -Arguments $LoadArguments
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

if ($JobInfo) {
    # Shape used by `sf data upsert bulk`.
    Write-Host ("{0,-35} {1}" -f "Job ID", $JobInfo.id)
    Write-Host ("{0,-35} {1}" -f "State", $JobInfo.state)
    Write-Host ("{0,-35} {1:N0}" -f "Records processed", $JobInfo.numberRecordsProcessed)
    Write-Host ("{0,-35} {1:N0}" -f "Records failed", $JobInfo.numberRecordsFailed)
}
elseif ($null -ne $LoadResult.result.processedRecords) {
    # Flat shape used by `sf data update bulk`.
    Write-Host ("{0,-35} {1}" -f "Job ID", $LoadResult.result.jobId)
    Write-Host ("{0,-35} {1:N0}" -f "Records processed", $LoadResult.result.processedRecords)
    Write-Host ("{0,-35} {1:N0}" -f "Records successful", $LoadResult.result.successfulRecords)
    Write-Host ("{0,-35} {1:N0}" -f "Records failed", $LoadResult.result.failedRecords)
}
else {
    Write-Host "Full result written to:" -ForegroundColor Cyan
    Write-Host $ResultFile
}

Write-Host ""
Write-Host "Full job result:" -ForegroundColor Cyan
Write-Host $ResultFile

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

    Stop-ScriptLog
}
