#Requires -Version 5.1

<#
    Chunk 2 of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md). Full field-by-field investigation and every exclusion's
    reasoning live in docs/engineering/TRANSFORMATION-RULES.md's Opportunity section -
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
      - priority_type__c: DO NOT WRITE. Labelled "Priority Type" - identical to
        the Airtable column name - but un-prefixed and owned by TTS OTCRM. The
        label match is a trap, not evidence. See the block below.
    LDGCRM_Level_of_Priority__c IS written as of 2026-08-14. It was blocked while
    the field defined only Low/Medium/High against a restricted picklist; those
    were retired and Airtable's four real values added. Airtable's "N/A" maps to
    BLANK by decision - see $PriorityTypeMap below.
    LDGCRM_Existing_Identity_Platforms__c / LDGCRM_Alternative_Identity_Platforms__c
    ARE migrated as of 2026-08-13. They used to be blocked: the Airtable columns
    held rec... IDs pointing at a table this migration doesn't pull. Airtable has
    since converted both to plain multi-selects holding the vendor names
    directly, which is what the Salesforce multipicklists wanted all along. The
    per-value counts are unchanged by the conversion (272 / 181 tags), so no data
    was lost in it. See $IdentityPlatformMap below for the three values whose
    spelling still differs, and Assert-IdentityPlatformsResolved for why a stale
    export is a hard failure rather than 453 silently dropped tags.
    LDGCRM_Partner_Account__c is set here, but is derived from the APPLICATIONS
    export rather than the Opportunities one - the Airtable Opportunities table
    has no Partner Account column at all. Do NOT source it from the Partner
    Accounts table's "Opportunities" column: that is a roll-up of the parent
    ACCOUNT's opportunities (verified exact-match for 72 of 76 Partner
    Accounts), not an authored link, so it cannot say which Partner Account an
    individual Opportunity belongs to. All 8 Partner Accounts under the
    Department of Defense carry byte-identical 50-Opportunity lists, several
    named "(placeholder)". See docs/engineering/TRANSFORMATION-RULES.md.

    OwnerId resolves in THREE steps (business rule 2026-08-14):
      1. Airtable's "Pod Opportunity Lead" (a collaborator object carrying
         .email), where it matches one ACTIVE User;
      2. otherwise this Opportunity's PARTNER ACCOUNT owner, where it has one -
         which is rare, since only ~80 of 842 carry a Partner Account;
      3. otherwise the named fallback owner, written EXPLICITLY rather than left
         blank. See the OWNER CHAIN block at the output row for why that is
         deliberate and not an oversight.

    This needs no separate pass: Partner Accounts load BEFORE Opportunity (see
    the load order in docs/engineering/ARCHITECTURE.md), so the lookup resolves during this same
    load, and the derivation only needs the local Applications JSON export, not
    Applications loaded into Salesforce. (Contrast Application's
    LDGCRM_Broker_App_Parent__c, which is genuinely a second pass because it is
    self-referential - its parents are in its own batch.)
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (powershell-scripts/Common.Orgs.ps1).
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

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-OpportunityLoad"

# Airtable Focus Level carries the cadence in the label ("High (2 month
# update)"); the Salesforce picklist stores just the level. Map by leading
# token, same shape as Application's Ramp Up Approach rule.
$FocusLevelPattern = '^(Highest|High|Backlog|Developing)'

# Airtable's "Priority Type" -> LDGCRM_Level_of_Priority__c.
# UNBLOCKED 2026-08-14: the field previously defined only Low / Medium / High
# and is restricted=true, so every in-scope row would have failed. The four
# values below were added to the field AND assigned to the Login_gov record
# type, and Low / Medium / High were retired (deactivated - a metadata deploy
# cannot delete a picklist value, and 0 Opportunities used any of them).
#
# DO NOT WRITE priority_type__c. That field is un-prefixed, belongs to TTS
# OTCRM, and its label ("Priority Type") matches the Airtable column name
# exactly - which makes it the better label match and the wrong answer. Matching
# labels are not evidence of ownership here.
#
# "N/A" IS DELIBERATELY MAPPED TO BLANK, not added as a picklist value
# (decided 2026-08-14). It is how Airtable says the field does not apply, and a
# priority literally called "N/A" reads as data while meaning the absence of it -
# nobody filters a report for it. 157 rows load with the field empty, which is
# what "not applicable" means. This is the only entry here whose value is "".
#
# An Airtable value that is NOT in this map is DROPPED and reported, never
# passed through. The field is restricted, so an unknown value fails the WHOLE
# row - and this map going stale is the likeliest cause: Airtable was on seven
# distinct values on 2026-08-13 and five on 2026-08-14 (the two HISP ones were
# DELETED from the field) with no code change on either side. Read the
# value-review CSV.
#
# ⚠️ TO RE-CHECK THIS MAP, READ THE AIRTABLE SCHEMA, NOT THE EXPORT.
# Counting distinct values in the export only finds choices somebody has already
# used. A choice that is DEFINED but not yet selected is invisible that way, and
# the first record to use it gets silently dropped. The field's own definition is
# authoritative (needs the PAT's schema.bases:read scope):
#
#   GET https://api.airtable.com/v0/meta/bases/{baseId}/tables
#   -> .tables[name='Opportunities'].fields[name='Priority Type'].options.choices
#
# Verified that way 2026-08-14: exactly these five choices are defined, and the
# field is a singleSelect, so a row can never carry two.
$PriorityTypeMap = @{
    "Strategic"             = "Strategic"
    "High Volume"           = "High Volume"
    "IdV Upgrade"           = "IdV Upgrade"
    "Leadership Escalation" = "Leadership Escalation"
    "N/A"                   = ""
}

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

# Airtable's two identity-platform columns were linked-record fields pointing at
# a table this migration doesn't pull; they are now plain multi-selects holding
# vendor names, so they finally line up with Salesforce's two restricted
# multipicklists (25 values each, all 25 allowed on the Login_gov record type -
# checked in recordTypes/Login_gov.recordType-meta.xml, not just the field
# metadata, per the record-type lesson this object taught).
#
# Airtable offers 17 choices on Existing and 8 on Alternative; 22 of the 25
# distinct names match Salesforce exactly. Only these three don't, and every one
# of them is a Salesforce-side or cosmetic problem rather than bad Airtable data:
#
#   "Ping / Forgerock"    -> "Ping/Foregerock"      6 tags. Spacing differs AND
#                            Salesforce's value misspells the vendor (ForgeRock,
#                            which Ping Identity acquired). Mapped so the data
#                            lands now; the Salesforce value should be corrected
#                            to "Ping/Forgerock" separately, after which this
#                            entry becomes an identity mapping.
#   "Sign-in with Google" -> "Sign-In with Google"  1 tag. Capital I only.
#   "CLEAR"               -> (no Salesforce value)  2 tags. Deliberately NOT
#                            mapped onto a near-neighbour - CLEAR is a real,
#                            distinct IdV vendor and there is nothing it belongs
#                            in. The tag is dropped and flagged for review until
#                            "CLEAR" is added to both picklists (and to the
#                            Login_gov record type).
#
# Salesforce also defines 8 values Airtable no longer uses at all (Google
# CiviForm, ManTech, Granicus, Shibboleth, Exostar, Jakobsen Id, Mattr, Idemia) -
# leftovers from the old linked table. Harmless; nothing is written to them.
#
# Both fields share one map: the value sets are identical in Salesforce, and
# Alternative's 8 Airtable choices are a subset of Existing's plus CLEAR.
$IdentityPlatformMap = @{
    "None"                    = "None"
    "Homegrown (placeholder)" = "Homegrown (placeholder)"
    "AWS"                     = "AWS"
    "Socure"                  = "Socure"
    "Okta"                    = "Okta"
    "Azure"                   = "Azure"
    "Oracle AM"               = "Oracle AM"
    "Ping / Forgerock"        = "Ping/Foregerock"
    "Keycloak"                = "Keycloak"
    "LexisNexis"              = "LexisNexis"
    "1Kosmos"                 = "1Kosmos"
    "ID.me"                   = "ID.me"
    "Microsoft Power Pages"   = "Microsoft Power Pages"
    "Salesforce"              = "Salesforce"
    "Experian"                = "Experian"
    "Sign-in with Google"     = "Sign-In with Google"
    "Max.gov"                 = "Max.gov"
}

function Assert-IdentityPlatformsResolved {
    <#
        Fails the run if the Airtable export predates the linked-record ->
        multi-select conversion.

        A stale export carries rec... IDs in these two columns. Those match
        nothing in $IdentityPlatformMap, so without this check the run would
        "succeed" while dropping all 453 tags into the value-review CSV as
        unmapped junk - the failure mode would look like a data-quality problem
        in Airtable rather than an out-of-date file on disk. Re-pulling is the
        fix, so say so.
    #>
    param([object[]]$Rows)

    $Stale = 0
    foreach ($Row in $Rows) {
        foreach ($Field in @("Existing Identity Platforms", "Alternative Identity Platforms")) {
            foreach ($Value in @($Row.fields.$Field)) {
                if ("$Value" -match '^rec[A-Za-z0-9]{14}$') { $Stale++ }
            }
        }
    }

    if ($Stale -gt 0) {
        throw ("$Stale identity-platform values are still Airtable rec... IDs, so this export " +
            "predates the linked-record -> multi-select conversion of 'Existing Identity Platforms' " +
            "and 'Alternative Identity Platforms'. Re-pull before building: " +
            "powershell-scripts/Get-AirtableExport.ps1 -Tables Opportunities")
    }
}

function Resolve-IdentityPlatforms {
    <#
        Maps one identity-platform multi-select to its Salesforce multipicklist
        string. Unmapped tags are dropped and flagged rather than passed through
        - both target fields are restricted, so an unknown value fails the whole
        ROW at the Bulk API, not just the field.
    #>
    # NOTE: no [Parameter(Mandatory)] on $ReviewList, matching
    # Resolve-OpportunityUrl above. Mandatory implies ValidateNotNullOrEmpty on a
    # collection, so an empty List - which is exactly its state on the first row -
    # fails to bind.
    param(
        $Value,
        [string]$AirtableField,
        [string]$RecordId,
        [System.Collections.Generic.List[object]]$ReviewList
    )

    $Tags = [System.Collections.Generic.List[string]]::new()

    foreach ($Element in @($Value)) {
        if (-not $Element) { continue }
        $Key = "$Element".Trim()
        if (-not $Key) { continue }

        if ($IdentityPlatformMap.ContainsKey($Key)) {
            if (-not $Tags.Contains($IdentityPlatformMap[$Key])) {
                $Tags.Add($IdentityPlatformMap[$Key])
            }
        }
        else {
            $script:DroppedIdentityPlatformCount++
            $ReviewList.Add([PSCustomObject]@{
                AirtableRecordId = $RecordId
                Field            = $AirtableField
                OriginalValue    = $Key
                AppliedValue     = ""
                Reason           = "No matching value in the restricted picklist - tag dropped. Add it in Salesforce (field AND the Login_gov record type) to migrate it."
            })
        }
    }

    return ($Tags -join ";")
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
    -Soql ("SELECT LDGCRM_External_ID__c FROM Account WHERE LDGCRM_External_ID__c != null") `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

$LoadedAccountIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)


foreach ($Acct in $LoadedAccounts) {
    if (-not $Acct.LDGCRM_External_ID__c) { continue }
    $LoadedAccountIds.Add($Acct.LDGCRM_External_ID__c) | Out-Null

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
# The owner columns feed step 2 of the owner chain - see the OWNER CHAIN block
# at the output row. Same eligibility test as everywhere else: active AND a
# UserType that can actually hold a record.
$LoadedPartnerAccounts = @(Invoke-SalesforceQuery `
    -Soql ("SELECT LDGCRM_External_ID__c, LDGCRM_Partner_Account_Owner__c, " +
           "LDGCRM_Partner_Account_Owner__r.IsActive, " +
           "LDGCRM_Partner_Account_Owner__r.UserType " +
           "FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null") `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
$LoadedPartnerAccountIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$PartnerAccountOwnerById = @{}
foreach ($Pa in $LoadedPartnerAccounts) {
    if ($Pa.LDGCRM_External_ID__c) {
        $LoadedPartnerAccountIds.Add($Pa.LDGCRM_External_ID__c) | Out-Null

        if ($Pa.LDGCRM_Partner_Account_Owner__c -and
            $Pa.LDGCRM_Partner_Account_Owner__r.IsActive -and
            $Pa.LDGCRM_Partner_Account_Owner__r.UserType -eq "Standard") {
            $PartnerAccountOwnerById[$Pa.LDGCRM_External_ID__c] = $Pa.LDGCRM_Partner_Account_Owner__c
        }
    }
}
Write-Host "$($LoadedPartnerAccountIds.Count) Partner Accounts present in $OrgAlias."

# --- Record owner: "Pod Opportunity Lead" -> OwnerId ---
# Always a scalar collaborator object here (verified: 0 of 826 rows carry more
# than one), so no array unwrap is needed - unlike Application's Service Level,
# which looked scalar and was a 1-element array. Checked rather than assumed.
Write-Host ""
Write-Host "Resolving Pod Opportunity Lead emails to Salesforce Users..." -ForegroundColor Cyan
$LeadEmails = @($AirtableOpportunities |
    ForEach-Object { $_.fields.'Pod Opportunity Lead'.email } |
    Where-Object { $_ })

$FallbackOwnerId = Resolve-FallbackOwnerId -Email $FallbackOwnerEmail -OrgAlias $OrgAlias -ApiVersion $ApiVersion
Write-Host "Fallback owner ($FallbackOwnerEmail) resolves to $FallbackOwnerId."

$OwnerLookup = Resolve-SalesforceOwnerIds -Emails $LeadEmails -OrgAlias $OrgAlias -ApiVersion $ApiVersion
$DistinctLeads = @($LeadEmails | ForEach-Object { $_.ToLower() } | Sort-Object -Unique)
Write-Host "$($OwnerLookup.IdByEmail.Count) of $($DistinctLeads.Count) distinct leads resolve to an active User."

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()
$ValueReviewRows = [System.Collections.Generic.List[object]]::new()
$CloseDateFallbackRows = [System.Collections.Generic.List[object]]::new()

# Which of the three owner steps each row ended up on, keyed by Airtable record
# Id. Kept beside the rows rather than on them: OwnerSource is a diagnostic, and
# anything added to the output row becomes a column in the CSV sent to
# Salesforce. Counted at summary time from the rows that actually survived, so
# a row skipped after its owner was resolved is not counted.
$OwnerSourceByRecId = @{}
$UnresolvedOwnerRows = [System.Collections.Generic.List[object]]::new()
$DroppedDemographicCount = 0
$DroppedIdentityPlatformCount = 0
$UnresolvedPartnerAccountCount = 0

Assert-IdentityPlatformsResolved -Rows @($AirtableOpportunities)

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
            Reason           = "Linked Account $AccountId is not reconciled in $OrgAlias (duplicate/unmatched Airtable Account - see docs/TROUBLESHOOTING.md). Would fail the load with INVALID_FIELD - skipped."
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

    # --- Identity platforms: two multi-selects -> two restricted multipicklists ---
    $ExistingPlatforms = Resolve-IdentityPlatforms -Value $Row.fields.'Existing Identity Platforms' `
        -AirtableField "Existing Identity Platforms" -RecordId $RecId -ReviewList $ValueReviewRows
    $AlternativePlatforms = Resolve-IdentityPlatforms -Value $Row.fields.'Alternative Identity Platforms' `
        -AirtableField "Alternative Identity Platforms" -RecordId $RecId -ReviewList $ValueReviewRows

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

    # --- OWNER CHAIN: three steps, in order (business rule 2026-08-14) ---
    #   1. Airtable's "Pod Opportunity Lead", if it matches one ACTIVE User.
    #   2. Otherwise this Opportunity's PARTNER ACCOUNT owner, where it has one.
    #   3. Otherwise the named fallback owner.
    #
    # ⚠️ Step 2 rarely fires, and that is expected rather than a bug. Only ~80 of
    # 842 Opportunities carry a Partner Account at all: the link is authored only
    # via Applications, and the Partner Accounts table's "Opportunities" column
    # that looks like a richer source is a rollup of the parent Account's
    # Opportunities, not a real link. So most unresolved owners go straight to
    # the fallback.
    #
    # An earlier draft of this rule inherited the parent ACCOUNT's owner instead.
    # That was dropped (project owner, 2026-08-14): Airtable has no Account owner
    # to migrate - the field lives on the Partners table, reaches only 68 of 747
    # Account rows, and half of those name someone with no Salesforce login - so
    # it would have meant writing OwnerId onto production Accounts this migration
    # otherwise never touches, to move 5.5% of them. Account ownership is changed
    # by hand, outside this pipeline.
    #
    # The fallback is written EXPLICITLY, not left blank. A blank OwnerId makes
    # Salesforce assign the record to whoever ran the load, which stopped being
    # the right owner once GSA IT Operations took over running this in
    # production - see Resolve-FallbackOwnerId for the full reasoning and the
    # re-run trade-off it costs.
    $OwnerId = $FallbackOwnerId
    $OwnerSource = "Fallback"
    $LeadEmail = $Row.fields.'Pod Opportunity Lead'.email
    $LeadResolved = $false

    if ($LeadEmail) {
        $LeadKey = "$LeadEmail".Trim().ToLower()
        if ($OwnerLookup.IdByEmail.ContainsKey($LeadKey)) {
            $OwnerId = $OwnerLookup.IdByEmail[$LeadKey]
            $OwnerSource = "PodOpportunityLead"
            $LeadResolved = $true
        }
    }

    if (-not $LeadResolved) {
        # Step 2. Inherit from this Opportunity's Partner Account, if it has one.
        if ($PartnerAccountId -and $PartnerAccountOwnerById.ContainsKey($PartnerAccountId)) {
            $OwnerId = $PartnerAccountOwnerById[$PartnerAccountId]
            $OwnerSource = "PartnerAccountOwner"
        }

        # Reported whenever Airtable named someone we could not use, even if the
        # Account rescued the row - the missing login is still the thing to fix,
        # and inheriting quietly would hide how many are affected.
        if ($LeadEmail) {
            $LeadKey = "$LeadEmail".Trim().ToLower()
            $UnresolvedOwnerRows.Add([PSCustomObject]@{
                AirtableRecordId = $RecId
                OpportunityName  = $Name
                OwnerEmail       = $LeadEmail
                ResolvedTo       = $OwnerSource
                Reason           = if ($OwnerLookup.Ambiguous -contains $LeadKey) {
                    "More than one ACTIVE Salesforce User has this email - not guessed at. Owner falls back to $OwnerSource."
                } else {
                    "No active Salesforce User has this email (checked with and without the sandbox '.invalid' suffix). Owner falls back to $OwnerSource."
                }
            })
        }
    }

    $OwnerSourceByRecId[$RecId] = $OwnerSource

    # --- Priority Type -> LDGCRM_Level_of_Priority__c (restricted picklist) ---
    # Unmapped values are dropped and reported rather than passed through: the
    # field is restricted, so one unknown value fails the entire row.
    $LevelOfPriority = ""
    $RawPriority = @($Row.fields.'Priority Type') | Select-Object -First 1

    if (-not [string]::IsNullOrWhiteSpace($RawPriority)) {
        $PriorityKey = "$RawPriority".Trim()
        if ($PriorityTypeMap.ContainsKey($PriorityKey)) {
            $LevelOfPriority = $PriorityTypeMap[$PriorityKey]
        }
        else {
            # Property set MUST match the other $ValueReviewRows entries -
            # Export-Csv takes its header from the first object only, so a row
            # with different properties silently loses columns for every row.
            $ValueReviewRows.Add([PSCustomObject]@{
                AirtableRecordId = $RecId
                Field            = "Priority Type"
                OriginalValue    = $RawPriority
                AppliedValue     = ""
                Reason           = "No matching value in LDGCRM_Level_of_Priority__c's restricted picklist - dropped rather than failing the whole row. Add it to `$PriorityTypeMap once the Salesforce value exists on the field AND on the Login_gov record type."
            })
        }
    }

    $OutputRow = [ordered]@{
        LDGCRM_External_ID__c                      = $RecId
        OwnerId                                     = $OwnerId
        Name                                        = $Name
        RecordTypeId                                = $LoginGovRecordTypeId
        StageName                                   = $Status
        CloseDate                                   = $CloseDate
        "Account.LDGCRM_External_ID__c"             = $AccountId
        "LDGCRM_Partner_Account__r.LDGCRM_External_ID__c" = $PartnerAccountId
        LDGCRM_Level_of_Priority__c                 = $LevelOfPriority
        LDGCRM_Opportunity_Type__c                  = $Row.fields.'Opportunity Type'
        LDGCRM_Focus_Level__c                       = $FocusLevel
        LDGCRM_Likely_Service_Level_Needed__c       = $Row.fields.'Likely Service Level Needed'
        LDGCRM_Technical_Readiness__c               = $TechnicalReadiness
        LDGCRM_Estimate_Source__c                   = $Row.fields.'Estimate source'
        LDGCRM_Demographic_Served__c                = ($DemographicTags -join ";")
        LDGCRM_Existing_Identity_Platforms__c       = $ExistingPlatforms
        LDGCRM_Alternative_Identity_Platforms__c    = $AlternativePlatforms
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
        # NOTE THE API NAME: "Tehnical", not "Technical". The typo is in the
        # Salesforce field, not here - its LABEL reads "Technical Checklist URL"
        # correctly, which is exactly what makes it easy to "fix" by hand and
        # break the load. The field was renamed on 2026-08-14 from LDGRM_ to
        # LDGCRM_ (the PREFIX was wrong, so it read as another app's field);
        # the misspelling in the body was not corrected at the same time.
        LDGCRM_Tehnical_Checklist_URL__c            = (Resolve-OpportunityUrl -Value $Row.fields.'Technical Checklist URL' -AirtableField "Technical Checklist URL" -RecordId $RecId -ReviewList $ValueReviewRows)
    }

    $UpsertRows.Add([PSCustomObject]$OutputRow)
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "Opportunity-upsert.csv"
$SkippedFile = Join-Path $LogDir "Opportunity-skipped-$Timestamp.csv"
$ValueReviewFile = Join-Path $LogDir "Opportunity-value-review-$Timestamp.csv"
$CloseDateFile = Join-Path $LogDir "Opportunity-closedate-fallback-$Timestamp.csv"
$UnresolvedOwnerFile = Join-Path $LogDir "Opportunity-unresolved-owner-$Timestamp.csv"

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
if ($UnresolvedOwnerRows.Count -gt 0) {
    $UnresolvedOwnerRows | Export-Csv -LiteralPath $UnresolvedOwnerFile -NoTypeInformation -Encoding UTF8
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
# Compare against the fallback Id, not "is OwnerId set" - every row carries one
# now, so a truthiness test would report every record as owner-resolved.
# Counted by which STEP resolved the owner, not by comparing against the
# fallback Id. Once an unresolved lead can inherit the Account's owner, "not the
# fallback Id" no longer means "came from Airtable" - it would silently fold the
# inherited ones in with the authored ones.
$OwnerStepCounts = @{ PodOpportunityLead = 0; PartnerAccountOwner = 0; Fallback = 0 }
foreach ($Row in $UpsertRows) {
    $Src = $OwnerSourceByRecId[$Row.LDGCRM_External_ID__c]
    if ($Src -and $OwnerStepCounts.ContainsKey($Src)) { $OwnerStepCounts[$Src]++ }
}

Write-Host ("{0,-50} {1,8:N0}" -f "Owner set from Pod Opportunity Lead", $OwnerStepCounts.PodOpportunityLead)
Write-Host ("{0,-50} {1,8:N0}" -f "Owner inherited from the Partner Account", $OwnerStepCounts.PartnerAccountOwner)
Write-Host ("{0,-50} {1,8:N0}" -f "Owner = fallback ($FallbackOwnerEmail)", $OwnerStepCounts.Fallback)
Write-Host ("{0,-50} {1,8:N0}" -f "CloseDate came from a fallback field", $CloseDateFallbackRows.Count)
Write-Host ("{0,-50} {1,8:N0}" -f "Demographic tags dropped (unmapped)", $DroppedDemographicCount)
Write-Host ("{0,-50} {1,8:N0}" -f "Existing Identity Platforms populated", @($UpsertRows | Where-Object { $_.LDGCRM_Existing_Identity_Platforms__c }).Count)
Write-Host ("{0,-50} {1,8:N0}" -f "Alternative Identity Platforms populated", @($UpsertRows | Where-Object { $_.LDGCRM_Alternative_Identity_Platforms__c }).Count)
Write-Host ("{0,-50} {1,8:N0}" -f "Identity platform tags dropped (unmapped)", $DroppedIdentityPlatformCount)
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
if ($UnresolvedOwnerRows.Count -gt 0) {
    Write-Host "Owners with no active Salesforce User (fell back):" -ForegroundColor Yellow
    Write-Host $UnresolvedOwnerFile
}

}
finally {
    Stop-ScriptLog
}
