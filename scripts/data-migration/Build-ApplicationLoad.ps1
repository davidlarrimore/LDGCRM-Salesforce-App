#Requires -Version 5.1

<#
    Chunk 3 of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md). Full field-by-field investigation,
    every exclusion's reasoning, and the Demographic Served picklist expansion
    (deployed separately via sfdx-metadata-sync before this script was written)
    live in docs/engineering/TRANSFORMATION-RULES.md's Application section - this header only
    covers what a script reader needs at a glance, not the full justification.

    LDGCRM_Partner_Account__c is a REQUIRED Lookup - needs Partner Account
    loaded first, or every row's parent lookup fails to resolve. LDGCRM_Opportunity__c
    is optional and needs Opportunity loaded (not built yet) to resolve; rows
    load fine without it, that lookup just stays blank until Opportunity exists.

    Does not query Salesforce - purely an offline Airtable JSON -> CSV
    transform, like Impediment (no User-resolution or reconciliation needed
    here, unlike Account/Partner Account).

    Fields NOT written, deliberately (see docs/engineering/TRANSFORMATION-RULES.md for why each
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
      - LDGCRM_Annual_Revenue_Amount__c: no Airtable source found.
      - LDGCRM_PP_Issuer_Strings__c: not migrated, and now DEPRECATED - the
        project owner confirmed 2026-08-13 that this data is not being migrated
        and the field is to be retired. Removal is not a plain delete: a formula
        (LDGCRM_Level_1_Complete_Pct__c) depends on it, which in turn feeds
        LDGCRM_Launch_Checklist_Completion__c. Tracked as CR-2 in
        docs/engineering/SALESFORCE-CHANGE-REQUESTS.md. Nothing here needs to
        change when it goes - this script never wrote it.
      - LDGCRM_Broker_App_Parent__c: a self-Lookup (Application -> Application).
        Deliberately NOT in the main upsert file - a first real load attempt
        (2026-08-12) confirmed Bulk API 2.0 does not resolve external-ID
        references between two rows in the same upsert batch, so every
        Broker App Parent reference failed with "foreign key external ID not
        found" even though the parent Application was in the very same CSV.
        This script now writes it to a SEPARATE second-pass file
        (LDGCRM_application__c-broker-parent-upsert.csv) automatically, so there
        is no extra script to remember - but that file must be LOADED AFTER the
        main one. See the "SECOND PASS" block below.

    LDGCRM_P3_Partner_Portal_Team_Name__c / LDGCRM_P3_Team_UUID__c DO migrate,
    sourced from the Issuer Strings table (added to Get-AirtableExport.ps1 by
    PR #1). Airtable models Application -> Issuer Strings as 1:N with the team
    recorded on each issuer string rather than on the Application, so the value
    is collapsed up: see Get-PortalTeamByApplication below for the rules, and
    the UNIQUE-CONSTRAINT PREFLIGHT block for why the columns may be withheld
    from the CSV altogether pending a change set.

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
    [string]$OrgAlias = "",

    [string]$ApiVersion = "67.0",

    # Owner for records whose own owner can't be determined. Resolved to a User
    # at run time (never a hard-coded Id - production's differs from every
    # sandbox's) and the run FAILS if it doesn't match an active User.
    [string]$FallbackOwnerEmail = "peter.marks@gsa.gov"
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
# (2026-08-12 analysis - see docs/engineering/TRANSFORMATION-RULES.md), mapped to their
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

function Get-CleanIssuerStringValue {
    <#
        Normalises one Team Name / Team UUID cell.

        "#N/A" is a LITERAL STRING in this table, not an Airtable empty - 136
        Team Names and 137 Team UUIDs carry it (2026-08-13 export). It is a
        spreadsheet artifact from however this table was populated, and every
        "#N/A" Team UUID is exactly 4 characters against a real UUID's 36, so
        there is no chance of a real value being caught by this. Treating it as
        text would write the string "#N/A" into Salesforce as if it were a team.
    #>
    param([object]$Value)

    if ($null -eq $Value) { return $null }

    $Text = ([string]$Value).Trim()

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -eq "#N/A") { return $null }

    return $Text
}

function Get-PortalTeamByApplication {
    <#
        Collapses the Issuer Strings table's per-issuer-string Team Name / Team
        UUID up to one value per Application, returning a hashtable keyed by
        Airtable Application record ID.

        WHY THIS NEEDS RULES AT ALL: the partner-portal team is a property of the
        APPLICATION (user-confirmed 2026-08-13). Airtable stores it on each
        ISSUER STRING instead, so it is duplicated across every issuer string an
        Application has, and **every copy is supposed to be identical**. The
        Application is therefore updated ONCE, from the single value they agree
        on - this is a de-duplication, not a merge of distinct facts.

        That framing decides how disagreement is handled: a set that does not
        agree is duplicated data that has DRIFTED, i.e. a defect to fix at
        source, never a signal that the Application legitimately has two teams.

        Verified against the 2026-08-13 export (901 issuer strings, 887 distinct
        Applications):
          - 678 agree on one Team UUID across every issuer string.  Clean.
          -  18 carry it on some issuer strings and leave others blank.
                Still unambiguous, so the Application gets the right team and
                nothing is blocked - but the blanks are reported, because under
                the rule above they are missing copies, not absent data.
          -   9 carry two DIFFERENT Team UUIDs.  Left blank + reported.
          - 182 have no Team UUID anywhere.  Nothing to carry over.

        The 9 are a genuine source defect - single Application rows whose issuer
        strings belong to two different portal teams (typically a dev/test
        string owned by one team and a prod string owned by another). There is
        no defensible tie-break - "first wins" would silently pick whichever
        issuer string sorted first - so BOTH fields are left blank and the
        Application is written to a review CSV for the Airtable owners. Same
        rule as everywhere else in this pipeline: skip and report, never invent
        a value to make a number look better.

        Team UUID is the authority when the two disagree, per the Salesforce
        field's own help text ("The name can be modified, so trust the Team
        UUID"). In this export they never do disagree - Team UUID <-> Team Name
        is exactly 1:1 across all 368 distinct UUIDs, 0 violations either
        direction - so the pair is resolved together and the check below is a
        guard against that changing, not a live code path.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$IssuerStringRows,

        # Not [Parameter(Mandatory)] - these are always passed, but a Mandatory
        # collection parameter REJECTS an empty list, and both of these start
        # empty on every run. Same shape as Resolve-UrlValue's $ReviewList.
        [System.Collections.Generic.List[object]]$ReviewList,

        [System.Collections.Generic.List[object]]$OverLengthList,

        [Parameter(Mandatory = $true)]
        [int]$MaxTeamNameLength
    )

    # Application record ID -> list of the team values seen on its issuer strings.
    $Observations = @{}
    $OrphanIssuerStrings = 0

    foreach ($IssuerRow in $IssuerStringRows) {
        # Null-check before @() - the usual 1-element-array-of-null gotcha, and
        # 7 issuer strings genuinely have no Application link at all.
        $RawApplications = $IssuerRow.fields.'Applications'
        if (-not $RawApplications) { $OrphanIssuerStrings++; continue }

        $TeamName = Get-CleanIssuerStringValue $IssuerRow.fields.'Team Name'
        $TeamUuid = Get-CleanIssuerStringValue $IssuerRow.fields.'Team UUID'

        foreach ($ApplicationId in @($RawApplications)) {
            if ([string]::IsNullOrWhiteSpace([string]$ApplicationId)) { continue }

            $Key = [string]$ApplicationId

            if (-not $Observations.ContainsKey($Key)) {
                $Observations[$Key] = [System.Collections.Generic.List[object]]::new()
            }

            # 2 rows in the table are entirely empty - no team AND no issuer
            # string. Label them so a review CSV cell is never just blank with
            # no explanation; an empty cell reads as a bug in the report.
            $IssuerStringText = $IssuerRow.fields.'Issuer String'
            if ([string]::IsNullOrWhiteSpace($IssuerStringText)) {
                $IssuerStringText = "(blank row $($IssuerRow.id) - no issuer string either)"
            }

            $Observations[$Key].Add([PSCustomObject]@{
                IssuerStringRecordId = $IssuerRow.id
                IssuerString         = $IssuerStringText
                TeamName             = $TeamName
                TeamUuid             = $TeamUuid
            })
        }
    }

    $Resolved = @{}

    foreach ($Key in $Observations.Keys) {
        $Seen = $Observations[$Key]

        $DistinctUuids = @($Seen | ForEach-Object { $_.TeamUuid } |
            Where-Object { $_ } | Select-Object -Unique)
        $DistinctNames = @($Seen | ForEach-Object { $_.TeamName } |
            Where-Object { $_ } | Select-Object -Unique)

        if ($DistinctUuids.Count -eq 0) { continue }   # nothing to carry over

        if ($DistinctUuids.Count -gt 1 -or $DistinctNames.Count -gt 1) {
            $ReviewList.Add([PSCustomObject]@{
                Issue                 = "CONFLICT - blocks both fields"
                AirtableApplicationId = $Key
                IssuerStringCount     = $Seen.Count
                BlankIssuerStrings    = @($Seen | Where-Object { -not $_.TeamUuid }).Count
                DistinctTeamUuids     = $DistinctUuids.Count
                TeamUuids             = ($DistinctUuids -join " | ")
                TeamNames             = ($DistinctNames -join " | ")
                IssuerStrings         = (@($Seen | ForEach-Object { $_.IssuerString }) -join " | ")
                Reason                = "The partner-portal team belongs to the Application, and Airtable duplicates it onto every one of that Application's issuer strings - so all copies should be identical. Here they are not: this Application's issuer strings name two different teams. That is drifted duplicate data, not an Application with two teams, so there is nothing to migrate and both fields are left BLANK. Fix in Airtable: decide which team is correct and make every issuer string match (or move the issuer strings that belong to the other team onto the Application they actually belong to)."
            })
            continue
        }

        # Unambiguous, so the Application still gets the right team - but under
        # the "every copy should be identical" rule these blanks are MISSING
        # COPIES rather than absent data, so they are reported. Deliberately
        # non-blocking: nothing about the load changes because of them.
        $BlankCount = @($Seen | Where-Object { -not $_.TeamUuid }).Count
        if ($BlankCount -gt 0) {
            $ReviewList.Add([PSCustomObject]@{
                Issue                 = "INCOMPLETE - migrates correctly, tidy-up only"
                AirtableApplicationId = $Key
                IssuerStringCount     = $Seen.Count
                BlankIssuerStrings    = $BlankCount
                DistinctTeamUuids     = 1
                TeamUuids             = $DistinctUuids[0]
                TeamNames             = ($DistinctNames -join " | ")
                IssuerStrings         = (@($Seen | Where-Object { -not $_.TeamUuid } |
                                            ForEach-Object { $_.IssuerString }) -join " | ")
                Reason                = "$BlankCount of this Application's $($Seen.Count) issuer strings have a blank (or '#N/A') Team Name/Team UUID while the rest agree on one team. NOT BLOCKING - the team is unambiguous, so it migrates correctly. Listed because the copies should all match: worth filling in so the table doesn't read as though this Application's team is only partly known. The issuer strings named here are the blank ones."
            })
        }

        $ResolvedName = $null
        if ($DistinctNames.Count -eq 1) { $ResolvedName = $DistinctNames[0] }

        # Text(50) in Salesforce; 6 distinct team names in the 2026-08-13
        # export are longer (up to 75), hitting 8 Applications - one team
        # covers three. Blank the NAME rather than truncate it, and keep
        # the UUID - the UUID is the field that identifies the team, and a
        # truncated display name would read as a real one while quietly not
        # matching what the partner portal shows. Reported for review either way.
        if ($ResolvedName -and $ResolvedName.Length -gt $MaxTeamNameLength) {
            $OverLengthList.Add([PSCustomObject]@{
                AirtableRecordId = $Key
                Field            = "Team Name (from Issuer Strings)"
                OriginalValue    = $ResolvedName
                AppliedValue     = ""
                Reason           = "Partner Portal Team Name is $($ResolvedName.Length) chars against LDGCRM_P3_Partner_Portal_Team_Name__c's $MaxTeamNameLength-char limit. Left BLANK rather than truncated - a truncated team name would not match the partner portal. The Team UUID still migrated. Needs either a shorter name in the portal or a longer Salesforce field."
            })
            $ResolvedName = $null
        }

        $Resolved[$Key] = [PSCustomObject]@{
            TeamName = $ResolvedName
            TeamUuid = $DistinctUuids[0]
        }
    }

    return [PSCustomObject]@{
        ByApplicationId     = $Resolved
        ApplicationsSeen    = $Observations.Keys.Count
        OrphanIssuerStrings = $OrphanIssuerStrings
    }
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
# docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) is a guaranteed Bulk API failure,
# not a maybe. The 2026-08-13 load submitted 343 such rows and got 343
# INVALID_FIELD errors back. Checking up front turns those into an explicit,
# reviewable skip list instead of load-time noise that buries real failures.
Write-Host ""
Write-Host "Resolving the fallback owner ($FallbackOwnerEmail)..." -ForegroundColor Cyan
$FallbackOwnerId = Resolve-FallbackOwnerId -Email $FallbackOwnerEmail -OrgAlias $OrgAlias -ApiVersion $ApiVersion
Write-Host "Fallback owner resolves to $FallbackOwnerId."

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
#
# UserType is pulled for a DIFFERENT and less obvious reason, and it has to be
# checked HERE rather than relying on Resolve-SalesforceOwnerIds. That resolver
# now excludes non-Standard users, but it governs what goes INTO
# LDGCRM_Partner_Account_Owner__c - and that field is an ordinary User LOOKUP,
# which may legitimately point at a Chatter Free or portal user. Ownership is
# the stricter operation: only UserType = 'Standard' can OWN a record.
#
# Reading the lookup and using it as an OwnerId without re-checking is exactly
# what failed 150 of 688 rows on 2026-08-13 with
# OP_WITH_INVALID_USER_TYPE_EXCEPTION - and it failed AGAIN after the resolver
# was fixed, because this path never consulted the resolver at all. A value
# that is valid in a lookup is not automatically valid as an owner.
$LoadedPartnerAccounts = @(Invoke-SalesforceQuery `
    -Soql ("SELECT LDGCRM_External_ID__c, LDGCRM_Partner_Account_Owner__c, " +
           "LDGCRM_Partner_Account_Owner__r.IsActive, " +
           "LDGCRM_Partner_Account_Owner__r.UserType " +
           "FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null") `
    -OrgAlias $OrgAlias)

$LoadedPartnerAccountIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$PartnerAccountOwnerById = @{}
$OwnerIneligible = 0
foreach ($Pa in $LoadedPartnerAccounts) {
    if ($Pa.LDGCRM_External_ID__c) {
        $LoadedPartnerAccountIds.Add($Pa.LDGCRM_External_ID__c) | Out-Null

        if ($Pa.LDGCRM_Partner_Account_Owner__c -and
            $Pa.LDGCRM_Partner_Account_Owner__r.IsActive -and
            $Pa.LDGCRM_Partner_Account_Owner__r.UserType -eq "Standard") {
            $PartnerAccountOwnerById[$Pa.LDGCRM_External_ID__c] = $Pa.LDGCRM_Partner_Account_Owner__c
        }
        elseif ($Pa.LDGCRM_Partner_Account_Owner__c -and
                $Pa.LDGCRM_Partner_Account_Owner__r.IsActive) {
            # Active, but not a user type that can own a record. Counted
            # separately so the summary says WHY these fell back, rather than
            # silently merging them with "no owner recorded".
            $OwnerIneligible++
        }
    }
}
Write-Host "$($LoadedPartnerAccountIds.Count) Partner Accounts present in $OrgAlias."
Write-Host "$($PartnerAccountOwnerById.Count) of them carry an owner eligible to pass down to Applications."
if ($OwnerIneligible -gt 0) {
    Write-Host "$OwnerIneligible have an ACTIVE owner who cannot own records (non-Standard UserType); those Applications take the fallback owner." -ForegroundColor Yellow
}

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
$PortalTeamReviewRows = [System.Collections.Generic.List[object]]::new()
$DroppedDemographicTagCount = 0
$UnresolvedOpportunityCount = 0

# ============================================================
# PARTNER PORTAL TEAM (from the Issuer Strings table)
# ============================================================
Write-Host ""
Write-Host "Loading Airtable Issuer Strings export..." -ForegroundColor Cyan
$AirtableIssuerStrings = Import-AirtableTable -Label "Issuer Strings"
Write-Host "$($AirtableIssuerStrings.Count) Airtable Issuer String rows loaded."

# Read the two target fields' real definitions instead of trusting the
# committed metadata - QA can trail Dev by a change set, and the whole point of
# the preflight below is that it must reflect the org being loaded.
$ApplicationFields = Get-SalesforceFieldMetadata `
    -ObjectApiName "LDGCRM_application__c" -OrgAlias $OrgAlias -ApiVersion $ApiVersion

$TeamNameField = $ApplicationFields["LDGCRM_P3_Partner_Portal_Team_Name__c"]
$TeamUuidField = $ApplicationFields["LDGCRM_P3_Team_UUID__c"]

if (-not $TeamNameField -or -not $TeamUuidField) {
    throw ("LDGCRM_P3_Partner_Portal_Team_Name__c and/or LDGCRM_P3_Team_UUID__c do not exist on " +
           "LDGCRM_application__c in $OrgAlias. Both are needed to migrate the partner-portal team. " +
           "They exist in Dev - if this is QA, the field is waiting on a change set (metadata is " +
           "promoted by CHANGE SET only; see CLAUDE.md).")
}

$PortalTeam = Get-PortalTeamByApplication `
    -IssuerStringRows $AirtableIssuerStrings `
    -ReviewList $PortalTeamReviewRows `
    -OverLengthList $OverLengthRows `
    -MaxTeamNameLength ([int]$TeamNameField.length)

$PortalTeamByApplicationId = $PortalTeam.ByApplicationId

Write-Host ("$($PortalTeam.ApplicationsSeen) Applications are referenced by an issuer string; " +
            "$($PortalTeamByApplicationId.Count) resolve to a single partner-portal team.")
if ($PortalTeam.OrphanIssuerStrings -gt 0) {
    Write-Host ("$($PortalTeam.OrphanIssuerStrings) issuer string(s) link to no Application at all - " +
                "they carry no team to anywhere and are ignored.") -ForegroundColor Yellow
}
# The team belongs to the Application and Airtable duplicates it onto every
# issuer string, so these two are both "the copies disagree" - they differ only
# in whether the disagreement is resolvable. Counted apart because one blocks
# the fields and the other changes nothing about the load.
$PortalTeamConflictCount = @($PortalTeamReviewRows |
    Where-Object { $_.Issue -like "CONFLICT*" }).Count
$PortalTeamIncompleteCount = @($PortalTeamReviewRows |
    Where-Object { $_.Issue -like "INCOMPLETE*" }).Count

if ($PortalTeamConflictCount -gt 0) {
    Write-Host ("$PortalTeamConflictCount Application(s) have issuer strings naming MORE THAN ONE " +
                "portal team - drifted duplicates, both fields left blank. See the review CSV.") -ForegroundColor Yellow
}
if ($PortalTeamIncompleteCount -gt 0) {
    Write-Host ("$PortalTeamIncompleteCount Application(s) carry the team on only SOME of their issuer " +
                "strings - unambiguous, so they migrate correctly; listed as tidy-up only.")
}

# ---------- UNIQUE-CONSTRAINT PREFLIGHT ----------
# Both fields are currently unique=true in the org. That models one portal team
# owning at most one Application, and the source data flatly contradicts it: a
# team owns many Applications by design (e.g. "DOI - FWS - ECOS" owns 54).
# Across the Applications that resolve cleanly, 104 Team UUIDs are shared by 2+
# Applications, covering 442 of them - so writing these columns against a
# unique field would fail the majority of the load with DUPLICATE_VALUE.
#
# This CANNOT be fixed from here: flipping unique to false is a metadata change,
# and metadata promotion is by CHANGE SET only (CLAUDE.md) - a CLI deploy is
# sanctioned solely for DELETING incorrect metadata. So the script adapts to the
# org instead of failing the whole Application load over two columns that
# everything else does not depend on: it withholds them and says exactly what
# needs to go in the change set. Once that lands, a plain re-run picks them up
# with no code change - same contract as the Opportunity lookup above.
$PortalTeamFieldsBlocked = ($TeamNameField.unique -or $TeamUuidField.unique)
$PortalTeamCollisionCount = 0

if ($PortalTeamFieldsBlocked) {
    $UuidGroups = $PortalTeamByApplicationId.Values | Group-Object TeamUuid
    $PortalTeamCollisionCount = (@($UuidGroups | Where-Object { $_.Count -gt 1 }) |
        Measure-Object -Property Count -Sum).Sum
    if (-not $PortalTeamCollisionCount) { $PortalTeamCollisionCount = 0 }

    Write-Host ""
    Write-Host "  !! PARTNER PORTAL TEAM COLUMNS WITHHELD FROM THIS LOAD !!" -ForegroundColor Red
    Write-Host ("     LDGCRM_P3_Team_UUID__c unique=$($TeamUuidField.unique), " +
                "LDGCRM_P3_Partner_Portal_Team_Name__c unique=$($TeamNameField.unique) in $OrgAlias.") -ForegroundColor Yellow
    Write-Host ("     One portal team legitimately owns many Applications, so $PortalTeamCollisionCount of " +
                "$($PortalTeamByApplicationId.Count) resolved Applications would fail with DUPLICATE_VALUE.") -ForegroundColor Yellow
    Write-Host "     CHANGE SET NEEDED: set Unique = false on both fields (they are not External IDs" -ForegroundColor Yellow
    Write-Host "     and nothing keys on them). Then re-run this script - no code change." -ForegroundColor Yellow
    Write-Host ""
}
else {
    Write-Host "Partner-portal team columns will be written (both fields are non-unique)." -ForegroundColor Green
}

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
            Reason           = "Linked Partner Account $PartnerAccountId is not loaded in $OrgAlias (its own parent Account is unresolved - see docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md). Would fail the load with INVALID_FIELD - skipped. Re-run once the Account/Partner Account data is fixed."
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
    # The fallback is written EXPLICITLY, not left blank - see
    # Resolve-FallbackOwnerId for why, and for the re-run trade-off it costs.
    $OwnerId = $FallbackOwnerId
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
        # '# of Estimated Annual IdV Transactions' and '# of Estimated Monthly
        # Active Users' are NOT migrated: their target fields
        # (LDGCRM_num_est_annual_idv__c, LDGCRM_Est_Monthly_Active_Users__c)
        # were deleted from the org on 2026-08-13 as no longer wanted, and the
        # metadata was removed from this repo to match.
        #
        # Worth knowing how it surfaced, because the error is unhelpful: Bulk
        # API rejected the WHOLE batch with
        #   InvalidBatch : Field name not found : LDGCRM_num_est_annual_idv__c
        # naming only the FIRST missing column, so fixing that one alone would
        # have failed again on the second. When this happens, diff every CSV
        # column against `sf sobject describe` rather than chasing the error
        # one field at a time.
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

    # Partner-portal team, collapsed up from this Application's issuer strings.
    # Omitted entirely (not blanked) while the unique constraint stands, so the
    # CSV has no column at all rather than an empty one - an empty column on an
    # upsert would CLEAR any value already in the org.
    if (-not $PortalTeamFieldsBlocked) {
        $Team = $null
        if ($PortalTeamByApplicationId.ContainsKey($RecId)) {
            $Team = $PortalTeamByApplicationId[$RecId]
        }

        $OutputRow["LDGCRM_P3_Partner_Portal_Team_Name__c"] = if ($Team -and $Team.TeamName) { $Team.TeamName } else { "" }
        $OutputRow["LDGCRM_P3_Team_UUID__c"]                = if ($Team) { $Team.TeamUuid } else { "" }
    }

    $UpsertRows.Add([PSCustomObject]$OutputRow)
}

# ============================================================
# SECOND PASS: LDGCRM_Broker_App_Parent__c (self-referential lookup)
# ============================================================
# Built automatically here rather than by a separate script somebody has to
# remember to run - the whole reason it exists is that it is easy to forget.
#
# WHY IT CANNOT GO IN THE MAIN FILE: Bulk API 2.0 does not resolve an external-ID
# reference between two rows of the SAME batch. Proven, not assumed - the first
# real load (2026-08-13) failed 68 rows with "Foreign key external ID not found"
# while the parent Application sat in the very same CSV. Every self-referential
# lookup in this pipeline needs its own pass, after every row exists.
#
# The file is written now but MUST BE LOADED AFTER the main Application file.
# Loading it first fails every row, for exactly the reason above.
#
# A row is only emitted when BOTH sides will exist once the main load finishes:
# the planned upsert set plus whatever is already in the org (a re-run may skip
# an Application it loaded previously, if its Partner Account has since become
# unresolvable).
Write-Host ""
Write-Host "Building the Broker App Parent second pass..." -ForegroundColor Cyan

$ExistingApplicationIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($App in @(Invoke-SalesforceQuery `
        -Soql "SELECT LDGCRM_External_ID__c FROM LDGCRM_application__c WHERE LDGCRM_External_ID__c != null" `
        -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($App.LDGCRM_External_ID__c) { $ExistingApplicationIds.Add($App.LDGCRM_External_ID__c) | Out-Null }
}

# Everything that will be present in the org once the main load completes.
$WillExist = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($Planned in $UpsertRows) { $WillExist.Add($Planned.LDGCRM_External_ID__c) | Out-Null }
foreach ($Id in $ExistingApplicationIds) { $WillExist.Add($Id) | Out-Null }

$BrokerParentRows = [System.Collections.Generic.List[object]]::new()
$BrokerSkippedRows = [System.Collections.Generic.List[object]]::new()

foreach ($Row in $AirtableApplications) {
    $RawParent = $Row.fields.'Broker App Parent'
    if (-not $RawParent) { continue }          # null-check before @()

    # Verified 0 of 70 rows carry more than one parent, but a lookup holds one
    # value regardless - take the first and say so rather than silently drop.
    $ParentId = @($RawParent)[0]
    if (-not $ParentId) { continue }

    # SELF-REFERENCE. Real in this data: "ACF Login.gov ACF-ockta-oidc" is its
    # own Broker App Parent. Meaningless as a hierarchy whether or not
    # Salesforce accepts the write, so it is dropped and reported rather than
    # loaded. Checked before the existence test because a self-reference is a
    # source-data defect, not a load-ordering problem, and should be described
    # as one.
    #
    # It is NOT in AIRTABLE-DATA-QUALITY-REQUESTS.md, on purpose. That list is
    # for things the data owners need to act on, and this blocks nothing - one
    # optional lookup on one record that migrates fine either way. Putting
    # zero-impact items on it trains people to ignore the list.
    if ($ParentId -eq $Row.id) {
        $BrokerSkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $Row.id
            Name             = $Row.fields.Name
            BrokerAppParent  = $ParentId
            NotLoaded        = "n/a - self-reference"
            Reason           = "This Application is its OWN Broker App Parent. A record cannot be its own parent, so this one link is dropped; the Application itself migrates normally. Recorded here for visibility - deliberately NOT raised as a data-quality request, since it blocks nothing."
        })
        continue
    }

    $Missing = @()
    if (-not $WillExist.Contains($Row.id))   { $Missing += "the Application itself" }
    if (-not $WillExist.Contains($ParentId)) { $Missing += "its Broker App Parent" }

    if ($Missing.Count -gt 0) {
        $BrokerSkippedRows.Add([PSCustomObject]@{
            AirtableRecordId = $Row.id
            Name             = $Row.fields.Name
            BrokerAppParent  = $ParentId
            NotLoaded        = ($Missing -join " and ")
            Reason           = "Both sides of a self-referential lookup must exist. The missing side was withheld by the main Application load - usually the unreconciled-Account data-quality issue. Re-run after it loads; no code change needed."
        })
        continue
    }

    $BrokerParentRows.Add([PSCustomObject][ordered]@{
        LDGCRM_External_ID__c                            = $Row.id
        "LDGCRM_Broker_App_Parent__r.LDGCRM_External_ID__c" = $ParentId
    })
}

Write-Host "$($BrokerParentRows.Count) Broker App Parent link(s) ready; $($BrokerSkippedRows.Count) waiting on a missing side."

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "LDGCRM_application__c-upsert.csv"
$BrokerParentFile = Join-Path $LoadDir "LDGCRM_application__c-broker-parent-upsert.csv"
$BrokerSkippedFile = Join-Path $LogDir "Application-broker-parent-skipped-$Timestamp.csv"
$SkippedFile = Join-Path $LogDir "Application-skipped-$Timestamp.csv"
$UnmappedRampUpFile = Join-Path $LogDir "Application-unmapped-rampup-$Timestamp.csv"
$OverLengthFile = Join-Path $LogDir "Application-overlength-$Timestamp.csv"
$PortalTeamReviewFile = Join-Path $LogDir "Application-portal-team-review-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile
}

if ($BrokerParentRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $BrokerParentRows.ToArray() -Path $BrokerParentFile
}

if ($BrokerSkippedRows.Count -gt 0) {
    $BrokerSkippedRows | Export-Csv -LiteralPath $BrokerSkippedFile -NoTypeInformation -Encoding UTF8
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

if ($PortalTeamReviewRows.Count -gt 0) {
    $PortalTeamReviewRows | Export-Csv -LiteralPath $PortalTeamReviewFile -NoTypeInformation -Encoding UTF8
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
# Compare against the fallback Id, not "is OwnerId set" - every row carries one
# now, so a truthiness test would report every record as owner-resolved.
Write-Host ("{0,-48} {1,8:N0}" -f "Owner inherited from Partner Account", @($UpsertRows | Where-Object { $_.OwnerId -ne $FallbackOwnerId }).Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Owner = fallback ($FallbackOwnerEmail)", @($UpsertRows | Where-Object { $_.OwnerId -eq $FallbackOwnerId }).Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Unmapped Ramp Up Approach (left blank)", $UnmappedRampUpRows.Count)
Write-Host ("{0,-48} {1,8:N0}" -f "Demographic Served tags dropped (stale category)", $DroppedDemographicTagCount)
Write-Host ("{0,-48} {1,8:N0}" -f "Name/URL/date values corrected or blanked", $OverLengthRows.Count)
Write-Host ""
if ($PortalTeamFieldsBlocked) {
    Write-Host ("{0,-48} {1,8}" -f "Partner Portal Team columns", "WITHHELD") -ForegroundColor Red
    Write-Host ("{0,-48} {1,8:N0}" -f "  ...Applications ready once unique is off", $PortalTeamByApplicationId.Count)
    Write-Host ("{0,-48} {1,8:N0}" -f "  ...of those, would collide on unique=true", $PortalTeamCollisionCount)
}
else {
    Write-Host ("{0,-48} {1,8:N0}" -f "Partner Portal Team resolved", @($UpsertRows | Where-Object { $_.LDGCRM_P3_Team_UUID__c }).Count)
    Write-Host ("{0,-48} {1,8:N0}" -f "  ...Team Name blank (over length limit)", @($UpsertRows | Where-Object { $_.LDGCRM_P3_Team_UUID__c -and -not $_.LDGCRM_P3_Partner_Portal_Team_Name__c }).Count)
}
Write-Host ("{0,-48} {1,8:N0}" -f "Applications w/ conflicting portal teams", $PortalTeamConflictCount)
Write-Host ("{0,-48} {1,8:N0}" -f "  ...team on only some issuer strings (tidy-up)", $PortalTeamIncompleteCount)
Write-Host ""
Write-Host ("{0,-48} {1,8:N0}" -f "Broker App Parent links (SECOND PASS file)", $BrokerParentRows.Count)
Write-Host ("{0,-48} {1,8:N0}" -f "  ...waiting on a missing side", $BrokerSkippedRows.Count)
Write-Host ""

if ($UpsertRows.Count -gt 0) {
    Write-Host "Upsert file (external-ID keyed, requires Partner Account already loaded):" -ForegroundColor Cyan
    Write-Host $UpsertFile
}

if ($BrokerParentRows.Count -gt 0) {
    Write-Host ""
    Write-Host "SECOND PASS - load this AFTER the file above, never before:" -ForegroundColor Yellow
    Write-Host $BrokerParentFile
    Write-Host "  scripts\data-migration\Invoke-SalesforceLoad.ps1 -Environment $Environment ``" -ForegroundColor DarkGray
    Write-Host "      -ObjectApiName ""LDGCRM_application__c"" ``" -ForegroundColor DarkGray
    Write-Host "      -CsvFile ""data\salesforce-loads\LDGCRM_application__c-broker-parent-upsert.csv""" -ForegroundColor DarkGray
}

if ($BrokerSkippedRows.Count -gt 0) {
    Write-Host "Broker App Parent links waiting on a missing side:" -ForegroundColor Yellow
    Write-Host $BrokerSkippedFile
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

if ($PortalTeamReviewRows.Count -gt 0) {
    Write-Host "Partner-portal team review (CONFLICT rows block the fields; INCOMPLETE rows are tidy-up):" -ForegroundColor Yellow
    Write-Host $PortalTeamReviewFile
}

}
finally {
    Stop-ScriptLog
}
