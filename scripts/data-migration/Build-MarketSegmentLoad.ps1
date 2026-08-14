#Requires -Version 5.1

<#
    Market Segment - the FIRST chunk of the pipeline (see
    docs/engineering/ARCHITECTURE.md). An independent parent with no lookups, so
    this is a straight upsert-on-external-ID transform.

    WHY THIS EXISTS (built 2026-08-14). Market Segment used to be the one object
    the pipeline REQUIRED but refused to load: pre-flight hard-failed when the
    org had none, yet no transform ever created them, so the records had to
    appear by hand. That is backwards, and it produced a real defect the moment a
    second org entered the picture - QA had all five segments with the right
    names and NO external IDs, so Account reconciliation (which resolves a
    segment through LDGCRM_Market_Segment__r.LDGCRM_External_ID__c) matched
    nothing. Pre-flight passed, the load succeeded, and Market Segment would have
    been silently empty across the entire migration, cascading through the three
    before-save Flows to Opportunity, Application and Partner Account.

    ⚠️ THE EXTERNAL ID IS THE SEGMENT NAME, NOT THE AIRTABLE rec... ID.
    This is the ONE object that departs from the repo-wide convention, and the
    departure is deliberate and pre-existing - the five records already in Dev
    are keyed this way, and Build-AccountReconciliation.ps1 resolves a segment by
    matching Airtable's segment name against that external ID. Re-keying to
    rec... IDs would mean:
      - changing the reconciliation to map name -> rec id -> record, an extra hop
        that buys nothing for a fixed set of five human-meaningful values, and
      - orphaning the five external IDs already loaded in Dev.
    Confirmed as the intended design 2026-08-14. If it is ever revisited, the
    reconciliation's $MarketSegmentMap and this file must change together.

    Airtable's segment names are NOT the same strings as the Salesforce records
    in 3 of 5 cases ("Defense & National Security" vs "Defense"). That mapping
    lives in Build-AccountReconciliation.ps1, applied to the ACCOUNT's segment
    column. It is not applied here: this table's own Name column already holds
    the Salesforce-side spelling, verified against both orgs on 2026-08-14.

    Rows with no Name are skipped rather than loaded with a placeholder - two of
    the seven Airtable rows are blank, the same treatment Impediment gives its
    two nameless rows.

    Reads Salesforce only to resolve the fallback owner. Writes local CSVs only.
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (scripts/common/Common.Orgs.ps1).
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # Owner for every Market Segment, since Airtable records none against the
    # segment itself. Resolved to a User at run time and the run FAILS if it
    # doesn't match an active, record-owning User.
    [string]$FallbackOwnerEmail = "peter.marks@gsa.gov"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-MarketSegmentLoad"

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " MARKET SEGMENT LOAD PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Reads Salesforce (read-only) - writes local files only." -ForegroundColor Yellow
Write-Host ""

$AirtableSegments = Import-AirtableTable -Label "Market Segments"
Write-Host "$($AirtableSegments.Count) Airtable Market Segment rows loaded."

Write-Host ""
Write-Host "Resolving the fallback owner ($FallbackOwnerEmail)..." -ForegroundColor Cyan
$FallbackOwnerId = Resolve-FallbackOwnerId -Email $FallbackOwnerEmail -OrgAlias $OrgAlias -ApiVersion $ApiVersion
Write-Host "Fallback owner resolves to $FallbackOwnerId."

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()

foreach ($Row in $AirtableSegments) {
    $Name = "$($Row.fields.Name)".Trim()

    if (-not $Name) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $Row.id
            Name             = ""
            Reason           = "No Name. LDGCRM_Market_Segment__c's Name is required and the segment name is also its external ID, so a nameless row has nothing to key on. Looks like an empty placeholder row in Airtable."
        })
        continue
    }

    # Name is Text(80); every real segment is far shorter, but truncate rather
    # than fail the row if that ever stops being true.
    if ($Name.Length -gt 80) { $Name = $Name.Substring(0, 80) }

    $UpsertRows.Add([PSCustomObject]([ordered]@{
        LDGCRM_External_ID__c = $Name    # deliberately the NAME - see the header
        Name                  = $Name
        OwnerId               = $FallbackOwnerId
    }))
}

# ---------------------------------------------------------------------------
# Duplicate guard. The external ID is the name, so two rows sharing a name
# would upsert onto one record and silently lose one. LDGCRM_External_ID__c is
# unique=false on this object, so nothing downstream would catch it.
# ---------------------------------------------------------------------------
$Duplicates = @($UpsertRows | Group-Object LDGCRM_External_ID__c | Where-Object { $_.Count -gt 1 })
if ($Duplicates.Count -gt 0) {
    Write-Host ""
    Write-Host "  !! DUPLICATE SEGMENT NAMES IN AIRTABLE !!" -ForegroundColor Red
    $Duplicates | ForEach-Object { Write-Host ("     '{0}' appears {1} times" -f $_.Name, $_.Count) -ForegroundColor Red }
    throw ("Two or more Airtable Market Segments share a Name, which is this object's external ID - " +
           "they would collapse onto one Salesforce record. Fix the duplicate in Airtable and re-run.")
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "LDGCRM_Market_Segment__c-upsert.csv"
$SkippedFile = Join-Path $LogDir "MarketSegment-skipped-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile
}
if ($SkippedRows.Count -gt 0) {
    $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " MARKET SEGMENT PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-40} {1,8:N0}" -f "Airtable Market Segment rows", $AirtableSegments.Count)
Write-Host ("{0,-40} {1,8:N0}" -f "Ready for upsert", $UpsertRows.Count)
Write-Host ("{0,-40} {1,8:N0}" -f "Skipped (no Name)", $SkippedRows.Count)
Write-Host ""
Write-Host "Segments in the load:" -ForegroundColor Cyan
$UpsertRows | ForEach-Object { Write-Host ("   {0}" -f $_.Name) }
Write-Host ""

if ($UpsertRows.Count -gt 0) {
    Write-Host "Upsert file (external-ID keyed on the segment NAME):" -ForegroundColor Cyan
    Write-Host $UpsertFile
}
if ($SkippedRows.Count -gt 0) {
    Write-Host "Skipped rows for human review:" -ForegroundColor Yellow
    Write-Host $SkippedFile
}

}
finally {
    Stop-ScriptLog
}
