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

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-AccountReconciliation"

# Airtable's Accounts table "Market Segment" text values don't exactly match the
# 5 real LDGCRM_Market_Segment__c records' Name/LDGCRM_External_ID__c (which
# store the segment name) in 3 of 5 cases - confirmed by querying gsa-peo
# directly rather than assumed. "Benefits" and "Infrastructure" already match
# and don't need an entry here.
$MarketSegmentMap = @{
    "Defense & National Security"       = "Defense"
    "Finance (Regulation & Compliance)" = "Finance & Regulation"
    "State & Local (SLTT)"              = "State & Local"
}

function Get-NormalizedName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    return $Name.Trim().ToLowerInvariant()
}

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

# Unclaimed records (no external ID yet) indexed by normalized Name, for
# the name-match fallback. A record is removed from this pool the moment
# it's claimed by an Airtable row, so a second Airtable row with the same
# name can't silently double-claim it - it falls through to "unmatched"
# for human review instead.
$SfByName = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new()

# ------------------------------------------------------------
# DISAMBIGUATING BY PARENT
#
# Several agencies each run an office with the same generic name - OPM, NASA,
# NSF and CDC all have an "Office of Communications" or an "Office of the
# Director", and four departments each have an "Office of the Inspector
# General". Matching on Name alone finds 2+ candidates and (correctly) refuses
# to guess, which is why 8 Airtable rows were reported ambiguous on 2026-08-14.
#
# Airtable's Accounts table carries a plain-text `Parent` column naming the
# agency, and Salesforce carries the equivalent as Account.ParentId. Comparing
# the two resolves the office to exactly one Account without guessing.
#
# Two things this deliberately does NOT do:
#   - It never falls back to picking one when the parent doesn't decide it. No
#     parent match, or more than one, is still reported for human review.
#   - It never lets two Airtable rows claim the same Salesforce Account. Airtable
#     currently holds three rows for "Office of Communications" all naming OPM as
#     the parent; without the claim check they would all resolve to the same
#     record and overwrite each other's external ID, which reports as success.
#     The second and third are reported as duplicates instead.
#
# NOTE the parent must actually be populated in the target org for this to fire.
# A sandbox rebuilt by Invoke-AccountBootstrap.ps1 can be missing the parent on
# exactly the ambiguous records (it identifies Accounts by name too, so it hits
# the same wall). That is a sandbox artifact - production carries the real
# hierarchy - but it means this matching can be a no-op in Dev/QA while being
# correct in production.
# ------------------------------------------------------------

# Every unclaimed record keyed "<name>|<parent name>", kept intact for
# diagnostics after $SfByName has had claimed records removed from it.
$SfByNameAndParent = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new()

# Salesforce Id -> the Airtable row that claimed it, so a later row colliding on
# the same record can be told exactly which row beat it to it.
$ClaimedBy = [System.Collections.Generic.Dictionary[string, object]]::new()

foreach ($SfAccount in $SalesforceAccounts) {
    if (-not [string]::IsNullOrWhiteSpace($SfAccount.LDGCRM_External_ID__c)) {
        $SfByExternalId[$SfAccount.LDGCRM_External_ID__c] = $SfAccount
        continue
    }

    $NormalizedName = Get-NormalizedName -Name $SfAccount.Name

    if (-not $SfByName.ContainsKey($NormalizedName)) {
        $SfByName[$NormalizedName] = [System.Collections.Generic.List[object]]::new()
    }

    $SfByName[$NormalizedName].Add($SfAccount)

    $ParentKey = $NormalizedName + "|" + (Get-NormalizedName -Name $SfAccount.Parent.Name)

    if (-not $SfByNameAndParent.ContainsKey($ParentKey)) {
        $SfByNameAndParent[$ParentKey] = [System.Collections.Generic.List[object]]::new()
    }

    $SfByNameAndParent[$ParentKey].Add($SfAccount)
}

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
    $RawSegment = $AirtableRow.fields.'Market Segment'
    $AtSegment = $RawSegment

    if ($RawSegment -and $MarketSegmentMap.ContainsKey($RawSegment)) {
        $AtSegment = $MarketSegmentMap[$RawSegment]
    }

    $DesiredType = if ($AirtableRow.fields.'States + DC/PR') { "State" } else { "Federal" }

    $MatchedSfAccount = $null
    $MatchType = $null

    if ($SfByExternalId.ContainsKey($RecId)) {
        $MatchedSfAccount = $SfByExternalId[$RecId]
        $MatchType = "ExternalId"
    }
    else {
        $NormalizedName = Get-NormalizedName -Name $AtName
        $Candidates = $null

        if ($SfByName.ContainsKey($NormalizedName)) {
            $Candidates = $SfByName[$NormalizedName]
        }

        # Airtable's Parent is a plain-text agency name (not a linked record).
        $AtParent = @($AirtableRow.fields.Parent) | Select-Object -First 1
        $NormalizedParent = Get-NormalizedName -Name $AtParent

        if (-not $Candidates -or $Candidates.Count -eq 0) {
            # Before calling it unmatched: did an EARLIER Airtable row already
            # claim the Account this one would have matched? If so these two
            # Airtable rows describe the same office and one is a duplicate -
            # a materially different finding from "no such Account exists".
            $ClaimedHit = $null

            if ($NormalizedParent -and $SfByNameAndParent.ContainsKey($NormalizedName + "|" + $NormalizedParent)) {
                foreach ($Cand in $SfByNameAndParent[$NormalizedName + "|" + $NormalizedParent]) {
                    if ($ClaimedBy.ContainsKey($Cand.Id)) { $ClaimedHit = $Cand; break }
                }
            }

            if ($ClaimedHit) {
                $Winner = $ClaimedBy[$ClaimedHit.Id]
                $AmbiguousRows.Add([PSCustomObject]@{
                    AirtableRecordId       = $RecId
                    AirtableName           = $AtName
                    AirtableParent         = $AtParent
                    AirtableMarketSegment  = $AtSegment
                    AirtableDesiredType    = $DesiredType
                    CandidateSalesforceIds = $ClaimedHit.Id
                    Reason                 = "DUPLICATE AIRTABLE ROW. Salesforce Account $($ClaimedHit.Id) ('$($ClaimedHit.Name)' under '$($ClaimedHit.Parent.Name)') was already matched by Airtable row $($Winner.AirtableRecordId). Both rows describe the same office - merge them in Airtable."
                })
                continue
            }

            $UnmatchedRows.Add([PSCustomObject]@{
                AirtableRecordId      = $RecId
                AirtableName          = $AtName
                AirtableParent        = $AtParent
                AirtableMarketSegment = $AtSegment
                AirtableDesiredType   = $DesiredType
                Reason                 = "No existing Salesforce Account with this external ID or an exact Name match. Needs human review - do not auto-create."
            })
            continue
        }

        if ($Candidates.Count -gt 1) {
            # Narrow by parent agency. Only an EXACTLY-one result is a match;
            # zero or several leaves the row ambiguous, as before.
            $ParentMatches = @()

            if ($NormalizedParent) {
                $ParentMatches = @($Candidates | Where-Object {
                    (Get-NormalizedName -Name $_.Parent.Name) -eq $NormalizedParent
                })
            }

            if ($ParentMatches.Count -ne 1) {
                $SfParents = @($Candidates | ForEach-Object {
                    if ($_.Parent.Name) { $_.Parent.Name } else { "(no parent set)" }
                }) -join ", "

                $Why = if (-not $NormalizedParent) {
                    "Airtable names no Parent for this row, so there is nothing to disambiguate with."
                }
                elseif ($ParentMatches.Count -eq 0) {
                    "Airtable says the parent is '$AtParent', but no candidate sits under that agency (they sit under: $SfParents). Either the Salesforce Account for that agency's office does not exist, or Airtable's Parent is wrong."
                }
                else {
                    "$($ParentMatches.Count) candidates share BOTH this Name and the parent '$AtParent'."
                }

                $AmbiguousRows.Add([PSCustomObject]@{
                    AirtableRecordId       = $RecId
                    AirtableName           = $AtName
                    AirtableParent         = $AtParent
                    AirtableMarketSegment  = $AtSegment
                    AirtableDesiredType    = $DesiredType
                    CandidateSalesforceIds = ($Candidates | ForEach-Object { $_.Id }) -join "; "
                    Reason                 = "$($Candidates.Count) unclaimed Salesforce Accounts share this Name. $Why"
                })
                continue
            }

            $MatchedSfAccount = $ParentMatches[0]
            $MatchType = "NameAndParent"
        }
        else {
            $MatchedSfAccount = $Candidates[0]
            $MatchType = "Name"
        }

        # Claim it so a later duplicate-name row can't match it too. Removed by
        # identity, not by index - with parent matching the winner is not
        # necessarily the first candidate in the list.
        [void]$SfByName[$NormalizedName].Remove($MatchedSfAccount)
        $ClaimedBy[$MatchedSfAccount.Id] = [PSCustomObject]@{
            AirtableRecordId = $RecId
            AirtableName     = $AtName
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
