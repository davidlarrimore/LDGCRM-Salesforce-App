#Requires -Version 5.1

<#
    Second pass over Opportunity: populates LDGCRM_Partner_Account__c only.

    WHY THIS IS A SEPARATE SCRIPT, not part of Build-OpportunityLoad.ps1:
    the relationship isn't recorded on either the Opportunities table or the
    Partner Accounts table in any usable form - it's derived from the
    APPLICATIONS table, whose rows reference both an Opportunity and a Partner
    Account. So it needs a different source file and a different join than
    everything else in the Opportunity transform.

    Do NOT try to source this from Partner Accounts' "Opportunities" column.
    That column looks authoritative (961 links over 469 Opportunities) but is a
    roll-up of the parent ACCOUNT's opportunities - verified as an exact match
    to the parent Account's own Opportunity set for 72 of the 76 Partner
    Accounts that have it. The visible tell: all 8 Partner Accounts under the
    Department of Defense carry byte-identical 50-Opportunity lists, several of
    them named "(placeholder)". A rollup produces identical sets across
    unrelated records; a real relationship doesn't. Using it would assign an
    essentially arbitrary Partner Account to every Opportunity under a
    multi-Partner Account. See docs/TRANSFORMATION-RULES.md's Opportunity
    section.

    Mode: UPDATE-style upsert on LDGCRM_External_ID__c, writing only the
    external ID (as the match key) and the lookup. Opportunity is already
    loaded by Build-OpportunityLoad.ps1; this only fills in one field, so
    re-running it can't disturb anything else.

    Safe to re-run: coverage grows as more Applications, Opportunities and
    Partner Accounts land.
#>

param(
    [string]$OrgAlias = "gsa-peo",
    [string]$ApiVersion = "67.0"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-OpportunityPartnerAccountLink"

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " OPPORTUNITY -> PARTNER ACCOUNT LINK (second pass)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Derived from the Applications table - see this script's header for" -ForegroundColor Yellow
Write-Host "why the Partner Accounts 'Opportunities' column is NOT usable." -ForegroundColor Yellow
Write-Host ""

$AirtableApplications = Import-AirtableTable -Label "Applications"
Write-Host "$($AirtableApplications.Count) Airtable Application rows loaded."

# Build Opportunity -> set of Partner Accounts, from Applications that
# reference both. Collect the full set per Opportunity rather than taking the
# first match, so a genuine conflict is detected instead of silently resolved.
$OppToPartnerAccounts = @{}
foreach ($App in $AirtableApplications) {
    $RawOpp = $App.fields.'Opportunity Record ID'
    $RawPa = $App.fields.'Partner Account Record ID (from Partner Agreement)'
    if (-not $RawOpp -or -not $RawPa) { continue }

    $OppId = @($RawOpp)[0]
    $PaId = @($RawPa)[0]

    if (-not $OppToPartnerAccounts.ContainsKey($OppId)) {
        $OppToPartnerAccounts[$OppId] = [System.Collections.Generic.HashSet[string]]::new()
    }
    $OppToPartnerAccounts[$OppId].Add($PaId) | Out-Null
}
Write-Host "$($OppToPartnerAccounts.Count) Opportunities have a Partner Account recorded via an Application."

Write-Host ""
Write-Host "Querying $OrgAlias for loaded Opportunities and Partner Accounts..." -ForegroundColor Cyan

$LoadedOpportunities = @(Invoke-SalesforceQuery `
    -Soql "SELECT LDGCRM_External_ID__c FROM Opportunity WHERE LDGCRM_External_ID__c != null" `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
$LoadedOppIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($O in $LoadedOpportunities) { if ($O.LDGCRM_External_ID__c) { $LoadedOppIds.Add($O.LDGCRM_External_ID__c) | Out-Null } }

$LoadedPartnerAccounts = @(Invoke-SalesforceQuery `
    -Soql "SELECT LDGCRM_External_ID__c FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null" `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
$LoadedPaIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($P in $LoadedPartnerAccounts) { if ($P.LDGCRM_External_ID__c) { $LoadedPaIds.Add($P.LDGCRM_External_ID__c) | Out-Null } }

Write-Host "$($LoadedOppIds.Count) Opportunities and $($LoadedPaIds.Count) Partner Accounts present in $OrgAlias."

$UpdateRows = [System.Collections.Generic.List[object]]::new()
$ConflictRows = [System.Collections.Generic.List[object]]::new()
$PendingRows = [System.Collections.Generic.List[object]]::new()

foreach ($OppId in $OppToPartnerAccounts.Keys) {
    $PaSet = $OppToPartnerAccounts[$OppId]

    if ($PaSet.Count -gt 1) {
        # Two Applications on the same Opportunity naming different Partner
        # Accounts - a single Lookup can't hold both, so don't guess.
        $ConflictRows.Add([PSCustomObject]@{
            OpportunityAirtableId = $OppId
            PartnerAccountIds     = ($PaSet -join "; ")
            Reason                = "Applications on this Opportunity reference more than one Partner Account. A single Lookup can't represent that - needs a human decision on which is correct."
        })
        continue
    }

    $PaId = @($PaSet)[0]

    if (-not $LoadedOppIds.Contains($OppId)) {
        $PendingRows.Add([PSCustomObject]@{
            OpportunityAirtableId = $OppId
            PartnerAccountId      = $PaId
            Reason                = "Opportunity isn't loaded in $OrgAlias yet (skipped by Build-OpportunityLoad.ps1). Re-run once it loads."
        })
        continue
    }
    if (-not $LoadedPaIds.Contains($PaId)) {
        $PendingRows.Add([PSCustomObject]@{
            OpportunityAirtableId = $OppId
            PartnerAccountId      = $PaId
            Reason                = "Partner Account isn't loaded in $OrgAlias yet (its parent Account is likely unreconciled). Re-run once it loads."
        })
        continue
    }

    $UpdateRows.Add([PSCustomObject]([ordered]@{
        LDGCRM_External_ID__c                             = $OppId
        "LDGCRM_Partner_Account__r.LDGCRM_External_ID__c"  = $PaId
    }))
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpdateFile = Join-Path $LoadDir "Opportunity-partner-account-link-upsert.csv"
$ConflictFile = Join-Path $LogDir "Opportunity-partner-account-conflict-$Timestamp.csv"
$PendingFile = Join-Path $LogDir "Opportunity-partner-account-pending-$Timestamp.csv"

if ($UpdateRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $UpdateRows.ToArray() -Path $UpdateFile
}
if ($ConflictRows.Count -gt 0) {
    $ConflictRows | Export-Csv -LiteralPath $ConflictFile -NoTypeInformation -Encoding UTF8
}
if ($PendingRows.Count -gt 0) {
    $PendingRows | Export-Csv -LiteralPath $PendingFile -NoTypeInformation -Encoding UTF8
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " LINK PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-52} {1,8:N0}" -f "Opportunities with a Partner Account via Application", $OppToPartnerAccounts.Count)
Write-Host ("{0,-52} {1,8:N0}" -f "Ready to link", $UpdateRows.Count)
Write-Host ("{0,-52} {1,8:N0}" -f "Pending (one side not loaded yet)", $PendingRows.Count)
Write-Host ("{0,-52} {1,8:N0}" -f "Conflicting (2+ Partner Accounts)", $ConflictRows.Count)
Write-Host ""

if ($UpdateRows.Count -gt 0) {
    Write-Host "Link file (upsert on LDGCRM_External_ID__c, sets only the lookup):" -ForegroundColor Cyan
    Write-Host $UpdateFile
}
if ($PendingRows.Count -gt 0) {
    Write-Host "Pending links (re-run later):" -ForegroundColor Yellow
    Write-Host $PendingFile
}
if ($ConflictRows.Count -gt 0) {
    Write-Host "Conflicting links for human review:" -ForegroundColor Yellow
    Write-Host $ConflictFile
}

}
finally {
    Stop-ScriptLog
}
