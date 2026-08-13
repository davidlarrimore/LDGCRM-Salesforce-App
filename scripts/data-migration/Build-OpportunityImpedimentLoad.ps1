#Requires -Version 5.1

<#
    Chunk 3 of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md). Builds the LDGCRM_Opportunity_Impediment__c junction.
    Full reasoning lives in docs/engineering/TRANSFORMATION-RULES.md's Opportunity
    Impediment section.

    SOURCE: the Impediments table's two linked-record columns, which encode the
    severity in WHICH column an Opportunity appears in:
        "Opportunities blocked"   -> LDGCRM_Severity__c = "Blocker"
        "Opportunities requested" -> LDGCRM_Severity__c = "Impediment"

    BOTH parents are MASTER-DETAIL and therefore required - unlike the
    Application-Contact junction, where only Contact was required. A pair whose
    Opportunity or Impediment isn't loaded can't be created at all, so those are
    skipped rather than submitted.

    Composite external ID, same pattern and for the same reason as
    Build-ApplicationContactLoad.ps1: this object also has a before-save
    duplicate-check Flow, and an Opportunity can legitimately appear in BOTH
    source columns for the same Impediment (122 pairs do). Keying the upsert on
    "<impedimentExtId>|<opportunityExtId>" makes one-row-per-pair structural, so
    the conflict is resolved in the transform rather than becoming a load error.

    TWO DATA DECISIONS, both user-confirmed 2026-08-13:

    1. THE IMPEDIMENT NAMED "None" IS SKIPPED. It carries 263 blocked + 202
       requested links - 5x more than any real impediment (next highest is 86) -
       with an empty Description and Talking Point. It reads as a placeholder
       meaning "no impediment". Creating its 297 loadable junction rows would
       assert those Opportunities ARE impeded, i.e. the opposite of what the
       data means, and would inflate LDGCRM_Blocked_Revenue__c (a roll-up on the
       Impediment, populated by an after-save Flow) on a meaningless record.
       Skipped and flagged for the data owners rather than silently loaded.

    2. WHEN A PAIR APPEARS IN BOTH COLUMNS, "Blocker" WINS. It's the more severe
       value and the one that drives the Blocked Revenue roll-up, so recording
       the pair as blocked is the safer, more visible choice. Every such pair is
       written to a review CSV regardless.

    Fields NOT written, deliberately:
      - Name: the nameField is an AUTONUMBER.
      - LDGCRM_Blocked_Revenue__c: owned by the after-save Flow
        LGDCRM_Opportunity_Impediment_Before_Save_Update_Blocked_Revenue, which
        sets it from the parent Opportunity's estimated revenue when severity is
        "Blocker" and the Opportunity isn't Closed Won. Writing it here would be
        overwritten anyway, and it also feeds a roll-up on Impediment.
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (scripts/common/Common.Orgs.ps1).
    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # The Airtable Impediment Name treated as a placeholder rather than a real
    # impediment. Parameterised so a decision change doesn't need a code edit.
    [string]$PlaceholderImpedimentName = "None"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-OpportunityImpedimentLoad"

# Airtable column -> Salesforce severity. The column an Opportunity appears in
# IS the severity; there is no severity field in Airtable.
$SeverityByColumn = [ordered]@{
    "Opportunities blocked"   = "Blocker"
    "Opportunities requested" = "Impediment"
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " OPPORTUNITY-IMPEDIMENT JUNCTION PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Reads Salesforce (read-only queries) - writes local files only." -ForegroundColor Yellow
Write-Host ""

$AirtableImpediments = Import-AirtableTable -Label "Impediments"
Write-Host "$($AirtableImpediments.Count) Airtable Impediment rows loaded."

Write-Host ""
Write-Host "Querying $OrgAlias for loaded Impediments and Opportunities..." -ForegroundColor Cyan
$LoadedImpedimentIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT LDGCRM_External_ID__c FROM LDGCRM_Impediment__c WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) { $LoadedImpedimentIds.Add($Row.LDGCRM_External_ID__c) | Out-Null }
}
$LoadedOpportunityIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT LDGCRM_External_ID__c FROM Opportunity WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) { $LoadedOpportunityIds.Add($Row.LDGCRM_External_ID__c) | Out-Null }
}
Write-Host "$($LoadedImpedimentIds.Count) Impediments, $($LoadedOpportunityIds.Count) Opportunities present in $OrgAlias."

# --- Collect pairs, recording every severity each pair was seen with --------
$Pairs = @{}
$RawPairCount = 0
$PlaceholderPairCount = 0

foreach ($Impediment in $AirtableImpediments) {
    $IsPlaceholder = ("$($Impediment.fields.Name)".Trim() -eq $PlaceholderImpedimentName)

    foreach ($Column in $SeverityByColumn.Keys) {
        $RawOpportunities = $Impediment.fields.$Column
        if (-not $RawOpportunities) { continue }      # null-check before @()

        foreach ($OpportunityId in @($RawOpportunities)) {
            if (-not $OpportunityId) { continue }
            $RawPairCount++
            if ($IsPlaceholder) { $PlaceholderPairCount++; continue }

            $Key = "$($Impediment.id)|$OpportunityId"
            if (-not $Pairs.ContainsKey($Key)) {
                $Pairs[$Key] = [PSCustomObject]@{
                    ImpedimentExternalId  = $Impediment.id
                    ImpedimentName        = $Impediment.fields.Name
                    OpportunityExternalId = $OpportunityId
                    Severities            = [System.Collections.Generic.List[string]]::new()
                }
            }
            $Severity = $SeverityByColumn[$Column]
            if (-not $Pairs[$Key].Severities.Contains($Severity)) {
                $Pairs[$Key].Severities.Add($Severity)
            }
        }
    }
}

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()
$SeverityConflictRows = [System.Collections.Generic.List[object]]::new()

foreach ($Key in $Pairs.Keys) {
    $Pair = $Pairs[$Key]

    # "Blocker" wins when a pair appears in both columns - see the header.
    $Severity = if ($Pair.Severities.Contains("Blocker")) { "Blocker" } else { "Impediment" }

    if ($Pair.Severities.Count -gt 1) {
        $SeverityConflictRows.Add([PSCustomObject]@{
            ImpedimentName        = $Pair.ImpedimentName
            ImpedimentExternalId  = $Pair.ImpedimentExternalId
            OpportunityExternalId = $Pair.OpportunityExternalId
            SeveritiesFound       = ($Pair.Severities -join "; ")
            AppliedSeverity       = $Severity
            Reason                = "This Opportunity appears in BOTH 'Opportunities blocked' and 'Opportunities requested' for this Impediment. Severity is a single required value, so the more severe 'Blocker' was applied. Confirm which is correct."
        })
    }

    $ImpedimentLoaded = $LoadedImpedimentIds.Contains($Pair.ImpedimentExternalId)
    $OpportunityLoaded = $LoadedOpportunityIds.Contains($Pair.OpportunityExternalId)

    if (-not $ImpedimentLoaded -or -not $OpportunityLoaded) {
        $Missing = @()
        if (-not $ImpedimentLoaded) { $Missing += "Impediment $($Pair.ImpedimentExternalId)" }
        if (-not $OpportunityLoaded) { $Missing += "Opportunity $($Pair.OpportunityExternalId)" }
        $SkippedRows.Add([PSCustomObject]@{
            ImpedimentName        = $Pair.ImpedimentName
            ImpedimentExternalId  = $Pair.ImpedimentExternalId
            OpportunityExternalId = $Pair.OpportunityExternalId
            NotLoaded             = ($Missing -join "; ")
            Reason                = "BOTH parents are Master-Detail and required; the missing one was withheld by its own load (usually the unreconciled-Account data-quality issue). Re-run once it loads - no code change needed."
        })
        continue
    }

    $UpsertRows.Add([PSCustomObject]([ordered]@{
        LDGCRM_External_ID__c                            = $Key
        "LDGCRM_Impediment__r.LDGCRM_External_ID__c"     = $Pair.ImpedimentExternalId
        "LDGCRM_Opportunity__r.LDGCRM_External_ID__c"    = $Pair.OpportunityExternalId
        LDGCRM_Severity__c                               = $Severity
    }))
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "LDGCRM_Opportunity_Impediment__c-upsert.csv"
$SkippedFile = Join-Path $LogDir "OpportunityImpediment-skipped-$Timestamp.csv"
$ConflictFile = Join-Path $LogDir "OpportunityImpediment-severity-conflict-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile }
if ($SkippedRows.Count -gt 0) { $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8 }
if ($SeverityConflictRows.Count -gt 0) { $SeverityConflictRows | Export-Csv -LiteralPath $ConflictFile -NoTypeInformation -Encoding UTF8 }

$BlockerCount = @($UpsertRows | Where-Object { $_.LDGCRM_Severity__c -eq "Blocker" }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " OPPORTUNITY-IMPEDIMENT PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-56} {1,8:N0}" -f "Raw (Impediment, Opportunity) links", $RawPairCount)
Write-Host ("{0,-56} {1,8:N0}" -f "  dropped - '$PlaceholderImpedimentName' placeholder Impediment", $PlaceholderPairCount)
Write-Host ("{0,-56} {1,8:N0}" -f "Distinct pairs from real Impediments", $Pairs.Count)
Write-Host ("{0,-56} {1,8:N0}" -f "Ready for upsert (both parents loaded)", $UpsertRows.Count)
Write-Host ("{0,-56} {1,8:N0}" -f "  ...severity Blocker", $BlockerCount)
Write-Host ("{0,-56} {1,8:N0}" -f "  ...severity Impediment", ($UpsertRows.Count - $BlockerCount))
Write-Host ("{0,-56} {1,8:N0}" -f "Skipped (a Master-Detail parent isn't loaded)", $SkippedRows.Count)
Write-Host ("{0,-56} {1,8:N0}" -f "Severity conflicts resolved to Blocker", $SeverityConflictRows.Count)
Write-Host ""

if ($UpsertRows.Count -gt 0) {
    Write-Host "Upsert file (composite external ID = <impediment>|<opportunity>):" -ForegroundColor Cyan
    Write-Host $UpsertFile
}
if ($SkippedRows.Count -gt 0) {
    Write-Host "Skipped pairs (re-run after the missing parent loads):" -ForegroundColor Yellow
    Write-Host $SkippedFile
}
if ($SeverityConflictRows.Count -gt 0) {
    Write-Host "Severity conflicts for human review:" -ForegroundColor Yellow
    Write-Host $ConflictFile
}

}
finally {
    Stop-ScriptLog
}
