#Requires -Version 5.1

<#
    Chunk 3 of the Airtable -> Salesforce data-migration pipeline (see
    docs/README.md). Full field-by-field investigation,
    every exclusion's reasoning, and the Demographic Served picklist expansion
    (deployed separately via sfdx-metadata-sync before this script was written)
    live in docs/TRANSFORMATION-RULES.md's Application section - this header only
    covers what a script reader needs at a glance, not the full justification.

    LDGCRM_Partner_Account__c is a REQUIRED Lookup - needs Partner Account
    loaded first, or every row's parent lookup fails to resolve. LDGCRM_Opportunity__c
    is optional and needs Opportunity loaded (not built yet) to resolve; rows
    load fine without it, that lookup just stays blank until Opportunity exists.

    Does not query Salesforce - purely an offline Airtable JSON -> CSV
    transform, like Impediment (no User-resolution or reconciliation needed
    here, unlike Account/Partner Account).

    Fields NOT written, deliberately (see docs/TRANSFORMATION-RULES.md for why each
    one specifically):
      - LDGCRM_Market_Segment__c: before-save Flow derives it from the linked
        Partner Account's Account.
      - LDGCRM_Launch_Checklist_Completion__c, LDGCRM_Level_1_Complete_Pct__c,
        LDGCRM_Level_3_Complete_Pct__c, LDGCRM_Level_4_Complete_Pct__c,
        LDGCRM_Opportunity_Lead__c, LDGCRM_Opportunity_Stage__c: all six are
        formula fields despite declaring normal-looking types (Percent/Text) -
        Salesforce rejects direct writes to them outright. They compute
        themselves from fields this script does set (checkboxes, URLs, the
        Opportunity lookup).
      - LDGCRM_Annual_Revenue_Amount__c, LDGCRM_P3_Partner_Portal_Team_Name__c,
        LDGCRM_P3_Team_UUID__c, LDGCRM_PP_Issuer_Strings__c: no Airtable source
        found (Issuer Strings links to a table this migration doesn't pull;
        user-confirmed not migrated).
      - LDGCRM_Broker_App_Parent__c: a self-Lookup (Application -> Application).
        Deliberately NOT written by this script - a first real load attempt
        (2026-08-12) confirmed Bulk API 2.0 does not resolve external-ID
        references between two rows in the same upsert batch, so every
        Broker App Parent reference failed with "foreign key external ID not
        found" even though the parent Application was in the very same CSV.
        Needs a second-pass script/run once every Application row already
        exists in gsa-peo (see docs/README.md).

    Rows with no linked Partner Account are skipped (required field) and
    written to a review CSV, same pattern as every other required-lookup
    check in this pipeline. Rows whose linked Partner Account exists in
    Airtable but hasn't actually loaded into gsa-peo are skipped the same
    way - see the preflight query below.
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (scripts/common/Common.Orgs.ps1).
    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-ApplicationLoad"

# Airtable Status value -> LDGCRM_Status__c. Only one of the eight distinct
# values in use needs remapping (a misspelling); everything else passes
# through unchanged.
$StatusMap = @{
    "Decomissioned" = "Decommissioned"
}

# Airtable Launch Level is a bare number; LDGCRM_Launch_Level__c needs the
# full label.
$LaunchLevelMap = @{
    "1" = "1 - Very Low Impact"
    "2" = "2 - Low Impact"
    "3" = "3 - Moderate Impact"
    "4" = "4 - High Impact"
    "5" = "5 - Very High Impact"
}

# The 24 Demographic Served categories used within the last 18 months
# (2026-08-12 analysis - see docs/TRANSFORMATION-RULES.md), mapped to their
# LDGCRM_Demographic_Served__c value. Every value maps to itself except
# "Contractors", which reuses the picklist's pre-existing "Gov't Employees
# (Contractors)" value rather than adding a near-duplicate. Any Airtable
# category NOT in this map (the 8 categories unused in 18+ months) is
# deliberately dropped for that row, not an error - counted in the summary,
# not written to a review CSV, since this was a deliberate scope decision,
# not a data-quality gap.
$DemographicServedMap = @{
    "Federal Employees"                      = "Federal Employees"
    "General Population"                     = "General Population"
    "Government Employees (Military)"        = "Government Employees (Military)"
    "Veterans"                                = "Veterans"
    "Contractors"                             = "Gov't Employees (Contractors)"
    "Agency Staff"                            = "Agency Staff"
    "State & Local Employees"                 = "State & Local Employees"
    "Grantees"                                = "Grantees"
    "Banking Organization"                    = "Banking Organization"
    "Employers"                               = "Employers"
    "Educators"                               = "Educators"
    "Agency Customers"                        = "Agency Customers"
    "Students"                                = "Students"
    "Grantors"                                = "Grantors"
    "Authorized Personnel"                    = "Authorized Personnel"
    "Tribal Nations"                          = "Tribal Nations"
    "Retirees - Former Government Employees"  = "Retirees - Former Government Employees"
    "Other Organizations"                     = "Other Organizations"
    "Law Enforcement"                         = "Law Enforcement"
    "Annuitants"                              = "Annuitants"
    "Young Adults"                            = "Young Adults"
    "Former Federal Employees"                = "Former Federal Employees"
    "Minors 13-18"                            = "Minors 13-18"
    "Credit Unions"                           = "Credit Unions"
}

# Simple presence-based Checkbox fields: Airtable omits the field entirely
# when unchecked, so "has a value" (including an array with entries, or any
# non-empty string) means true.
$PresenceBooleanFields = @(
    @{ Airtable = "Account Manager Approved"; Sf = "LDGCRM_Account_Manager_Approved__c" }
    @{ Airtable = "Agreement Finalization Email Sent"; Sf = "LDGCRM_Agreement_Finalization_Email_Sent__c" }
    @{ Airtable = "Customer Support Meeting Deemed Unnecessary"; Sf = "LDGCRM_No_Customer_Support_Meeting__c" }
    @{ Airtable = "Finalized Application Details"; Sf = "LDGCRM_Finalized_Application_Details__c" }
    @{ Airtable = "Fraud Meeting Deemed Unnecessary"; Sf = "LDGCRM_No_Fraud_Meeting__c" }
    @{ Airtable = "IdV Upgrade?"; Sf = "LDGCRM_IDV_Upgrade__c" }
    @{ Airtable = "Confirmed pre-launch or launch day activities"; Sf = "LDGCRM_Launch_Activities_Confirmed__c" }
    @{ Airtable = "Launch Day Activities Completed"; Sf = "LDGCRM_Launch_Activities_Completed__c" }
    @{ Airtable = "Launch Coordinators Kick-off Call"; Sf = "LDGCRM_Launch_Coordinators_Kickoff_Call__c" }
    @{ Airtable = "Launch Kick-off Meeting Unnecessary"; Sf = "LDGCRM_No_Launch_Kickoff_Meeting__c" }
    @{ Airtable = "Launch Tested"; Sf = "LDGCRM_Launch_Tested__c" }
    @{ Airtable = "Launch to Production Completed by OE"; Sf = "LDGCRM_Production_Launch_Completed__c" }
    @{ Airtable = "Marketing/Comms Strategy"; Sf = "LDGCRM_Marketing_Strategy__c" }
    @{ Airtable = "Requested Contact Center Reporting"; Sf = "LDGCRM_Requested_CC_Reporting__c" }
    @{ Airtable = "Security Meeting Deemed Unnecessary"; Sf = "LDGCRM_No_Security_Meeting__c" }
    @{ Airtable = "Coordinated Optional Follow-up Tech Sync"; Sf = "LDGCRM_Followup_Tech_Sync_Scheduled__c" }
    @{ Airtable = "UX Meeting Deemed Unnecessary"; Sf = "LDGCRM_No_UX_Meeting__c" }
    # "Meeting held" fields: the Airtable column links to the not-yet-migrated
    # Meetings table (or, for Security Meeting, holds freeform meeting-name
    # text) - deliberately not resolving which meeting, just true/false on
    # whether any value is present (user-confirmed).
    @{ Airtable = "Customer Support Meeting"; Sf = "LDGCRM_Customer_Support_Meeting__c" }
    @{ Airtable = "Fraud Meeting"; Sf = "LDGCRM_Fraud_Meeting_Held__c" }
    @{ Airtable = "Launch Kick-off Meeting"; Sf = "LDGCRM_Launch_Kickoff_Meeting_Held__c" }
    @{ Airtable = "UX Meeting"; Sf = "LDGCRM_UX_Meeting_Held__c" }
    @{ Airtable = "Security Meeting"; Sf = "LDGCRM_Security_Meeting__c" }
    # Presence of any value (not a literal boolean) - only ever blank or
    # "At Risk" in the data.
    @{ Airtable = "Launch Risk"; Sf = "LDGCRM_Launch_Risk__c" }
)

function Get-PresenceBool {
    param($Value)
    if ($Value) { return "true" }
    return "false"
}

# Every Url-type field on this object. Salesforce hard-caps Url fields at 255
# characters and there is no <length> override for the type, so an over-length
# value can only be dropped, not truncated (a cut-off URL is a broken URL).
# The first load pass only checked LDGCRM_URL__c and was then failed by a
# single over-length Launch Deck URL - hence the table: check every Url field,
# not just the one that happened to be obviously long.
$UrlFieldMap = @(
    @{ Airtable = "URL"; Sf = "LDGCRM_URL__c" }
    @{ Airtable = "Completed Customer Support Survey"; Sf = "LDGCRM_Completed_Customer_Support_Survey__c" }
    @{ Airtable = "Completed Fraud Survey"; Sf = "LDGCRM_Completed_Fraud_Survey__c" }
    @{ Airtable = "Completed Security Survey"; Sf = "LDGCRM_Completed_Security_Survey_URL__c" }
    @{ Airtable = "Launch Checklist URL"; Sf = "LDGCRM_Launch_Checklist_URL__c" }
    @{ Airtable = "Launch Deck URL"; Sf = "LDGCRM_Launch_Deck_URL__c" }
)

function Resolve-UrlValue {
    <#
        Applies the shared Url-field rules: strip "TBD" placeholders, and drop
        anything past Salesforce's 255-char Url cap (recording it for review
        rather than silently losing it).
    #>
    param(
        $Value,
        [string]$AirtableField,
        [string]$RecordId,
        [System.Collections.Generic.List[object]]$ReviewList
    )

    if (-not $Value) { return "" }
    if ($Value -match '^TBD') { return "" }

    if ($Value.Length -gt 255) {
        $ReviewList.Add([PSCustomObject]@{
            AirtableRecordId = $RecordId
            Field            = $AirtableField
            OriginalValue    = $Value
            AppliedValue     = ""
            Reason           = "URL exceeds Salesforce's 255-char hard limit for a Url-type field (not adjustable via metadata) - left blank rather than truncated, since a truncated URL wouldn't work. Needs human review."
        })
        return ""
    }

    return $Value
}

function Resolve-DateValue {
    <#
        Airtable dates arrive as YYYY-MM-DD, which matches what Bulk API wants,
        but the format being right doesn't make the value sane: one row carries
        "0202-02-18" (a mistyped 2022) that failed the load with
        FIELD_INTEGRITY_EXCEPTION. Range-check the year rather than trusting
        the format - same lesson as checking a picklist's values instead of
        just its type.
    #>
    param(
        $Value,
        [string]$AirtableField,
        [string]$RecordId,
        [System.Collections.Generic.List[object]]$ReviewList
    )

    if (-not $Value) { return "" }

    if ($Value -match '^(\d{4})-\d{2}-\d{2}$') {
        $Year = [int]$Matches[1]
        if ($Year -ge 1900 -and $Year -le 2100) { return $Value }
    }

    $ReviewList.Add([PSCustomObject]@{
        AirtableRecordId = $RecordId
        Field            = $AirtableField
        OriginalValue    = $Value
        AppliedValue     = ""
        Reason           = "Not a plausible date (expected YYYY-MM-DD with a year between 1900 and 2100) - Salesforce rejects it outright. Left blank; needs a corrected value in Airtable."
    })
    return ""
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " APPLICATION LOAD PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Reads Salesforce (one read-only query) - writes local files only." -ForegroundColor Yellow
Write-Host ""

Write-Host "Loading Airtable Applications export..." -ForegroundColor Cyan
$AirtableApplications = Import-AirtableTable -Label "Applications"
Write-Host "$($AirtableApplications.Count) Airtable Application rows loaded."

# LDGCRM_Partner_Account__c is a REQUIRED lookup resolved by external ID at
# load time. A row referencing a Partner Account that exists in Airtable but
# never made it into gsa-peo (its own parent Account is unresolved - see
# docs/AIRTABLE-DATA-QUALITY-REQUESTS.md) is a guaranteed Bulk API failure,
# not a maybe. The 2026-08-13 load submitted 343 such rows and got 343
# INVALID_FIELD errors back. Checking up front turns those into an explicit,
# reviewable skip list instead of load-time noise that buries real failures.
Write-Host ""
Write-Host "Querying $OrgAlias for Partner Accounts that actually exist..." -ForegroundColor Cyan
# The same query also carries the Partner Account's owner, which becomes the
# Application's OwnerId (decided 2026-08-13). Airtable has no Application-level
# owner: its "Account Owner" column is a ROLLUP from the parent Account, so
# using it would assert the agency's account owner personally owns each
# application. The Partner Account's own owner is the nearest authored value,
# and every Application has a required Partner Account, so coverage is total
# wherever the Partner Account itself has an owner.
#
# IsActive is pulled through the relationship because Salesforce rejects an
# INACTIVE user as an OwnerId - and this field was populated by an earlier
# version of Build-PartnerAccountLoad.ps1 that did not filter on IsActive, so
# stale inactive owners can genuinely be sitting in it.
$LoadedPartnerAccounts = @(Invoke-SalesforceQuery `
    -Soql ("SELECT LDGCRM_External_ID__c, LDGCRM_Partner_Account_Owner__c, " +
           "LDGCRM_Partner_Account_Owner__r.IsActive " +
           "FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null") `
    -OrgAlias $OrgAlias)

$LoadedPartnerAccountIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$PartnerAccountOwnerById = @{}
foreach ($Pa in $LoadedPartnerAccounts) {
    if ($Pa.LDGCRM_External_ID__c) {
        $LoadedPartnerAccountIds.Add($Pa.LDGCRM_External_ID__c) | Out-Null

        if ($Pa.LDGCRM_Partner_Account_Owner__c -and $Pa.LDGCRM_Partner_Account_Owner__r.IsActive) {
            $PartnerAccountOwnerById[$Pa.LDGCRM_External_ID__c] = $Pa.LDGCRM_Partner_Account_Owner__c
        }
    }
}
Write-Host "$($LoadedPartnerAccountIds.Count) Partner Accounts present in $OrgAlias."
Write-Host "$($PartnerAccountOwnerById.Count) of them carry an active owner to pass down to Applications."

# Same problem, different severity, for the OPTIONAL Opportunity lookup.
# "Optional" means the column may be blank - it does NOT mean it may point at
# a record that doesn't exist: Bulk API rejects the whole row either way (99
# rows failed this way on 2026-08-13, before Opportunity was built at all).
# Since the field genuinely is optional, an unresolvable reference is blanked
# and the row still loads, rather than being skipped like a missing required
# Partner Account. Re-running this script after Opportunity loads picks the
# real links up.
Write-Host "Querying $OrgAlias for Opportunities that actually exist..." -ForegroundColor Cyan
$LoadedOpportunities = @(Invoke-SalesforceQuery `
    -Soql "SELECT LDGCRM_External_ID__c FROM Opportunity WHERE LDGCRM_External_ID__c != null" `
    -OrgAlias $OrgAlias)

$LoadedOpportunityIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($Opp in $LoadedOpportunities) {
    if ($Opp.LDGCRM_External_ID__c) {
        $LoadedOpportunityIds.Add($Opp.LDGCRM_External_ID__c) | Out-Null
    }
}
Write-Host "$($LoadedOpportunityIds.Count) Opportunities present in $OrgAlias."

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()
$OverLengthRows = [System.Collections.Generic.List[object]]::new()
$UnmappedRampUpRows = [System.Collections.Generic.List[object]]::new()
$DroppedDemographicTagCount = 0
$UnresolvedOpportunityCount = 0

foreach ($Row in $AirtableApplications) {
    $RecId = $Row.id
    $Name = $Row.fields.Name

    # Name is the object's nameField (Text type) - Salesforce hard-caps
    # custom-object Name fields at 80 characters, unlike a normal custom
    # Text field. Not adjustable via metadata (no <length> override exists
    # for nameField), unlike the TextArea-length fixes elsewhere in this
    # migration. Truncate and flag for human review rather than fail the row.
    if ($Name -and $Name.Length -gt 80) {
        $OverLengthRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            Field            = "Name"
            OriginalValue    = $Name
            AppliedValue     = $Name.Substring(0, 80)
            Reason           = "Application Name exceeds Salesforce's 80-char hard limit for a custom object's Name field (not adjustable via metadata) - truncated to 80 chars. Needs human review to confirm the truncation still identifies the record."
        })
        $Name = $Name.Substring(0, 80)
    }

    $RawPartnerAccountIds = $Row.fields.'Partner Account Record ID (from Partner Agreement)'

    # Same @($null)-is-a-1-element-array gotcha as Build-PartnerAccountLoad.ps1
    # - null-check before wrapping in @().
    if (-not $RawPartnerAccountIds) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            Name             = $Name
            Reason           = "No linked Partner Account. LDGCRM_Partner_Account__c is a required Lookup - needs human review."
        })
        continue
    }
    $PartnerAccountId = @($RawPartnerAccountIds)[0]

    if (-not $LoadedPartnerAccountIds.Contains($PartnerAccountId)) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $RecId
            Name             = $Name
            Reason           = "Linked Partner Account $PartnerAccountId is not loaded in $OrgAlias (its own parent Account is unresolved - see docs/AIRTABLE-DATA-QUALITY-REQUESTS.md). Would fail the load with INVALID_FIELD - skipped. Re-run once the Account/Partner Account data is fixed."
        })
        continue
    }

    $OpportunityId = ""
    if ($Row.fields.'Opportunity Record ID') {
        $CandidateOpportunityId = @($Row.fields.'Opportunity Record ID')[0]
        if ($LoadedOpportunityIds.Contains($CandidateOpportunityId)) {
            $OpportunityId = $CandidateOpportunityId
        }
        else {
            # Optional field - blank it and keep the row loadable (see the
            # preflight comment above); count it so the summary shows how
            # much linkage is still pending an Opportunity load.
            $UnresolvedOpportunityCount++
        }
    }

    $Status = $Row.fields.Status
    if ($Status -and $StatusMap.ContainsKey($Status)) {
        $Status = $StatusMap[$Status]
    }

    $RampUpApproach = ""
    $RawRampUp = $Row.fields.'Ramp Up Approach'
    if ($RawRampUp) {
        $RawRampUpValue = @($RawRampUp)[0].Trim()
        if ($RawRampUpValue -match '^(Gradual|Immediate|Spikes)') {
            $RampUpApproach = $Matches[1]
        }
        else {
            $UnmappedRampUpRows.Add([PSCustomObject]@{
                AirtableRecordId = $RecId
                Name             = $Name
                RawValue         = $RawRampUpValue
                Reason           = "Doesn't start with Gradual/Immediate/Spikes - looks like a data-entry error, not a real Ramp Up Approach value. Left blank - needs human review."
            })
        }
    }

    $LaunchLevel = ""
    if ($Row.fields.'Launch Level' -and $LaunchLevelMap.ContainsKey($Row.fields.'Launch Level')) {
        $LaunchLevel = $LaunchLevelMap[$Row.fields.'Launch Level']
    }

    $DemographicTags = [System.Collections.Generic.List[string]]::new()
    foreach ($Category in @($Row.fields.'Demographic Served')) {
        if (-not $Category) { continue }
        if ($DemographicServedMap.ContainsKey($Category)) {
            $DemographicTags.Add($DemographicServedMap[$Category])
        }
        else {
            $DroppedDemographicTagCount++
        }
    }
    $DemographicServedValue = ($DemographicTags | Sort-Object -Unique) -join ";"

    $BrokerApplication = ($Row.fields.'Broker Application' -eq "Yes")

    # Every Url field goes through the same placeholder + length rules.
    $UrlValues = @{}
    foreach ($UrlPair in $UrlFieldMap) {
        $UrlValues[$UrlPair.Sf] = Resolve-UrlValue `
            -Value $Row.fields.($UrlPair.Airtable) `
            -AirtableField $UrlPair.Airtable `
            -RecordId $RecId `
            -ReviewList $OverLengthRows
    }

    $Description = $Row.fields.Description
    if ($Description -and $Description -match '^TBD') { $Description = "" }

    # Despite looking like a plain single-select, Airtable returns Service
    # Level as a 1-element linked-record-style array (confirmed against the
    # raw JSON) - same @()[0] unwrap as every other linked field, or
    # PowerShell stringifies the array as the literal text "System.Object[]"
    # on CSV export, which Salesforce then rejects as an invalid picklist
    # value. Every other direct-passthrough field in this script was checked
    # and is a genuine scalar - this is the only one shaped this way.
    $ServiceLevel = ""
    if ($Row.fields.'Service Level') {
        $ServiceLevel = @($Row.fields.'Service Level')[0]
    }

    # --- OwnerId: inherited from the Partner Account ---
    # Blank means "fall back to the loading user" and is deliberate: Bulk API
    # 2.0 treats an empty value as "not supplied", so an insert lands on the
    # loading user (the agreed fallback) and a re-run leaves any manual
    # reassignment in Salesforce intact instead of reverting it.
    $OwnerId = ""
    if ($PartnerAccountOwnerById.ContainsKey($PartnerAccountId)) {
        $OwnerId = $PartnerAccountOwnerById[$PartnerAccountId]
    }

    $OutputRow = [ordered]@{
        LDGCRM_External_ID__c                             = $RecId
        OwnerId                                            = $OwnerId
        Name                                               = $Name
        "LDGCRM_Partner_Account__r.LDGCRM_External_ID__c"  = $PartnerAccountId
        "LDGCRM_Opportunity__r.LDGCRM_External_ID__c"      = $OpportunityId
        LDGCRM_Status__c                                  = $Status
        LDGCRM_Ramp_Up_Approach__c                        = $RampUpApproach
        LDGCRM_Launch_Level__c                            = $LaunchLevel
        LDGCRM_Demographic_Served__c                      = $DemographicServedValue
        LDGCRM_Service_Level__c                           = $ServiceLevel
        LDGCRM_Broker_Application__c                      = if ($BrokerApplication) { "true" } else { "false" }
        LDGCRM_Actual_Go_Live_Date__c                     = Resolve-DateValue -Value $Row.fields.'Actual Go-Live Date' -AirtableField "Actual Go-Live Date" -RecordId $RecId -ReviewList $OverLengthRows
        LDGCRM_Current_Go_Live_Date__c                    = Resolve-DateValue -Value $Row.fields.'Current Go Live Date' -AirtableField "Current Go Live Date" -RecordId $RecId -ReviewList $OverLengthRows
        LDGCRM_num_est_annual_idv__c                      = $Row.fields.'# of Estimated Annual IdV Transactions'
        LDGCRM_Est_Monthly_Active_Users__c                = $Row.fields.'# of Estimated Monthly Active Users'
        LDGCRM_Completed_Customer_Support_Survey__c       = $UrlValues["LDGCRM_Completed_Customer_Support_Survey__c"]
        LDGCRM_Completed_Fraud_Survey__c                  = $UrlValues["LDGCRM_Completed_Fraud_Survey__c"]
        LDGCRM_Completed_Security_Survey_URL__c           = $UrlValues["LDGCRM_Completed_Security_Survey_URL__c"]
        LDGCRM_Launch_Checklist_URL__c                    = $UrlValues["LDGCRM_Launch_Checklist_URL__c"]
        LDGCRM_Launch_Deck_URL__c                         = $UrlValues["LDGCRM_Launch_Deck_URL__c"]
        LDGCRM_URL__c                                     = $UrlValues["LDGCRM_URL__c"]
        LDGCRM_Description__c                             = $Description
    }

    foreach ($Pair in $PresenceBooleanFields) {
        $OutputRow[$Pair.Sf] = Get-PresenceBool $Row.fields.($Pair.Airtable)
    }

    $UpsertRows.Add([PSCustomObject]$OutputRow)
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "LDGCRM_application__c-upsert.csv"
$SkippedFile = Join-Path $LogDir "Application-skipped-$Timestamp.csv"
$UnmappedRampUpFile = Join-Path $LogDir "Application-unmapped-rampup-$Timestamp.csv"
$OverLengthFile = Join-Path $LogDir "Application-overlength-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile
}

if ($SkippedRows.Count -gt 0) {
    $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8
}

if ($UnmappedRampUpRows.Count -gt 0) {
    $UnmappedRampUpRows | Export-Csv -LiteralPath $UnmappedRampUpFile -NoTypeInformation -Encoding UTF8
}

if ($OverLengthRows.Count -gt 0) {
    $OverLengthRows | Export-Csv -LiteralPath $OverLengthFile -NoTypeInformation -Encoding UTF8
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " APPLICATION PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
$SkippedNoPartnerAccount = @($SkippedRows | Where-Object { $_.Reason -like "No linked Partner Account*" }).Count
$SkippedPartnerAccountNotLoaded = @($SkippedRows | Where-Object { $_.Reason -like "Linked Partner Account*" }).Count

Write-Host ("{0,-48} {1,8:N0}" -f "Airtable Application rows", $AirtableApplications.Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Ready for upsert", $UpsertRows.Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Skipped - no Partner Account in Airtable", $SkippedNoPartnerAccount)
Write-Host ("{0,-48} {1,8:N0}" -f "Skipped - Partner Account not loaded in org", $SkippedPartnerAccountNotLoaded)
Write-Host ("{0,-48} {1,8:N0}" -f "Opportunity links blanked (Opportunity not loaded)", $UnresolvedOpportunityCount)
Write-Host ("{0,-48} {1,8:N0}" -f "Owner inherited from Partner Account", @($UpsertRows | Where-Object { $_.OwnerId }).Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Owner falls back to the loading user", @($UpsertRows | Where-Object { -not $_.OwnerId }).Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Unmapped Ramp Up Approach (left blank)", $UnmappedRampUpRows.Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Demographic Served tags dropped (stale category)", $DroppedDemographicTagCount)
Write-Host ("{0,-48} {1,8:N0}" -f "Name/URL/date values corrected or blanked", $OverLengthRows.Count)
Write-Host ""

if ($UpsertRows.Count -gt 0) {
    Write-Host "Upsert file (external-ID keyed, requires Partner Account already loaded):" -ForegroundColor Cyan
    Write-Host $UpsertFile
}

if ($SkippedRows.Count -gt 0) {
    Write-Host "Skipped rows for human review:" -ForegroundColor Yellow
    Write-Host $SkippedFile
}

if ($UnmappedRampUpRows.Count -gt 0) {
    Write-Host "Unmapped Ramp Up Approach rows for human review:" -ForegroundColor Yellow
    Write-Host $UnmappedRampUpFile
}

if ($OverLengthRows.Count -gt 0) {
    Write-Host "Name/URL/date values needing human review:" -ForegroundColor Yellow
    Write-Host $OverLengthFile
}

}
finally {
    Stop-ScriptLog
}
