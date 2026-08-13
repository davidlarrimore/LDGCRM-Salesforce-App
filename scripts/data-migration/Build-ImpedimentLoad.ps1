#Requires -Version 5.1

<#
    Chunk 2 of the Airtable -> Salesforce data-migration pipeline (see
    docs/README.md for the full pipeline). LDGCRM_Impediment__c
    is an independent parent - no lookups to other objects - so unlike Account
    this is a straight upsert-on-external-ID transform with no Salesforce query
    needed first.

    OwnerId is deliberately NOT set. Checked, not overlooked: the Airtable
    Impediments table has no owner/assignee column of any kind (its only
    non-content columns are Airtable-side rollups). Under the ownership rule
    agreed 2026-08-13, "no Airtable owner" means fall back to the loading user,
    which is what leaving OwnerId unset already does.

    Field notes (checked against the Airtable export and LDGCRM_Impediment__c's
    metadata before assuming a same-name mapping, per the "States + DC/PR" lesson
    on Account):
      - LDGCRM_Blocked_Revenue__c is a roll-up Summary field (sum of
        LDGCRM_Opportunity_Impediment__c.LDGCRM_Blocked_Revenue__c) - Salesforce
        computes it from the junction records and rejects direct writes to it, so
        it's intentionally excluded here. Airtable's "Blocked revenue"/"Requested
        revenue"/"Blocked Annual IdV users"/count columns have no Salesforce field
        at all and are Airtable-side rollups - not migrated.
      - LDGCRM_Category__c is a RESTRICTED picklist with exactly three values:
        "Product / Feature request", "Relationship issue", "Issue on partner end".
        Airtable's Category column uses different strings for two of the three
        ("Relationship Issue" - capital I; "Issue on their end" instead of "Issue
        on partner end") that a restricted picklist will reject outright, so this
        script maps them explicitly rather than passing the value through.
      - The object's Name field (LDGCRM_Impediment__c's `nameField`) is a plain
        required Text field, not autonumber - Airtable rows with no Name are
        skipped rather than loaded with a placeholder, same as any other
        confidently-unresolvable row in this pipeline.

    Does not touch the "Opportunities blocked" / "Opportunities requested" linked
    columns - those drive LDGCRM_Opportunity_Impediment__c (a later, junction
    chunk), not this object.

    Does not query Salesforce - this script only reads the Airtable export and
    writes a local CSV.
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-ImpedimentLoad"

# Airtable Category value -> LDGCRM_Impediment__c's restricted LDGCRM_Category__c
# picklist value. Keys are matched exactly (case-sensitive) against what's
# actually in the Airtable export, not guessed.
$CategoryMap = @{
    "Product / Feature request" = "Product / Feature request"
    "Relationship Issue"        = "Relationship issue"
    "Issue on their end"        = "Issue on partner end"
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " IMPEDIMENT LOAD PREP (Airtable -> Salesforce)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script does not query or write to Salesforce - local files only." -ForegroundColor Yellow
Write-Host ""

Write-Host "Loading Airtable Impediments export..." -ForegroundColor Cyan
$AirtableImpediments = Import-AirtableTable -Label "Impediments"
Write-Host "$($AirtableImpediments.Count) Airtable Impediment rows loaded."

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()
$UnmappedCategoryRows = [System.Collections.Generic.List[object]]::new()

foreach ($Row in $AirtableImpediments) {
    $RecId = $Row.id
    $Name = $Row.fields.Name
    $AtCategory = $Row.fields.Category

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            Reason           = "No Name - looks like an empty placeholder row in Airtable (no Name, Category, Description, Talking Point, or Opportunity links). Needs human review before loading."
        })
        continue
    }

    $MappedCategory = ""

    if (-not [string]::IsNullOrWhiteSpace($AtCategory)) {
        if ($CategoryMap.ContainsKey($AtCategory)) {
            $MappedCategory = $CategoryMap[$AtCategory]
        }
        else {
            $UnmappedCategoryRows.Add([PSCustomObject]@{
                AirtableRecordId = $RecId
                Name             = $Name
                AirtableCategory = $AtCategory
                Reason           = "Category value has no known mapping to LDGCRM_Category__c's restricted picklist. Row is still included in the upsert file with Category left blank - update `$CategoryMap in this script once the right mapping is known, then re-run."
            })
        }
    }

    $UpsertRows.Add([PSCustomObject]@{
        LDGCRM_External_ID__c   = $RecId
        Name                    = $Name
        LDGCRM_Category__c      = $MappedCategory
        LDGCRM_Description__c   = $Row.fields.Description
        LDGCRM_Talking_Point__c = $Row.fields.'Talking Point'
    })
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "LDGCRM_Impediment__c-upsert.csv"
$SkippedFile = Join-Path $LogDir "Impediment-skipped-$Timestamp.csv"
$UnmappedCategoryFile = Join-Path $LogDir "Impediment-unmapped-category-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile
}

if ($SkippedRows.Count -gt 0) {
    $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8
}

if ($UnmappedCategoryRows.Count -gt 0) {
    $UnmappedCategoryRows | Export-Csv -LiteralPath $UnmappedCategoryFile -NoTypeInformation -Encoding UTF8
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " IMPEDIMENT PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-40} {1,8:N0}" -f "Airtable Impediment rows", $AirtableImpediments.Count)
Write-Host ("{0,-40} {1,8:N0}" -f "Ready for upsert", $UpsertRows.Count)
Write-Host ("{0,-40} {1,8:N0}" -f "Skipped (no Name)", $SkippedRows.Count)
Write-Host ("{0,-40} {1,8:N0}" -f "Unmapped Category (included, blank)", $UnmappedCategoryRows.Count)
Write-Host ""

if ($UpsertRows.Count -gt 0) {
    Write-Host "Upsert file (external-ID keyed, LDGCRM_External_ID__c):" -ForegroundColor Cyan
    Write-Host $UpsertFile
}

if ($SkippedRows.Count -gt 0) {
    Write-Host "Skipped rows for human review:" -ForegroundColor Yellow
    Write-Host $SkippedFile
}

if ($UnmappedCategoryRows.Count -gt 0) {
    Write-Host "Unmapped Category rows for human review:" -ForegroundColor Yellow
    Write-Host $UnmappedCategoryFile
}

}
finally {
    Stop-ScriptLog
}
