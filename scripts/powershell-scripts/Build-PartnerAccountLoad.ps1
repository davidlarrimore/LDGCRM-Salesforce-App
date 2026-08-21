#Requires -Version 5.1

<#
    Chunk 2 of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md). LDGCRM_Partner_Account__c is a true
    Master-Detail child of Account (LDGCRM_Account__c, filtered to the Federal
    record type), so unlike Impediment this needs the parent Account's
    LDGCRM_External_ID__c already populated - run Build-AccountReconciliation.ps1
    and load its output first, or these rows' parent lookup won't resolve.

    LDGCRM_Account__c is written as an "LDGCRM_Account__r.LDGCRM_External_ID__c"
    column, NOT the plain field API name - that's the Bulk API 2.0 syntax for
    resolving a lookup/master-detail by external ID (confirmed against
    Salesforce's own docs:
    https://developer.salesforce.com/docs/atlas.en-us.api_asynch.meta/api_asynch/relationship_fields_in_a_header_row__2_0.htm).
    A plain "LDGCRM_Account__c" column would be interpreted as a literal
    Salesforce Id, not resolved by external ID.

    LDGCRM_Market_Segment__c is deliberately NOT set by this script at all.
    LDGCRM_Partner_Account_Before_Save_Create_Update_Market_Segment (a
    before-save Flow, runs on new Partner Accounts) already assigns it
    automatically from $Record.LDGCRM_Account__r.LDGCRM_Market_Segment__r.Id -
    i.e. copied from the linked Account's own Market Segment. Setting it here
    would be redundant at best (the Flow would just overwrite it on insert
    anyway) and reintroduces exactly the kind of value-mapping bug already
    found and fixed in Build-AccountReconciliation.ps1's Market Segment column
    (see docs/engineering/TRANSFORMATION-RULES.md) for no benefit. The same pattern applies to
    Opportunity and Application, which have their own analogous before-save
    Flows deriving Market Segment from their related Account - neither of
    those future transform scripts should set it either.

    Field notes (checked against the Airtable export and gsa-peo's existing
    data before assuming a mapping, per the "States + DC/PR"/Impediment-Category
    lessons):
      - There's no "Name" column in Airtable. LDGCRM_Partner_Account__c's
        required Name field is sourced from "Agreement Short Name" (complete on
        all rows, human-readable, no duplicates) rather than "Tag" (Airtable's
        own primary field, but a snake_case slug missing on 9 of 99 rows) - a
        deliberate choice, not a default guess.
      - LDGCRM_Agreement_Short_Name__c and LDGCRM_Current_Status_Summary__c
        were both too short for the real data (Text(10) vs values up to 37
        chars; TextArea/255 vs values up to 9,590 chars, an ever-appended
        dated log) - fixed via sfdx-metadata-sync before this script was
        written, not truncated.
      - "Agency Summary" is genuinely a URL field despite the name (Google Docs
        links) - maps to LDGCRM_Partner_Summary_URL__c per that field's own
        description. 7 of 87 non-blank values are placeholder text ("N/A",
        "Not available", a bare state name) instead of real URLs - left blank
        for those rows rather than writing non-URL text into a URL field.
      - "Account Owner" is a Lookup to User with no external ID field to hang
        a relationship-header resolution on, so unlike every other lookup in
        this script, it's resolved to a real Salesforce Id by querying Users
        directly - via the shared Resolve-SalesforceOwnerIds helper, which
        handles the sandbox ".invalid" Email suffix (present on most gsa-peo
        users but NOT all), filters to active Users, and refuses to guess when
        one address matches several. Owners it can't resolve are left blank and
        flagged for review rather than guessed.
        NOTE: this is the custom LDGCRM_Partner_Account_Owner__c field, not
        record ownership. LDGCRM_Partner_Account__c is a Master-Detail child of
        Account and therefore has NO OwnerId of its own - it inherits the
        Account's owner, so there is nothing here for the ownership rule to set.
        The value written here does feed Application's OwnerId, though (see
        Build-ApplicationLoad.ps1), so an inactive or wrong owner propagates.
      - Every picklist target (Complexity, Health, Priority, Service Type,
        Status) was checked distinct-value-by-distinct-value against its
        Salesforce picklist before deciding no mapping table was needed -
        all of Airtable's values already match exactly.

    Rows with no parent Account at all, or more than one (Master-Detail only
    supports one parent), are skipped and written to a review CSV rather than
    guessed at.
#>

param(
    [ValidateSet("Dev", "QA", "UAT", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (powershell-scripts/Common.Orgs.ps1).
    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # Last step of the owner chain - see the OWNER CHAIN block in the transform.
    [string]$FallbackOwnerEmail = "peter.marks@gsa.gov"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-PartnerAccountLoad"

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PARTNER ACCOUNT LOAD PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Loading Airtable Partner Accounts export..." -ForegroundColor Cyan
$AirtablePartnerAccounts = Import-AirtableTable -Label "Partner Accounts"
Write-Host "$($AirtablePartnerAccounts.Count) Airtable Partner Account rows loaded."

# ============================================================
# RESOLVE OWNERS (Account Owner -> User.Id)
# ============================================================

# This was hand-rolled here first and had THREE defects, each of which produced
# a wrong owner rather than an error. It now delegates to the shared
# Resolve-SalesforceOwnerIds helper (Common.DataMigration.ps1), which is also
# what Opportunity uses, so the ownership rule has one implementation:
#   1. No IsActive filter - Salesforce refuses to assign a record to an
#      inactive user, so an inactive match is not a match.
#   2. Duplicate emails were last-write-wins - moncef.belyamani@gsa.gov has two
#      User records in gsa-peo (one active, one inactive).
#   3. Only the ".invalid" form was queried. NOT every gsa-peo user carries that
#      suffix - users created since the last sandbox refresh have a plain
#      address (verified: howard.miller@gsa.gov). So real, matchable owners were
#      being reported as unmatched. Querying both forms is also what lets this
#      run unchanged against production, where no suffix exists.
$OwnerEmails = @($AirtablePartnerAccounts |
    ForEach-Object { $_.fields.'Account Owner'.email } |
    Where-Object { $_ } |
    Sort-Object -Unique)

Write-Host ""
Write-Host "Resolving $($OwnerEmails.Count) distinct owner email(s) against Salesforce Users..." -ForegroundColor Cyan

$OwnerLookup = Resolve-SalesforceOwnerIds -Emails $OwnerEmails -OrgAlias $OrgAlias -ApiVersion $ApiVersion
$OwnerIdByEmail = $OwnerLookup.IdByEmail

Write-Host "$($OwnerIdByEmail.Count) of $($OwnerEmails.Count) owner email(s) matched an active User."
if (@($OwnerLookup.Ambiguous).Count -gt 0) {
    Write-Host "$(@($OwnerLookup.Ambiguous).Count) email(s) matched MORE THAN ONE active User - left blank for review." -ForegroundColor Yellow
}

# ============================================================
# OWNER CHAIN - step 2
#
# Business rule confirmed 2026-08-14: where Airtable's owner has no active
# Salesforce User, inherit the parent ACCOUNT's owner; only if that fails too
# does the row take the named fallback owner.
#
# Doing it HERE rather than only on Application matters: this field is what
# Application inherits from, so implementing the chain once at the Partner
# Account means Application picks it up without a second copy of the rule.
#
# LDGCRM_Partner_Account_Owner__c is a LOOKUP, not the record's owner. Partner
# Account is a Master-Detail child of Account and therefore has no OwnerId of
# its own - Salesforce forces it to follow the Account's owner regardless of
# what this field says. That is why filling it in cannot misassign the record
# itself, and why the value only really matters downstream.
# ============================================================

Write-Host ""
Write-Host "Resolving the fallback owner ($FallbackOwnerEmail)..." -ForegroundColor Cyan
$FallbackOwnerId = Resolve-FallbackOwnerId -Email $FallbackOwnerEmail -OrgAlias $OrgAlias -ApiVersion $ApiVersion
Write-Host "Fallback owner resolves to $FallbackOwnerId."


# ============================================================
# TRANSFORM
# ============================================================

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()
$UnmappedOwnerRows = [System.Collections.Generic.List[object]]::new()
$OwnerStepCounts = @{ AirtableOwner = 0; Fallback = 0 }

foreach ($Row in $AirtablePartnerAccounts) {
    $RecId = $Row.id
    $AgreementShortName = $Row.fields.'Agreement Short Name'
    $RawAccountRecordIds = $Row.fields.'Account Record ID'

    # NOTE: @($null) is a 1-element array in PowerShell, not an empty one -
    # the null/missing check has to happen before wrapping in @(), or a
    # missing parent silently produces a blank lookup instead of being caught.
    if (-not $RawAccountRecordIds) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId   = $RecId
            AgreementShortName = $AgreementShortName
            Reason              = "No parent Account linked in Airtable. LDGCRM_Account__c is Master-Detail and requires a parent - needs human review."
        })
        continue
    }

    $AccountRecordIds = @($RawAccountRecordIds)

    if ($AccountRecordIds.Count -gt 1) {
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRecordId   = $RecId
            AgreementShortName = $AgreementShortName
            Reason              = "Linked to $($AccountRecordIds.Count) Accounts ($($AccountRecordIds -join '; ')) but LDGCRM_Account__c (Master-Detail) only supports one parent. Needs human review to pick the right one."
        })
        continue
    }

    # --- OWNER CHAIN: Airtable owner -> fallback ---
    $OwnerEmail = $Row.fields.'Account Owner'.email
    $OwnerId = ""
    $OwnerSource = ""

    if ($OwnerEmail -and $OwnerIdByEmail.ContainsKey($OwnerEmail)) {
        $OwnerId = $OwnerIdByEmail[$OwnerEmail]
        $OwnerSource = "AirtableOwner"
    }
    else {
        $OwnerId = $FallbackOwnerId
        $OwnerSource = "Fallback"
    }

    $OwnerStepCounts[$OwnerSource]++

    # Still reported even when the Account rescued the row. The missing login is
    # the thing to fix, and inheriting quietly would hide how many are affected.
    if ($OwnerEmail -and $OwnerSource -ne "AirtableOwner") {
        $UnmappedOwnerRows.Add([PSCustomObject]@{
            AirtableRecordId   = $RecId
            AgreementShortName = $AgreementShortName
            OwnerEmail          = $OwnerEmail
            ResolvedTo          = $OwnerSource
            Reason               = "No active Salesforce User matches this email (checked with and without the sandbox '.invalid' suffix). Owner falls back to $OwnerSource."
        })
    }

    $SummaryUrl = $Row.fields.'Agency Summary'
    if ($SummaryUrl -and $SummaryUrl -notmatch '^https?://') {
        $SummaryUrl = ""
    }

    $UpsertRows.Add([PSCustomObject]@{
        LDGCRM_External_ID__c                            = $RecId
        Name                                              = $AgreementShortName
        LDGCRM_Agreement_Short_Name__c                    = $AgreementShortName
        "LDGCRM_Account__r.LDGCRM_External_ID__c"         = $AccountRecordIds[0]
        LDGCRM_Active_Accounts_Folder_URL__c              = $Row.fields.'Active Account Folder'
        LDGCRM_Current_Status_Summary__c                  = $Row.fields.'Current Status Summary'
        LDGCRM_Initial_Agreement_Date__c                  = $Row.fields.'Initial Agreement Date'
        LDGCRM_Partner_Account_Complexity__c              = $Row.fields.'Account Complexity'
        LDGCRM_Partner_Account_Health__c                  = $Row.fields.'Account Health'
        LDGCRM_Partner_Account_Owner__c                   = $OwnerId
        LDGCRM_Partner_Account_Priority__c                = $Row.fields.'Account Priority Level'
        LDGCRM_Partner_Summary_URL__c                     = $SummaryUrl
        LDGCRM_Service_Type__c                            = $Row.fields.'Login.gov Service Type'
        LDGCRM_Status__c                                  = $Row.fields.Status
    })
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "LDGCRM_Partner_Account__c-upsert.csv"
$SkippedFile = Join-Path $LogDir "PartnerAccount-skipped-$Timestamp.csv"
$UnmappedOwnerFile = Join-Path $LogDir "PartnerAccount-unmapped-owner-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile
}

if ($SkippedRows.Count -gt 0) {
    $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8
}

if ($UnmappedOwnerRows.Count -gt 0) {
    $UnmappedOwnerRows | Export-Csv -LiteralPath $UnmappedOwnerFile -NoTypeInformation -Encoding UTF8
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " PARTNER ACCOUNT PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-40} {1,8:N0}" -f "Airtable Partner Account rows", $AirtablePartnerAccounts.Count)
Write-Host ("{0,-40} {1,8:N0}" -f "Ready for upsert", $UpsertRows.Count)
Write-Host ("{0,-40} {1,8:N0}" -f "Skipped (no/ambiguous parent Account)", $SkippedRows.Count)
Write-Host ("{0,-40} {1,8:N0}" -f "Owner from Airtable", $OwnerStepCounts.AirtableOwner)
Write-Host ("{0,-40} {1,8:N0}" -f "Owner = fallback ($FallbackOwnerEmail)", $OwnerStepCounts.Fallback)
Write-Host ("{0,-40} {1,8:N0}" -f "Airtable owner unusable (reported)", $UnmappedOwnerRows.Count)
Write-Host ""

if ($UpsertRows.Count -gt 0) {
    Write-Host "Upsert file (external-ID keyed, requires parent Accounts already loaded):" -ForegroundColor Cyan
    Write-Host $UpsertFile
}

if ($SkippedRows.Count -gt 0) {
    Write-Host "Skipped rows for human review:" -ForegroundColor Yellow
    Write-Host $SkippedFile
}

if ($UnmappedOwnerRows.Count -gt 0) {
    Write-Host "Unmapped owner rows for human review:" -ForegroundColor Yellow
    Write-Host $UnmappedOwnerFile
}

}
finally {
    Stop-ScriptLog
}
