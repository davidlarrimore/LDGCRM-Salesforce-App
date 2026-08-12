#Requires -Version 5.1

<#
    Chunk 1 of the Airtable -> Salesforce data-migration pipeline (see
    scripts/data-migration/README.md for the full pipeline).

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
    [string]$OrgAlias = "gsa-peo",
    [string]$ApiVersion = "67.0"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-AccountReconciliation"

function Get-NormalizedName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    return $Name.Trim().ToLowerInvariant()
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ACCOUNT RECONCILIATION (Airtable -> gsa-peo)" -ForegroundColor Cyan
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
$Soql = "SELECT Id, Name, Type, LDGCRM_External_ID__c, LDGCRM_Market_Segment__r.LDGCRM_External_ID__c FROM Account"
$SalesforceAccounts = Invoke-SalesforceQuery -Soql $Soql -OrgAlias $OrgAlias -ApiVersion $ApiVersion
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
}

# ============================================================
# RECONCILE
# ============================================================

$UpdateRows = [System.Collections.Generic.List[object]]::new()
$UnmatchedRows = [System.Collections.Generic.List[object]]::new()
$AmbiguousRows = [System.Collections.Generic.List[object]]::new()
$AlreadyCurrentCount = 0

foreach ($AirtableRow in $AirtableAccounts) {
    $RecId = $AirtableRow.id
    $AtName = $AirtableRow.fields.Name
    $AtSegment = $AirtableRow.fields.'Market Segment'
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

        if (-not $Candidates -or $Candidates.Count -eq 0) {
            $UnmatchedRows.Add([PSCustomObject]@{
                AirtableRecordId      = $RecId
                AirtableName          = $AtName
                AirtableMarketSegment = $AtSegment
                AirtableDesiredType   = $DesiredType
                Reason                 = "No existing Salesforce Account with this external ID or an exact Name match. Needs human review - do not auto-create."
            })
            continue
        }

        if ($Candidates.Count -gt 1) {
            $AmbiguousRows.Add([PSCustomObject]@{
                AirtableRecordId       = $RecId
                AirtableName           = $AtName
                AirtableMarketSegment  = $AtSegment
                AirtableDesiredType    = $DesiredType
                CandidateSalesforceIds = ($Candidates | ForEach-Object { $_.Id }) -join "; "
                Reason                  = "Multiple unclaimed Salesforce Accounts share this Name. Needs human review to pick the right one."
            })
            continue
        }

        $MatchedSfAccount = $Candidates[0]
        $MatchType = "Name"

        # Claim it so a later duplicate-name row can't match it too.
        $SfByName[$NormalizedName].RemoveAt(0)
    }

    $CurrentSegmentExternalId = $MatchedSfAccount.LDGCRM_Market_Segment__r.LDGCRM_External_ID__c

    $NeedsExternalIdUpdate = ($MatchType -eq "Name")
    $NeedsSegmentUpdate = ($AtSegment -and ($CurrentSegmentExternalId -ne $AtSegment))
    $NeedsTypeUpdate = ($MatchedSfAccount.Type -ne $DesiredType)

    if (-not $NeedsExternalIdUpdate -and -not $NeedsSegmentUpdate -and -not $NeedsTypeUpdate) {
        $AlreadyCurrentCount++
        continue
    }

    $UpdateRows.Add([PSCustomObject]@{
        Id                       = $MatchedSfAccount.Id
        LDGCRM_External_ID__c    = $RecId
        LDGCRM_Market_Segment__c = $AtSegment
        Type                     = $DesiredType
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
Write-Host ("{0,-45} {1,8:N0}" -f "Unmatched (no candidate Account)", $UnmatchedRows.Count)
Write-Host ("{0,-45} {1,8:N0}" -f "Ambiguous (multiple candidate Accounts)", $AmbiguousRows.Count)
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
