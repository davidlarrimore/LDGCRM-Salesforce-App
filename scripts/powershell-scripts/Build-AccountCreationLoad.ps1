#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the INSERT file for Airtable Accounts that have no Salesforce
    Account, after exhausting every way of matching an existing one.

.DESCRIPTION
    The reconciliation (Build-AccountReconciliation.ps1) matches Airtable rows
    onto Accounts that already exist and never creates one. This script covers
    what is left: rows that genuinely have nowhere to land.

    IT ONLY PROPOSES A NEW ACCOUNT AFTER THE WHOLE ORG HAS BEEN SWEPT.
    Production disambiguates same-named offices with an agency suffix ("Office
    of Civil Rights - GSA") while Airtable stores the bare name plus a Parent
    column, so a naive matcher proposes creating dozens of records that already
    exist. The cascade lives in Common.AccountMatching.ps1 and is shared with
    the reconciliation so both answer "is this the same office?" identically.

    WHAT IT SETS, AND WHAT IT DELIBERATELY DOES NOT
    -----------------------------------------------
    Set:    Name, ParentId, Account_Level__c, Type, RecordTypeId, OwnerId,
            LDGCRM_External_ID__c, LDGCRM_Market_Segment__r.
    NOT set: Level_1_Account__c, Level_2_Account__c, Level_3_Account__c and
            Agency_Acronym__c are FORMULA fields. They walk Parent.Parent...
            themselves, so they populate from ParentId alone and Salesforce
            rejects any attempt to write them.

    READ-ONLY AGAINST SALESFORCE. Writes a CSV; the insert is a separate,
    confirmed step (Invoke-SalesforceLoad.ps1 -Operation Insert).

.PARAMETER PlanOnly
    Print the itemised report of what WOULD be created and write no load file.
    Use this to review before anything is inserted. Without it the script writes
    Account-insert.csv and prints counts only.

.EXAMPLE
    .\Build-AccountCreationLoad.ps1 -Environment Dev -PlanOnly
    Reports every Account that would be created, and creates nothing.
#>

[CmdletBinding()]
param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # Airtable's Accounts table records no owner, so every created Account takes
    # this one. Resolved at run time; the run FAILS if it isn't an active,
    # assignable User.
    [string]$FallbackOwnerEmail = "peter.marks@gsa.gov",

    # Report what would be created and write no load file.
    [switch]$PlanOnly,

    # Below this, a similar name inside the agency is reported for a human
    # rather than treated as a match. Lowering it matches more and risks
    # attaching records to the wrong office; raising it creates more duplicates.
    [int]$ConfirmThreshold = 55
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")
. (Join-Path $PSScriptRoot "Common.AccountMatching.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias
$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-AccountCreationLoad"

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ACCOUNT CREATION PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "READ-ONLY against Salesforce. No records are created by this script." -ForegroundColor Yellow
if ($PlanOnly) {
    Write-Host "-PlanOnly: reporting what would be created; no load file will be written." -ForegroundColor Yellow
}
Write-Host ""

# ------------------------------------------------------------
# SOURCES
# ------------------------------------------------------------

Write-Host "Resolving the fallback owner ($FallbackOwnerEmail)..." -ForegroundColor Cyan
$FallbackOwnerId = Resolve-FallbackOwnerId -Email $FallbackOwnerEmail -OrgAlias $OrgAlias -ApiVersion $ApiVersion
Write-Host "Fallback owner resolves to $FallbackOwnerId."

Write-Host "Loading Airtable Accounts export..." -ForegroundColor Cyan
$AirtableAccounts = Import-AirtableTable -Label "Accounts"
Write-Host "$($AirtableAccounts.Count) Airtable Account rows loaded."

Write-Host "Resolving the Federal Account record type..." -ForegroundColor Cyan
$RecordTypeRows = @(Invoke-SalesforceQuery `
    -Soql "SELECT Id, DeveloperName FROM RecordType WHERE SObjectType = 'Account' AND DeveloperName = 'Federal'" `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
if ($RecordTypeRows.Count -ne 1) {
    throw "Expected exactly one Federal Account record type, found $($RecordTypeRows.Count). Cannot create Accounts without it."
}
$FederalRecordTypeId = $RecordTypeRows[0].Id
Write-Host "Federal record type: $FederalRecordTypeId"

Write-Host "Querying existing Salesforce Accounts..." -ForegroundColor Cyan
$SfRaw = @(Invoke-SalesforceQuery `
    -Soql ("SELECT Id, Name, ParentId, Parent.Name, Account_Level__c, LDGCRM_External_ID__c FROM Account") `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
Write-Host "$($SfRaw.Count) Salesforce Account records found."

# Flatten Parent.Name to ParentName so the same index code serves both a
# Salesforce query and the production export.
$SfAccounts = @($SfRaw | ForEach-Object {
    $ParentName = ""
    if ($_.Parent -and $_.Parent.Name) { $ParentName = $_.Parent.Name }
    [PSCustomObject]@{
        Id         = $_.Id
        Name       = $_.Name
        ParentId   = $_.ParentId
        ParentName = $ParentName
        Level      = $_.Account_Level__c
        ExternalId = $_.LDGCRM_External_ID__c
    }
})

# Id -> account, so a new record's depth can be measured by walking ParentId.
# Account_Level__c itself is unusable for this: it is blank on almost every
# Account in a bootstrapped sandbox, so deriving a child's level from its
# parent's field labels everything "Level 1".
$SfAccountsById = @{}
foreach ($Account in $SfAccounts) { $SfAccountsById[$Account.Id] = $Account }

$Index = New-LdgcrmAccountIndex -Accounts $SfAccounts
Write-Host "Agency suffix conventions learned from this org: $($Index.SuffixByAgency.Count)"

# Every external ID already on an Account, so rows the reconciliation owns are
# not proposed for creation.
$TaggedExternalIds = @{}
foreach ($Account in $SfAccounts) {
    if (-not [string]::IsNullOrWhiteSpace($Account.ExternalId)) { $TaggedExternalIds[$Account.ExternalId] = $true }
}

# ------------------------------------------------------------
# RESOLVE
# ------------------------------------------------------------

$InsertRows      = [System.Collections.Generic.List[object]]::new()
$ConfirmRows     = [System.Collections.Generic.List[object]]::new()
$BlockedRows     = [System.Collections.Generic.List[object]]::new()
$AlreadyTagged   = 0
$MatchedExisting = 0

foreach ($Row in $AirtableAccounts) {
    $RecId    = $Row.id
    $AtName   = $Row.fields.Name
    $AtParent = @($Row.fields.Parent) | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($AtName)) {
        $BlockedRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            AirtableName     = ""
            AirtableParent   = $AtParent
            Reason           = "No Name in Airtable. An Account cannot be created without one."
        })
        continue
    }

    if ($TaggedExternalIds.ContainsKey($RecId)) { $AlreadyTagged++; continue }

    $Resolution = Resolve-LdgcrmAccount -Index $Index -Name $AtName -ParentName $AtParent -ConfirmThreshold $ConfirmThreshold

    if ($Resolution.Verdict -eq "Match") { $MatchedExisting++; continue }

    if ($Resolution.Verdict -eq "Confirm") {
        $ConfirmRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            AirtableName     = $AtName
            AirtableParent   = $AtParent
            Candidates       = (@($Resolution.Candidates | ForEach-Object {
                                    if ($_.PSObject.Properties.Name -contains 'Account') { $_.Account.Name } else { $_.Name }
                                }) -join " | ")
            Reason           = "$($Resolution.Route). NOT created - a human must decide whether one of these is the same office."
        })
        continue
    }

    # ---------------- Create ----------------
    # The parent must already exist, and unambiguously. Creating a child under
    # a guessed parent puts an agency's records in the wrong place, which is
    # the failure this whole pass exists to avoid - so an unresolvable parent
    # blocks the row rather than producing a top-level orphan.
    $ParentId    = ""
    $ParentDepth = -1

    if (-not [string]::IsNullOrWhiteSpace($AtParent)) {
        $ParentKey   = Get-LdgcrmNameLoose -Name $AtParent
        $ParentHits  = @()
        if ($Index.ByLoose.ContainsKey($ParentKey)) { $ParentHits = @($Index.ByLoose[$ParentKey]) }

        if ($ParentHits.Count -eq 0) {
            $BlockedRows.Add([PSCustomObject]@{
                AirtableRecordId = $RecId
                AirtableName     = $AtName
                AirtableParent   = $AtParent
                Reason           = "Parent '$AtParent' does not exist in this org, so the child cannot be placed. Create the parent first, or correct the Parent in Airtable."
            })
            continue
        }
        if ($ParentHits.Count -gt 1) {
            $BlockedRows.Add([PSCustomObject]@{
                AirtableRecordId = $RecId
                AirtableName     = $AtName
                AirtableParent   = $AtParent
                Reason           = "Parent '$AtParent' matches $($ParentHits.Count) Accounts, so the right one cannot be chosen. Disambiguate before creating."
            })
            continue
        }

        $ParentId    = $ParentHits[0].Id
        $ParentDepth = Get-LdgcrmAccountDepth -AccountsById $SfAccountsById -AccountId $ParentId
    }

    # Depth 0 is a top-level record; a child sits one below its parent.
    $Level = Get-LdgcrmAccountLevel -Depth ($ParentDepth + 1)

    $Segment = Get-LdgcrmMarketSegmentName -AirtableValue $Row.fields.'Market Segment'
    $Type    = if ($Row.fields.'States + DC/PR') { "State" } else { "Federal" }

    $InsertRows.Add([PSCustomObject]@{
        Name                                            = $Resolution.ProposedName
        ParentId                                        = $ParentId
        Account_Level__c                                = $Level
        Type                                            = $Type
        RecordTypeId                                    = $FederalRecordTypeId
        OwnerId                                         = $FallbackOwnerId
        LDGCRM_External_ID__c                           = $RecId
        'LDGCRM_Market_Segment__r.LDGCRM_External_ID__c' = $Segment
    })

}

# ------------------------------------------------------------
# OUTPUT
# ------------------------------------------------------------

$LogDirectory = Get-LogDirectory -Category "data-migration"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ACCOUNT CREATION PREP COMPLETE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-48} {1,8:N0}" -f "Airtable Account rows", $AirtableAccounts.Count)
Write-Host ("{0,-48} {1,8:N0}" -f "  already tagged (reconciliation owns them)", $AlreadyTagged)
Write-Host ("{0,-48} {1,8:N0}" -f "  matched an existing Account", $MatchedExisting)
Write-Host ("{0,-48} {1,8:N0}" -f "  NEEDS A HUMAN (candidates found)", $ConfirmRows.Count) -ForegroundColor $(if ($ConfirmRows.Count) { "Yellow" } else { "Gray" })
Write-Host ("{0,-48} {1,8:N0}" -f "  BLOCKED (cannot place)", $BlockedRows.Count) -ForegroundColor $(if ($BlockedRows.Count) { "Yellow" } else { "Gray" })
Write-Host ("{0,-48} {1,8:N0}" -f "  TO CREATE", $InsertRows.Count) -ForegroundColor Green

if ($ConfirmRows.Count -gt 0) {
    $ConfirmPath = Join-Path $LogDirectory "AccountCreation-needs-review-$Timestamp.csv"
    Export-DataLoaderCsv -InputObject $ConfirmRows -Path $ConfirmPath
    Write-Host ""
    Write-Host "Needs a human decision: $ConfirmPath" -ForegroundColor Yellow
}

if ($BlockedRows.Count -gt 0) {
    $BlockedPath = Join-Path $LogDirectory "AccountCreation-blocked-$Timestamp.csv"
    Export-DataLoaderCsv -InputObject $BlockedRows -Path $BlockedPath
    Write-Host "Blocked, cannot place:   $BlockedPath" -ForegroundColor Yellow
}

if ($PlanOnly) {
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " WOULD CREATE $($InsertRows.Count) ACCOUNT(S)" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan

    if ($InsertRows.Count -eq 0) {
        Write-Host "  (none)"
    }
    else {
        $ParentNameById = @{}
        foreach ($Account in $SfAccounts) { $ParentNameById[$Account.Id] = $Account.Name }

        foreach ($New in ($InsertRows | Sort-Object Name)) {
            $Under = if ($New.ParentId) { $ParentNameById[$New.ParentId] } else { "(top level)" }
            Write-Host ""
            Write-Host ("  {0}" -f $New.Name) -ForegroundColor Green
            Write-Host ("      under    : {0}" -f $Under)
            Write-Host ("      level    : {0}" -f $(if ($New.Account_Level__c) { $New.Account_Level__c } else { "(blank - parent level unrecognised)" }))
            Write-Host ("      type     : {0}" -f $New.Type)
            Write-Host ("      segment  : {0}" -f $(if ($New.'LDGCRM_Market_Segment__r.LDGCRM_External_ID__c') { $New.'LDGCRM_Market_Segment__r.LDGCRM_External_ID__c' } else { "(none)" }))
            Write-Host ("      ext id   : {0}" -f $New.LDGCRM_External_ID__c)
        }
    }

    Write-Host ""
    Write-Host "-PlanOnly: no load file was written. Re-run without it to produce one." -ForegroundColor Yellow
}
else {
    $LoadDirectory = Join-Path (Get-LdgcrmRoot) "data\salesforce-loads"
    if (-not (Test-Path -LiteralPath $LoadDirectory)) { New-Item -ItemType Directory -Path $LoadDirectory -Force | Out-Null }

    $InsertPath = Join-Path $LoadDirectory "Account-insert.csv"
    Export-DataLoaderCsv -InputObject $InsertRows -Path $InsertPath

    Write-Host ""
    Write-Host "Insert file (INSERT, not upsert - these Accounts do not exist yet):" -ForegroundColor Green
    Write-Host "  $InsertPath"
    Write-Host ""
    Write-Host "Review it before loading. Run with -PlanOnly for the itemised report." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "No records were created in $OrgAlias by this script." -ForegroundColor Yellow

}
finally {
    Stop-ScriptLog
}
