#Requires -Version 5.1

<#
    Chunk 1 of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md for the full pipeline).

    Account is a special case: unlike every other object in this migration,
    Salesforce Account records already exist independently of Airtable (they
    aren't being created by this migration), and in production most of them
    don't yet carry LDGCRM_External_ID__c. So this script does not produce
    an upsert-on-external-ID file like the other Build-*.ps1 transforms
    will. It reconciles Airtable "Accounts" rows against existing Salesforce
    Account records (external ID match first, then exact Name match) and
    produces an UPDATE file (keyed on Salesforce Id) that backfills
    LDGCRM_External_ID__c, LDGCRM_Market_Segment__c, and Type on the matched rows.

    Type mapping: Airtable's "States + DC/PR" checkbox on Accounts isn't a list of
    states - it's a boolean that distinguishes state/DC/territory government
    Accounts from federal ones. Confirmed against gsa-peo's existing data (54
    Accounts already Type="State", 530 already Type="Federal", matching the ~52
    Airtable rows with the checkbox set) rather than assumed: checked -> "State",
    unchecked/absent -> "Federal". This does not touch RecordType - every Account
    in gsa-peo, State or Federal Type, uses the Federal RecordType; the State/
    Federal distinction lives entirely in the Type field.

    Airtable rows that can't be confidently matched (no existing Account, or
    more than one Account with the same Name) are written to review CSVs
    instead of being guessed at - per CLAUDE.md, an unmatched Account row is
    a decision for a human, not something a script should resolve by
    creating a new Account or picking among duplicates.

    Read-only against Salesforce (a single SOQL query) - this script does
    not write to gsa-peo. It only produces local CSVs.
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (powershell-scripts/Common.Orgs.ps1).
    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")
. (Join-Path $PSScriptRoot "Common.AccountMatching.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-AccountReconciliation"

# Airtable's Accounts table "Market Segment" text values don't exactly match the
# 5 real LDGCRM_Market_Segment__c records' Name/LDGCRM_External_ID__c (which
# store the segment name) in 3 of 5 cases - confirmed by querying gsa-peo
# directly rather than assumed. "Benefits" and "Infrastructure" already match
# and don't need an entry here.
# The map itself now lives in Common.AccountMatching.ps1 as
# Get-LdgcrmMarketSegmentName, shared with Build-AccountCreationLoad.ps1.
# Account is the ONE object where the migration writes Market Segment directly -
# the other three get it from a before-save Flow - so two copies of this map
# would diverge silently and only Account would be wrong.

# Name normalisation lives in Common.AccountMatching.ps1 too
# (Get-LdgcrmNameExact / Get-LdgcrmNameLoose). The local copy folded case only,
# so it saw "Economic & Business Affairs" and "Economic and Business Affairs" as
# different offices; the shared one does not.

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ACCOUNT RECONCILIATION (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Target org alias: $OrgAlias"
Write-Host "This script is READ-ONLY against Salesforce. No records are written or updated." -ForegroundColor Yellow
Write-Host ""

# ============================================================
# LOAD SOURCE DATA
# ============================================================

Write-Host "Loading Airtable Accounts export..." -ForegroundColor Cyan
$AirtableAccounts = Import-AirtableTable -Label "Accounts"
Write-Host "$($AirtableAccounts.Count) Airtable Account rows loaded."

Write-Host ""
Write-Host "Querying existing Salesforce Accounts..." -ForegroundColor Cyan
# Parent.Name is read so a Name shared by several agencies can be told apart by
# the agency it sits under - see "DISAMBIGUATING BY PARENT" below.
$Soql = "SELECT Id, Name, Type, ParentId, Parent.Name, LDGCRM_External_ID__c, LDGCRM_Market_Segment__r.LDGCRM_External_ID__c FROM Account"
$SalesforceAccounts = @(Invoke-SalesforceQuery -Soql $Soql -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
Write-Host "$($SalesforceAccounts.Count) Salesforce Account records found."

# ============================================================
# INDEX SALESFORCE ACCOUNTS
# ============================================================

# Records already carrying an external ID - matched immediately, no name
# lookup needed.
$SfByExternalId = [System.Collections.Generic.Dictionary[string, object]]::new()

# ------------------------------------------------------------
# PARENT IS A VETO, NOT A TIE-BREAKER
#
# Several agencies each run an office with the same generic name - four
# departments have an "Office of the Inspector General", and OPM, NASA, NSF and
# CDC all have an "Office of the Director". Airtable's Accounts table carries a
# plain-text `Parent` column naming the agency; Salesforce carries the
# equivalent as Account.ParentId.
#
# The parent used to be consulted ONLY when two or more Accounts shared a name.
# A name matching exactly one Account won outright - so a Housing and Urban
# Development row matched Commerce's "Office of the Secretary", and six others
# like it attached one agency's records to another agency's office while the run
# reported success. Seven Accounts were linked that way.
#
# Now the agency selects the candidate pool before any name is compared, so an
# office belonging to a different department is never a candidate at all,
# however well the names agree.
#
# Two things this deliberately does NOT do:
#   - It never picks one when the agency does not decide it. Several candidates,
#     or none, is reported for human review.
#   - It never lets two Airtable rows claim the same Salesforce Account. The
#     claimed record leaves the pool, and the second row is reported as a
#     duplicate rather than silently overwriting the first one's external ID.
#
# NOTE the parent must actually be populated in the target org for this to fire.
# A sandbox rebuilt by Invoke-AccountBootstrap.ps1 can be missing the parent on
# exactly the ambiguous records (it identifies Accounts by name too, so it hits
# the same wall). That is a sandbox artifact - production carries the real
# hierarchy - but it means this matching can be a no-op in Dev/QA while being
# correct in production.
# ------------------------------------------------------------

# Salesforce Id -> the Airtable row that claimed it, so a later row colliding on
# the same record can be told exactly which row beat it to it.
$ClaimedBy = [System.Collections.Generic.Dictionary[string, object]]::new()

$UnclaimedAccounts = [System.Collections.Generic.List[object]]::new()

foreach ($SfAccount in $SalesforceAccounts) {
    if (-not [string]::IsNullOrWhiteSpace($SfAccount.LDGCRM_External_ID__c)) {
        $SfByExternalId[$SfAccount.LDGCRM_External_ID__c] = $SfAccount
        continue
    }

    # Flatten Parent.Name so the shared index sees the same shape whether the
    # Accounts came from a SOQL query or from the production export.
    $ParentName = ""
    if ($SfAccount.Parent -and $SfAccount.Parent.Name) { $ParentName = $SfAccount.Parent.Name }
    $SfAccount | Add-Member -NotePropertyName ParentName -NotePropertyValue $ParentName -Force

    $UnclaimedAccounts.Add($SfAccount)
}

# THE MATCHING RULES NOW LIVE IN Common.AccountMatching.ps1, shared with
# Build-AccountCreationLoad.ps1 so both answer "is this the same office?"
# identically. They used to be implemented here alone, and the creation pass
# answered differently - which is how a Housing and Urban Development row came
# to own Commerce's Account.
$Index = New-LdgcrmAccountIndex -Accounts $UnclaimedAccounts.ToArray()

# Loose "<name>|<parent>" -> the Airtable row that claimed it. Once an Account
# is claimed it leaves the index entirely, so a second Airtable row for the same
# office finds nothing and would otherwise be reported as "no such Account".
# This keeps the far more useful finding: two Airtable rows describe one office.
$ClaimedByNameParent = @{}

# ============================================================
# RECONCILE
# ============================================================

$UpdateRows = [System.Collections.Generic.List[object]]::new()
$UnmatchedRows = [System.Collections.Generic.List[object]]::new()
$AmbiguousRows = [System.Collections.Generic.List[object]]::new()
$AlreadyCurrentCount = 0
# Matches that needed the parent agency to pick between same-named Accounts.
$ParentResolvedCount = 0

foreach ($AirtableRow in $AirtableAccounts) {
    $RecId = $AirtableRow.id
    $AtName = $AirtableRow.fields.Name
    $AtSegment = Get-LdgcrmMarketSegmentName -AirtableValue $AirtableRow.fields.'Market Segment'

    $DesiredType = if ($AirtableRow.fields.'States + DC/PR') { "State" } else { "Federal" }

    $MatchedSfAccount = $null
    $MatchType = $null

    if ($SfByExternalId.ContainsKey($RecId)) {
        $MatchedSfAccount = $SfByExternalId[$RecId]
        $MatchType = "ExternalId"
    }
    else {
        # Airtable's Parent is a plain-text agency name (not a linked record).
        $AtParent = @($AirtableRow.fields.Parent) | Select-Object -First 1
        $ClaimKey = (Get-LdgcrmNameLoose -Name $AtName) + "|" + (Get-LdgcrmNameLoose -Name $AtParent)

        $Resolution = Resolve-LdgcrmAccount -Index $Index -Name $AtName -ParentName $AtParent

        if ($Resolution.Verdict -eq "Match") {
            $MatchedSfAccount = $Resolution.Account
            $MatchType = "Name"

            # Anything the plain name alone would not have found was resolved by
            # the agency - either by narrowing to its subtree or by the suffix
            # convention. Counted so the run reports how much work that did.
            if ($Resolution.Route -notlike "exact name*") { $ParentResolvedCount++ }

            Remove-LdgcrmAccountFromIndex -Index $Index -Account $MatchedSfAccount
            $ClaimedBy[$MatchedSfAccount.Id] = [PSCustomObject]@{
                AirtableRecordId = $RecId
                AirtableName     = $AtName
            }
            $ClaimedByNameParent[$ClaimKey] = [PSCustomObject]@{
                AirtableRecordId = $RecId
                Account          = $MatchedSfAccount
            }
        }
        elseif ($Resolution.Verdict -eq "Confirm") {
            $AmbiguousRows.Add([PSCustomObject]@{
                AirtableRecordId       = $RecId
                AirtableName           = $AtName
                AirtableParent         = $AtParent
                AirtableMarketSegment  = $AtSegment
                AirtableDesiredType    = $DesiredType
                CandidateSalesforceIds = (@($Resolution.Candidates | ForEach-Object {
                                            if ($_.PSObject.Properties.Name -contains 'Account') { $_.Account.Id } else { $_.Id }
                                        }) -join "; ")
                Reason                 = "$($Resolution.Route). The migration will not guess between them - a human must decide."
            })
            continue
        }
        else {
            # Before calling it unmatched: did an EARLIER Airtable row already
            # claim the Account this one describes? If so these two rows are the
            # same office, which is a materially different finding from "no such
            # Account exists" - and the one the data owners can act on.
            if ($ClaimedByNameParent.ContainsKey($ClaimKey)) {
                $Winner = $ClaimedByNameParent[$ClaimKey]
                $AmbiguousRows.Add([PSCustomObject]@{
                    AirtableRecordId       = $RecId
                    AirtableName           = $AtName
                    AirtableParent         = $AtParent
                    AirtableMarketSegment  = $AtSegment
                    AirtableDesiredType    = $DesiredType
                    CandidateSalesforceIds = $Winner.Account.Id
                    Reason                 = "DUPLICATE AIRTABLE ROW. Salesforce Account $($Winner.Account.Id) ('$($Winner.Account.Name)' under '$($Winner.Account.ParentName)') was already matched by Airtable row $($Winner.AirtableRecordId). Both rows describe the same office - merge them in Airtable."
                })
                continue
            }

            $RuledOut = ""
            if ($Resolution.Candidates -and @($Resolution.Candidates).Count -gt 0) {
                $RuledOut = " Ruled out: " + (@($Resolution.Candidates | ForEach-Object {
                    if ($_.PSObject.Properties.Name -contains 'Account') { $_.Account.Name } else { $_.Name }
                }) -join "; ") + "."
            }

            $UnmatchedRows.Add([PSCustomObject]@{
                AirtableRecordId      = $RecId
                AirtableName          = $AtName
                AirtableParent        = $AtParent
                AirtableMarketSegment = $AtSegment
                AirtableDesiredType   = $DesiredType
                Reason                = "$($Resolution.Route).$RuledOut Needs an Account creating - see Build-AccountCreationLoad.ps1."
            })
            continue
        }
    }

    $CurrentSegmentExternalId = $MatchedSfAccount.LDGCRM_Market_Segment__r.LDGCRM_External_ID__c

    # A record matched on Name (with or without the parent narrowing it down)
    # has no external ID yet, so it always needs one written. Missing
    # "NameAndParent" here would silently drop the tag from every
    # parent-disambiguated Account - they would look matched and stay untagged.
    $NeedsExternalIdUpdate = ($MatchType -eq "Name" -or $MatchType -eq "NameAndParent")

    if ($MatchType -eq "NameAndParent") { $ParentResolvedCount++ }
    $NeedsSegmentUpdate = ($AtSegment -and ($CurrentSegmentExternalId -ne $AtSegment))
    $NeedsTypeUpdate = ($MatchedSfAccount.Type -ne $DesiredType)

    if (-not $NeedsExternalIdUpdate -and -not $NeedsSegmentUpdate -and -not $NeedsTypeUpdate) {
        $AlreadyCurrentCount++
        continue
    }

    $UpdateRows.Add([PSCustomObject]@{
        Id                                            = $MatchedSfAccount.Id
        LDGCRM_External_ID__c                         = $RecId
        "LDGCRM_Market_Segment__r.LDGCRM_External_ID__c" = $AtSegment
        Type                                           = $DesiredType
    })
}

# ============================================================
# WRITE OUTPUT
# ============================================================

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpdateFile = Join-Path $LoadDir "Account-update.csv"
$UnmatchedFile = Join-Path $LogDir "Account-reconciliation-unmatched-$Timestamp.csv"
$AmbiguousFile = Join-Path $LogDir "Account-reconciliation-ambiguous-$Timestamp.csv"

if ($UpdateRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $UpdateRows.ToArray() -Path $UpdateFile
}
else {
    Write-Host ""
    Write-Host "No Account records need updating - nothing written to $UpdateFile." -ForegroundColor Yellow
}

if ($UnmatchedRows.Count -gt 0) {
    $UnmatchedRows | Export-Csv -LiteralPath $UnmatchedFile -NoTypeInformation -Encoding UTF8
}

if ($AmbiguousRows.Count -gt 0) {
    $AmbiguousRows | Export-Csv -LiteralPath $AmbiguousFile -NoTypeInformation -Encoding UTF8
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " RECONCILIATION COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-45} {1,8:N0}" -f "Airtable Account rows", $AirtableAccounts.Count)
Write-Host ("{0,-45} {1,8:N0}" -f "Salesforce Account records", $SalesforceAccounts.Count)
Write-Host ("{0,-45} {1,8:N0}" -f "Matched, already current (no update needed)", $AlreadyCurrentCount)
Write-Host ("{0,-45} {1,8:N0}" -f "Matched, queued for update", $UpdateRows.Count)
Write-Host ("{0,-45} {1,8:N0}" -f "  ...of which resolved by parent agency", $ParentResolvedCount)
Write-Host ("{0,-45} {1,8:N0}" -f "Unmatched (no candidate Account)", $UnmatchedRows.Count)
Write-Host ("{0,-45} {1,8:N0}" -f "Ambiguous (multiple candidate Accounts)", $AmbiguousRows.Count)

# Airtable rows that describe an office another row already claimed. Called out
# separately because the fix is an Airtable merge, not a Salesforce decision.
$DuplicateAirtableRows = @($AmbiguousRows | Where-Object { $_.Reason -like "DUPLICATE AIRTABLE ROW*" })
if ($DuplicateAirtableRows.Count -gt 0) {
    Write-Host ("{0,-45} {1,8:N0}" -f "  ...of which are duplicate Airtable rows", $DuplicateAirtableRows.Count) -ForegroundColor Yellow
}

if ($ParentResolvedCount -eq 0 -and $AmbiguousRows.Count -gt 0) {
    Write-Host ""
    Write-Host "Parent-agency matching resolved nothing this run." -ForegroundColor Yellow
    Write-Host "If the ambiguous rows say '(no parent set)', the target org is missing" -ForegroundColor Yellow
    Write-Host "the Account hierarchy - see Invoke-AccountBootstrap.ps1 and docs/TROUBLESHOOTING.md." -ForegroundColor Yellow
}
Write-Host ""

if ($UpdateRows.Count -gt 0) {
    Write-Host "Update file (Id-keyed, for Data Loader UPDATE - not upsert):" -ForegroundColor Cyan
    Write-Host $UpdateFile
}

if ($UnmatchedRows.Count -gt 0) {
    Write-Host "Unmatched rows for human review:" -ForegroundColor Yellow
    Write-Host $UnmatchedFile
}

if ($AmbiguousRows.Count -gt 0) {
    Write-Host "Ambiguous rows for human review:" -ForegroundColor Yellow
    Write-Host $AmbiguousFile
}

Write-Host ""
Write-Host "No records were written to $OrgAlias by this script." -ForegroundColor Yellow

}
finally {
    Stop-ScriptLog
}
