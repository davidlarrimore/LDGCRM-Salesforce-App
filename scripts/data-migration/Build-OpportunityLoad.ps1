#Requires -Version 5.1

<#
    Chunk 2 of the Airtable -> Salesforce data-migration pipeline (see
    docs/README.md). Full field-by-field investigation and every exclusion's
    reasoning live in docs/TRANSFORMATION-RULES.md's Opportunity section -
    this header covers only what a script reader needs at a glance.

    Opportunity is an independent parent (like Contact and Impediment), but
    unlike those it carries a real Account lookup, so it queries gsa-peo for
    the Accounts that actually exist and skips rows whose Account can't
    resolve - same preflight pattern as Build-ApplicationLoad.ps1, and for the
    same reason: an unresolvable lookup fails the entire row, not just the
    field.

    THREE required standard fields have to be present on every row:
      - Name       <- Opportunity Name (present on all rows)
      - StageName  <- Status (blank on 28 rows -> those rows are SKIPPED)
      - CloseDate  <- only 199 of 928 rows have a real go-live date, so this
                      falls back through Last Status Change Date, then the
                      record's Created date. Never invented - always a real
                      date from the record's own history. The fallback used
                      is recorded per row in the review CSV.

    Fields NOT written, deliberately:
      - LDGCRM_Market_Segment__c: the before-save Flow
        LDGCRM_Opportunity_Before_Save_Assign_Account_and_Market_Segment
        derives it from Account.LDGCRM_Market_Segment__r on create and on any
        AccountId change. Setting it here is redundant and would be overwritten.
      - LDGCRM_Status_Summary_Modified_Datetime__c: owned by a before-save Flow
        that stamps it whenever LDGCRM_Current_Status_Summary__c changes. Any
        value written here is stomped on the next update that touches the
        summary, so writing it produces an inconsistent, misleading timestamp.
      - LDGCRM_Days_Since_Last_Activity__c, LDGCRM_Est_Annual_Revenue_fully_ramped__c,
        LDGCRM_Est_First_Year_Revenue__c, LDGCRM_Status_Summary_Indicator__c:
        formula fields. Salesforce rejects direct writes outright. Note that
        the two revenue formulas are computed FROM the estimate fields this
        script does set, so Airtable's own revenue columns are not migrated -
        the values recompute themselves.
      - priority_type__c: Airtable's Priority Type values all exist at field
        level, but the Login_gov record type exposes only a single malformed
        concatenated value, so there is no valid target. Flagged for review
        rather than force-fitted onto LDGCRM_Level_of_Priority__c, which is a
        different concept (Low/Medium/High).
      - LDGCRM_Existing_Identity_Platforms__c / LDGCRM_Alternative_Identity_Platforms__c:
        the Airtable columns hold rec... IDs pointing at a table this migration
        doesn't pull, while the Salesforce fields are multipicklists of vendor
        names. Unresolvable without that table.
    LDGCRM_Partner_Account__c is set here, but is derived from the APPLICATIONS
    export rather than the Opportunities one - the Airtable Opportunities table
    has no Partner Account column at all. Do NOT source it from the Partner
    Accounts table's "Opportunities" column: that is a roll-up of the parent
    ACCOUNT's opportunities (verified exact-match for 72 of 76 Partner
    Accounts), not an authored link, so it cannot say which Partner Account an
    individual Opportunity belongs to. All 8 Partner Accounts under the
    Department of Defense carry byte-identical 50-Opportunity lists, several
    named "(placeholder)". See docs/TRANSFORMATION-RULES.md.

    This needs no separate pass: Partner Accounts load BEFORE Opportunity (see
    the load order in docs/README.md), so the lookup resolves during this same
    load, and the derivation only needs the local Applications JSON export, not
    Applications loaded into Salesforce. (Contrast Application's
    LDGCRM_Broker_App_Parent__c, which is genuinely a second pass because it is
    self-referential - its parents are in its own batch.)
#>

param(
    [string]$OrgAlias = "gsa-peo",
    [string]$ApiVersion = "67.0"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-OpportunityLoad"

# Airtable Focus Level carries the cadence in the label ("High (2 month
# update)"); the Salesforce picklist stores just the level. Map by leading
# token, same shape as Application's Ramp Up Approach rule.
$FocusLevelPattern = '^(Highest|High|Backlog|Developing)'

# Airtable literally stores "Gov?t Employees" with an ASCII question mark on
# 25 rows - confirmed NOT an export artifact (82 curly apostrophes survive
# intact elsewhere in the same JSON file), so the corruption is in Airtable
# itself. Salesforce's LDGCRM_Demographic_Served__c uses a straight ASCII
# apostrophe ("Gov't Employees"); the deprecated Demographic_Served__c field
# uses a CURLY one - do not confuse them, and do not reuse Application's
# Demographic map, which has "Gov't Employees (Contractors)" instead.
$DemographicMap = @{
    "General Population"              = "General Population"
    "Federal Employees"               = "Federal Employees"
    "Government Employees (Military)" = "Government Employees (Military)"
    "Veterans"                        = "Veterans"
    "Non-USC"                         = "Non-USC"
    "Gov?t Employees"                 = "Gov't Employees"
}

function ConvertTo-SalesforceRichText {
    <#
        LDGCRM_Current_Status_Summary__c, LDGCRM_Recent_Conversations__c and
        LDGCRM_Estimate_Rationale__c are Html (rich text) fields, not plain
        LongTextArea. Two consequences for plain-text Airtable content:
          1. Bare < > & are interpreted as markup. 7 Recent Conversations
             values contain <https://...> autolinks that would vanish
             entirely, and 63 values across the three fields contain a bare &.
             Escape them first.
          2. Newlines don't render. All 559 Recent Conversations values and
             119 Current Status Summary values are multi-line dated logs that
             would collapse into one unreadable paragraph, so newlines become
             <br> AFTER escaping (never before, or the tags get escaped too).
    #>
    param([string]$Value)

    if (-not $Value) { return "" }

    $Escaped = $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    $Escaped = $Escaped -replace "`r`n", "<br>"
    $Escaped = $Escaped -replace "`n", "<br>"
    $Escaped = $Escaped -replace "`r", "<br>"

    return $Escaped
}

function Resolve-OpportunityUrl {
    <#
        Same 255-char Url hard cap as every other object (platform limit, not
        adjustable). Airtable additionally wraps some URLs in angle brackets
        (Slack/markdown autolink style) and uses "N/A" as a placeholder, both
        of which have to come off before the value is a real URL.
    #>
    param(
        $Value,
        [string]$AirtableField,
        [string]$RecordId,
        [System.Collections.Generic.List[object]]$ReviewList
    )

    if (-not $Value) { return "" }

    $Clean = "$Value".Trim()
    $Clean = $Clean.Trim('<', '>').Trim()

    if (-not $Clean) { return "" }
    if ($Clean -match '^(N/?A|None|TBD)$') { return "" }
    if ($Clean -notmatch '^https?://') {
        $ReviewList.Add([PSCustomObject]@{
            AirtableRecordId = $RecordId
            Field            = $AirtableField
            OriginalValue    = $Value
            AppliedValue     = ""
            Reason           = "Not a URL - left blank rather than written into a Url-type field."
        })
        return ""
    }

    if ($Clean.Length -gt 255) {
        $ReviewList.Add([PSCustomObject]@{
            AirtableRecordId = $RecordId
            Field            = $AirtableField
            OriginalValue    = $Value
            AppliedValue     = ""
            Reason           = "URL exceeds Salesforce's 255-char hard limit for a Url-type field (not adjustable via metadata) - left blank rather than truncated, since a truncated URL wouldn't work. Needs human review."
        })
        return ""
    }

    return $Clean
}

function Get-DatePart {
    param($Value)
    if (-not $Value) { return "" }
    $S = "$Value"
    if ($S -match '^(\d{4}-\d{2}-\d{2})') {
        $Year = [int]$S.Substring(0, 4)
        if ($Year -ge 1900 -and $Year -le 2100) { return $Matches[1] }
    }
    return ""
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " OPPORTUNITY LOAD PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Reads Salesforce (read-only queries) - writes local files only." -ForegroundColor Yellow
Write-Host ""

Write-Host "Loading Airtable Opportunities export..." -ForegroundColor Cyan
$AirtableOpportunities = Import-AirtableTable -Label "Opportunities"
Write-Host "$($AirtableOpportunities.Count) Airtable Opportunity rows loaded."

# Opportunity has two active record types and the business process supplies no
# default StageName, so the record type must be set explicitly - unlike
# LDGCRM_application__c, which has only one and could rely on the default.
Write-Host ""
Write-Host "Looking up the Login_gov record type..." -ForegroundColor Cyan
$RecordTypeRows = @(Invoke-SalesforceQuery `
    -Soql "SELECT Id FROM RecordType WHERE SObjectType = 'Opportunity' AND DeveloperName = 'Login_gov'" `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

if ($RecordTypeRows.Count -ne 1) {
    throw "Expected exactly 1 Login_gov Opportunity record type, found $($RecordTypeRows.Count)."
}
$LoginGovRecordTypeId = $RecordTypeRows[0].Id
Write-Host "RecordTypeId: $LoginGovRecordTypeId"

Write-Host "Querying $OrgAlias for Accounts carrying an external ID..." -ForegroundColor Cyan
$LoadedAccounts = @(Invoke-SalesforceQuery `
    -Soql "SELECT LDGCRM_External_ID__c FROM Account WHERE LDGCRM_External_ID__c != null" `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

$LoadedAccountIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($Acct in $LoadedAccounts) {
    if ($Acct.LDGCRM_External_ID__c) { $LoadedAccountIds.Add($Acct.LDGCRM_External_ID__c) | Out-Null }
}
Write-Host "$($LoadedAccountIds.Count) reconciled Accounts present in $OrgAlias."

# --- Opportunity -> Partner Account, derived from the Applications export ---
# See the header for why this is derived from Applications and not from the
# Partner Accounts table's (rollup) "Opportunities" column. Collect the full
# SET per Opportunity rather than taking the first match, so a genuine
# disagreement between two Applications surfaces instead of being silently
# resolved to whichever row happened to come first.
Write-Host ""
Write-Host "Deriving Opportunity -> Partner Account links from the Applications export..." -ForegroundColor Cyan
$AirtableApplications = Import-AirtableTable -Label "Applications"

$OppToPartnerAccounts = @{}
foreach ($App in $AirtableApplications) {
    $RawAppOpp = $App.fields.'Opportunity Record ID'
    $RawAppPa = $App.fields.'Partner Account Record ID (from Partner Agreement)'
    if (-not $RawAppOpp -or -not $RawAppPa) { continue }

    $AppOppId = @($RawAppOpp)[0]
    if (-not $OppToPartnerAccounts.ContainsKey($AppOppId)) {
        $OppToPartnerAccounts[$AppOppId] = [System.Collections.Generic.HashSet[string]]::new()
    }
    $OppToPartnerAccounts[$AppOppId].Add(@($RawAppPa)[0]) | Out-Null
}
Write-Host "$($OppToPartnerAccounts.Count) Opportunities have a Partner Account recorded via an Application."

Write-Host "Querying $OrgAlias for loaded Partner Accounts..." -ForegroundColor Cyan
$LoadedPartnerAccounts = @(Invoke-SalesforceQuery `
    -Soql "SELECT LDGCRM_External_ID__c FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null" `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
$LoadedPartnerAccountIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($Pa in $LoadedPartnerAccounts) {
    if ($Pa.LDGCRM_External_ID__c) { $LoadedPartnerAccountIds.Add($Pa.LDGCRM_External_ID__c) | Out-Null }
}
Write-Host "$($LoadedPartnerAccountIds.Count) Partner Accounts present in $OrgAlias."

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()
$ValueReviewRows = [System.Collections.Generic.List[object]]::new()
$CloseDateFallbackRows = [System.Collections.Generic.List[object]]::new()
$DroppedDemographicCount = 0
$UnresolvedPartnerAccountCount = 0

foreach ($Row in $AirtableOpportunities) {
    $RecId = $Row.id
    $Name = $Row.fields.'Opportunity Name'

    # --- Required field 1: StageName ---
    $Status = $Row.fields.Status
    if (-not $Status) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            Name             = $Name
            Reason           = "No Status. StageName is a required Salesforce field with no default on the Login.gov business process - the row cannot load. Needs a Status in Airtable."
        })
        continue
    }

    # --- Account lookup: unresolvable means the whole row fails, so skip ---
    $RawAccountIds = $Row.fields.'Account Record ID'
    if (-not $RawAccountIds) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            Name             = $Name
            Reason           = "No linked Account in Airtable. Without one the Market Segment Flow can't populate either - needs an Account link in Airtable."
        })
        continue
    }
    $AccountId = @($RawAccountIds)[0]

    if (-not $LoadedAccountIds.Contains($AccountId)) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            Name             = $Name
            Reason           = "Linked Account $AccountId is not reconciled in $OrgAlias (duplicate/unmatched Airtable Account - see docs/AIRTABLE-DATA-QUALITY-REQUESTS.md). Would fail the load with INVALID_FIELD - skipped."
        })
        continue
    }

    # --- Required field 2: CloseDate, with a documented 3-step fallback ---
    $CloseDate = Get-DatePart $Row.fields.'Est. Go Live'
    $CloseDateSource = "Est. Go Live"
    if (-not $CloseDate) {
        $CloseDate = Get-DatePart $Row.fields.'(c) Last Status Change Date'
        $CloseDateSource = "(c) Last Status Change Date"
    }
    if (-not $CloseDate) {
        $CloseDate = Get-DatePart $Row.fields.Created
        $CloseDateSource = "Created"
    }
    if (-not $CloseDate) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            Name             = $Name
            Reason           = "No usable date for the required CloseDate field (Est. Go Live, Last Status Change Date and Created were all missing or unparseable)."
        })
        continue
    }
    if ($CloseDateSource -ne "Est. Go Live") {
        $CloseDateFallbackRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            Name             = $Name
            Status           = $Status
            CloseDateUsed    = $CloseDate
            SourceField      = $CloseDateSource
            Reason           = "No Est. Go Live date; CloseDate is required by Salesforce so it fell back to this field. Not a real forecast close date - re-run after a real go-live estimate is entered in Airtable."
        })
    }

    # --- Focus Level: leading token ---
    $FocusLevel = ""
    if ($Row.fields.'Focus Level') {
        if ("$($Row.fields.'Focus Level')" -match $FocusLevelPattern) { $FocusLevel = $Matches[1] }
        else {
            $ValueReviewRows.Add([PSCustomObject]@{
                AirtableRecordId = $RecId
                Field            = "Focus Level"
                OriginalValue    = $Row.fields.'Focus Level'
                AppliedValue     = ""
                Reason           = "Doesn't start with Highest/High/Backlog/Developing - left blank."
            })
        }
    }

    # --- Demographic Served: multi-value, semicolon-joined inside each element ---
    $DemographicTags = [System.Collections.Generic.List[string]]::new()
    foreach ($Element in @($Row.fields.'Demographic Served')) {
        if (-not $Element) { continue }
        foreach ($Part in ("$Element" -split ';')) {
            $Key = $Part.Trim()
            if (-not $Key) { continue }
            if ($DemographicMap.ContainsKey($Key)) {
                if (-not $DemographicTags.Contains($DemographicMap[$Key])) {
                    $DemographicTags.Add($DemographicMap[$Key])
                }
            }
            else {
                $DroppedDemographicCount++
                $ValueReviewRows.Add([PSCustomObject]@{
                    AirtableRecordId = $RecId
                    Field            = "Demographic Served"
                    OriginalValue    = $Key
                    AppliedValue     = ""
                    Reason           = "Not one of the 6 values allowed on Opportunity's LDGCRM_Demographic_Served__c - tag dropped."
                })
            }
        }
    }

    # --- Technical Readiness: 1-element array, exact-match picklist ---
    $TechnicalReadiness = ""
    if ($Row.fields.'Technical Readiness') {
        $TechnicalReadiness = @($Row.fields.'Technical Readiness')[0]
    }

    # --- Partner Account, derived from Applications (see header) ---
    $PartnerAccountId = ""
    if ($OppToPartnerAccounts.ContainsKey($RecId)) {
        $PaSet = $OppToPartnerAccounts[$RecId]
        if ($PaSet.Count -gt 1) {
            # Two Applications on the same Opportunity naming different Partner
            # Accounts. A single Lookup can't hold both - leave blank, flag it.
            $ValueReviewRows.Add([PSCustomObject]@{
                AirtableRecordId = $RecId
                Field            = "Partner Account (derived from Applications)"
                OriginalValue    = ($PaSet -join "; ")
                AppliedValue     = ""
                Reason           = "Applications on this Opportunity reference more than one Partner Account; a single Lookup can't represent that. Left blank - needs a human decision on which is correct."
            })
        }
        else {
            $CandidatePa = @($PaSet)[0]
            if ($LoadedPartnerAccountIds.Contains($CandidatePa)) {
                $PartnerAccountId = $CandidatePa
            }
            else {
                # Partner Account not loaded (its parent Account is likely
                # unreconciled). Blank rather than skip - the field is optional,
                # and re-running once it loads fills this in.
                $UnresolvedPartnerAccountCount++
            }
        }
    }

    # --- Est. First Year Ramp %: Airtable stores a 0-1 fraction; Salesforce
    # Percent fields take the raw 0-100 number over the API, and this one has
    # scale 0 so it must be a whole number. ---
    $FirstYearRamp = ""
    if ($null -ne $Row.fields.'Est. First Year Ramp %' -and $Row.fields.'Est. First Year Ramp %' -ne "") {
        $FirstYearRamp = [math]::Round([double]$Row.fields.'Est. First Year Ramp %' * 100, 0)
    }

    $OutputRow = [ordered]@{
        LDGCRM_External_ID__c                      = $RecId
        Name                                        = $Name
        RecordTypeId                                = $LoginGovRecordTypeId
        StageName                                   = $Status
        CloseDate                                   = $CloseDate
        "Account.LDGCRM_External_ID__c"             = $AccountId
        "LDGCRM_Partner_Account__r.LDGCRM_External_ID__c" = $PartnerAccountId
        LDGCRM_Opportunity_Type__c                  = $Row.fields.'Opportunity Type'
        LDGCRM_Focus_Level__c                       = $FocusLevel
        LDGCRM_Likely_Service_Level_Needed__c       = $Row.fields.'Likely Service Level Needed'
        LDGCRM_Technical_Readiness__c               = $TechnicalReadiness
        LDGCRM_Estimate_Source__c                   = $Row.fields.'Estimate source'
        LDGCRM_Demographic_Served__c                = ($DemographicTags -join ";")
        LDGCRM_Estimated_Go_Live_Date__c            = (Get-DatePart $Row.fields.'Est. Go Live')
        LDGCRM_Est_Annual_Idv_Users__c              = $Row.fields.'Est. Annual IdV Users (fully ramped)'
        LDGCRM_Est_Annual_Auth_Only_Users__c        = $Row.fields.'Est. Annual Auth-only Users (fully ramped)'
        LDGCRM_Est_Auth_Only_Avg_Active_Months__c   = $Row.fields.'Est. Auth-only Avg Active Months'
        LDGCRM_Est_First_Year_Ramp__c               = $FirstYearRamp
        LDGCRM_App_Description__c                   = $Row.fields.'App Description'
        LDGCRM_Current_Status_Summary__c            = (ConvertTo-SalesforceRichText $Row.fields.'Current Status Summary')
        LDGCRM_Recent_Conversations__c              = (ConvertTo-SalesforceRichText $Row.fields.'Recent Conversations')
        LDGCRM_Estimate_Rationale__c                = (ConvertTo-SalesforceRichText $Row.fields.'Estimate rationale')
        LDGCRM_Cost_Estimate_URL__c                 = (Resolve-OpportunityUrl -Value $Row.fields.'Cost Estimate URL' -AirtableField "Cost Estimate URL" -RecordId $RecId -ReviewList $ValueReviewRows)
        LDGCRM_Summary_URL__c                       = (Resolve-OpportunityUrl -Value $Row.fields.'Summary URL' -AirtableField "Summary URL" -RecordId $RecId -ReviewList $ValueReviewRows)
        LDGCRM_Sandbox_URL__c                       = (Resolve-OpportunityUrl -Value $Row.fields.'Sandbox URL' -AirtableField "Sandbox URL" -RecordId $RecId -ReviewList $ValueReviewRows)
    }

    $UpsertRows.Add([PSCustomObject]$OutputRow)
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "Opportunity-upsert.csv"
$SkippedFile = Join-Path $LogDir "Opportunity-skipped-$Timestamp.csv"
$ValueReviewFile = Join-Path $LogDir "Opportunity-value-review-$Timestamp.csv"
$CloseDateFile = Join-Path $LogDir "Opportunity-closedate-fallback-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile
}
if ($SkippedRows.Count -gt 0) {
    $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8
}
if ($ValueReviewRows.Count -gt 0) {
    $ValueReviewRows | Export-Csv -LiteralPath $ValueReviewFile -NoTypeInformation -Encoding UTF8
}
if ($CloseDateFallbackRows.Count -gt 0) {
    $CloseDateFallbackRows | Export-Csv -LiteralPath $CloseDateFile -NoTypeInformation -Encoding UTF8
}

$SkippedNoStatus = @($SkippedRows | Where-Object { $_.Reason -like "No Status*" }).Count
$SkippedNoAccount = @($SkippedRows | Where-Object { $_.Reason -like "No linked Account*" }).Count
$SkippedAccountUnreconciled = @($SkippedRows | Where-Object { $_.Reason -like "Linked Account*" }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " OPPORTUNITY PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-50} {1,8:N0}" -f "Airtable Opportunity rows", $AirtableOpportunities.Count)
Write-Host ("{0,-50} {1,8:N0}" -f "Ready for upsert", $UpsertRows.Count)
Write-Host ("{0,-50} {1,8:N0}" -f "Skipped - no Status (StageName required)", $SkippedNoStatus)
Write-Host ("{0,-50} {1,8:N0}" -f "Skipped - no Account link in Airtable", $SkippedNoAccount)
Write-Host ("{0,-50} {1,8:N0}" -f "Skipped - Account not reconciled in org", $SkippedAccountUnreconciled)
Write-Host ("{0,-50} {1,8:N0}" -f "Partner Account linked (via Applications)", @($UpsertRows | Where-Object { $_.'LDGCRM_Partner_Account__r.LDGCRM_External_ID__c' }).Count)
Write-Host ("{0,-50} {1,8:N0}" -f "Partner Account known but not loaded yet", $UnresolvedPartnerAccountCount)
Write-Host ("{0,-50} {1,8:N0}" -f "CloseDate came from a fallback field", $CloseDateFallbackRows.Count)
Write-Host ("{0,-50} {1,8:N0}" -f "Demographic tags dropped (unmapped)", $DroppedDemographicCount)
Write-Host ("{0,-50} {1,8:N0}" -f "Other values blanked for review", $ValueReviewRows.Count)
Write-Host ""

if ($UpsertRows.Count -gt 0) {
    Write-Host "Upsert file (external-ID keyed, requires Accounts reconciled first):" -ForegroundColor Cyan
    Write-Host $UpsertFile
}
if ($SkippedRows.Count -gt 0) {
    Write-Host "Skipped rows for human review:" -ForegroundColor Yellow
    Write-Host $SkippedFile
}
if ($CloseDateFallbackRows.Count -gt 0) {
    Write-Host "CloseDate fallback rows (not real forecast dates):" -ForegroundColor Yellow
    Write-Host $CloseDateFile
}
if ($ValueReviewRows.Count -gt 0) {
    Write-Host "Values blanked/dropped for human review:" -ForegroundColor Yellow
    Write-Host $ValueReviewFile
}

}
finally {
    Stop-ScriptLog
}
