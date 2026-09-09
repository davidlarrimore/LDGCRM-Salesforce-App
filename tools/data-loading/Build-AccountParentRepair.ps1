#Requires -Version 5.1
<#
.SYNOPSIS
    Repoints Accounts whose ParentId names a DUPLICATE of the real parent, so
    the org's own hierarchy validation rules stop rejecting them.

.DESCRIPTION
    Two validation rules on Account are live in this org, both owned by another
    app and both correct:

      OTCRM_Federal_Parent_Account_Level_Check
          a Level 2 Account's parent must be Level 1, a Level 3's must be
          Level 2, a Level 4+'s must be Level 3.
      Parent_Account_Required_for_Level_3_Acct
          an Account marked "Level 3 or below" must have a parent.

    Neither reads a field this migration writes, but Salesforce re-runs every
    validation rule on every save - so an Account whose EXISTING hierarchy
    breaks a rule rejects an unrelated update. That is what stopped the UAT run
    of 2026-08-24: 20 of 690 reconciliation updates failed on ParentId, a field
    the reconciliation does not send.

    WHY THE PARENT LOOKS WRONG WHEN IT IS NOT MISSING
    -------------------------------------------------
    The parent is found. The parent is a DUPLICATE carrying the wrong level.
    Production holds two "Department of Defense" Accounts: one Level 1 with no
    parent, and one marked "Level 3 or below" that is ITS OWN PARENT. 62 Level 2
    Accounts hang off the broken one, and every one of them is unsaveable by
    anyone, through any tool, until it is repointed.

    THE RULE THIS APPLIES (project owner, 2026-08-24)
    ------------------------------------------------
    Where a child breaks the level rule AND another Account of the same name as
    its parent carries exactly the level the rule requires, repoint the child at
    that one. Where no same-named alternative satisfies the rule, CHANGE
    NOTHING and report it - the President Personnel Office cluster is a genuine
    mis-filing, not a duplicate, and guessing would move records nobody asked to
    move.

    This is the ONLY place the pipeline writes Account.ParentId on records it
    did not create. It is deliberately a separate, separately-confirmed step
    rather than part of the reconciliation, so an operator can see it, skip it
    with -OnlySteps, and roll it back from the run's restore point.

    READ-ONLY AGAINST SALESFORCE. Writes a CSV; the update is a separate,
    confirmed step (Invoke-SalesforceLoad.ps1 -Operation Update).

.PARAMETER PlanOnly
    Print the itemised report of what WOULD be repointed and write no load file.

.EXAMPLE
    .\Build-AccountParentRepair.ps1 -Environment UAT -PlanOnly
    Reports every repoint that would be made, and changes nothing.
#>

[CmdletBinding()]
param(
    [ValidateSet("Dev", "QA")]
    [string]$Environment = "Dev",

    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # Report what would be repointed and write no load file.
    [switch]$PlanOnly
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")
. (Join-Path $PSScriptRoot "Common.AccountMatching.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias
$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-AccountParentRepair"

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ACCOUNT PARENT REPAIR (hierarchy -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "READ-ONLY against Salesforce. No records are changed by this script." -ForegroundColor Yellow
if ($PlanOnly) {
    Write-Host "-PlanOnly: reporting what would be repointed; no load file will be written." -ForegroundColor Yellow
}
Write-Host ""

# ------------------------------------------------------------
# SOURCE
# ------------------------------------------------------------

# SCOPED TO THE RECORD TYPES THIS MIGRATION OWNS. Both validation rules test
# RecordType Federal, so records outside our scope cannot be affected by them
# and are none of our business either way (standing rule, 2026-08-24).
$AccountScope = Get-LdgcrmOwnedRecordTypeClause -SObject "Account"

Write-Host "Querying Salesforce Accounts and their parents..." -ForegroundColor Cyan
$Soql = "SELECT Id, Name, ParentId, Parent.Name, Parent.Account_Level__c, Account_Level__c " +
        "FROM Account WHERE $AccountScope"
$Accounts = @(Invoke-SalesforceQuery -Soql $Soql -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
Write-Host "$($Accounts.Count) Salesforce Account records found (owned record types only)."

# ------------------------------------------------------------
# DECIDE
# ------------------------------------------------------------

# Flattened so the rule sees one shape. The decision itself lives in
# Common.AccountMatching.ps1 as Get-LdgcrmParentRepairPlan, deliberately: it is
# the only rule here that writes ParentId on a record this migration did not
# create, and as a pure function it can be tested without an org. It has to be -
# Dev and QA carry a bootstrapped hierarchy with a blank Account_Level__c, so
# neither validation rule can fire there and this whole path is dead code until
# it meets a copy of production.
$Shaped = @($Accounts | ForEach-Object {
    $ParentNameValue = ""
    $ParentLevelValue = ""
    if ($_.Parent) {
        if ($_.Parent.Name) { $ParentNameValue = "$($_.Parent.Name)" }
        if ($_.Parent.Account_Level__c) { $ParentLevelValue = "$($_.Parent.Account_Level__c)" }
    }
    [PSCustomObject]@{
        Id          = $_.Id
        Name        = $_.Name
        ParentId    = "$($_.ParentId)"
        ParentName  = $ParentNameValue
        ParentLevel = $ParentLevelValue
        Level       = "$($_.Account_Level__c)"
    }
})

$Plan = Get-LdgcrmParentRepairPlan -Accounts $Shaped

$RepairRows = $Plan.Repairs
$ReviewRows = $Plan.Review
$SelfParented = $Plan.SelfParented
$AlreadySound = $Plan.AlreadySound

# ------------------------------------------------------------
# OUTPUT
# ------------------------------------------------------------

$LogDirectory = Get-LogDirectory -Category "data-migration"

$Repointed = @($ReviewRows | Where-Object { $_.Rule -eq "REPOINTED" }).Count
$NeedsHuman = @($ReviewRows | Where-Object { $_.Rule -ne "REPOINTED" }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ACCOUNT PARENT REPAIR COMPLETE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-48} {1,8:N0}" -f "Accounts examined", $Accounts.Count)
Write-Host ("{0,-48} {1,8:N0}" -f "  parent level already correct", $AlreadySound)
Write-Host ("{0,-48} {1,8:N0}" -f "  TO REPOINT (sound twin found)", $Repointed) -ForegroundColor $(if ($Repointed) { "Green" } else { "Gray" })
Write-Host ("{0,-48} {1,8:N0}" -f "  NEEDS A HUMAN (no sound twin)", $NeedsHuman) -ForegroundColor $(if ($NeedsHuman) { "Yellow" } else { "Gray" })
Write-Host ("{0,-48} {1,8:N0}" -f "  self-parented (reported only)", $SelfParented.Count) -ForegroundColor $(if ($SelfParented.Count) { "Yellow" } else { "Gray" })

if ($ReviewRows.Count -gt 0) {
    $ReviewPath = Join-Path $LogDirectory "AccountParentRepair-decisions-$Timestamp.csv"
    Export-DataLoaderCsv -InputObject $ReviewRows -Path $ReviewPath
    Write-Host ""
    Write-Host "Every decision, repointed and not: $ReviewPath" -ForegroundColor Yellow
}

if ($SelfParented.Count -gt 0) {
    $SelfPath = Join-Path $LogDirectory "AccountParentRepair-self-parented-$Timestamp.csv"
    Export-DataLoaderCsv -InputObject $SelfParented -Path $SelfPath
    Write-Host "Self-parented, needs merging:     $SelfPath" -ForegroundColor Yellow
}

if ($PlanOnly) {
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " WOULD REPOINT $($RepairRows.Count) ACCOUNT(S)" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan

    if ($RepairRows.Count -eq 0) {
        Write-Host "  (none)"
    }
    else {
        foreach ($Row in ($ReviewRows | Where-Object { $_.Rule -eq "REPOINTED" } | Sort-Object Name)) {
            Write-Host ""
            Write-Host ("  {0}" -f $Row.Name) -ForegroundColor Green
            Write-Host ("      level    : {0}" -f $Row.Level)
            Write-Host ("      was under: {0}" -f $Row.CurrentParent)
            Write-Host ("      now under: {0}" -f $Row.Reason)
        }
    }

    Write-Host ""
    Write-Host "-PlanOnly: no load file was written. Re-run without it to produce one." -ForegroundColor Yellow
}
else {
    $LoadDirectory = Join-Path (Get-LdgcrmRoot) "data\salesforce-loads"
    if (-not (Test-Path -LiteralPath $LoadDirectory)) { New-Item -ItemType Directory -Path $LoadDirectory -Force | Out-Null }

    $RepairPath = Join-Path $LoadDirectory "Account-parent-repair.csv"

    # Nothing to repoint is the CORRECT outcome once the hierarchy is sound, and
    # is what a healthy org looks like. Export-DataLoaderCsv refuses to write a
    # headerless empty file, so a stale file is removed rather than left for the
    # orchestrator to load against today's org.
    if ($RepairRows.Count -eq 0) {
        if (Test-Path -LiteralPath $RepairPath) { Remove-Item -LiteralPath $RepairPath -Force }
        Write-Host ""
        Write-Host "No Accounts need repointing - every parent carries the level its child requires." -ForegroundColor Green
        Write-Host "No repair file written." -ForegroundColor Green
    }
    else {
        Export-DataLoaderCsv -InputObject $RepairRows -Path $RepairPath

        Write-Host ""
        Write-Host "Repair file (UPDATE - repoints ParentId on existing Accounts):" -ForegroundColor Green
        Write-Host "  $RepairPath"
        Write-Host ""
        Write-Host "THIS CHANGES HIERARCHY ON RECORDS THIS MIGRATION DID NOT CREATE." -ForegroundColor Yellow
        Write-Host "Review it before loading. Run with -PlanOnly for the itemised report." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "No records were changed in $OrgAlias by this script." -ForegroundColor Yellow

}
finally {
    Stop-ScriptLog
}
