#Requires -Version 5.1

<#
    Chunk 2 of the Airtable -> Salesforce data-migration pipeline (see
    scripts/data-migration/README.md). LDGCRM_Partner_Account__c is a true
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
    (see TRANSFORMATION-RULES.md) for no benefit. The same pattern applies to
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
        directly. Airtable's owner emails match real User records once
        gsa-peo's sandbox-standard ".invalid" Email suffix is accounted for
        (e.g. "gabriel.yunusa@gsa.gov" -> "gabriel.yunusa@gsa.gov.invalid").
        2 of 7 distinct owner emails in this export match no User at all -
        left blank and flagged for review rather than guessed.
      - Every picklist target (Complexity, Health, Priority, Service Type,
        Status) was checked distinct-value-by-distinct-value against its
        Salesforce picklist before deciding no mapping table was needed -
        all of Airtable's values already match exactly.

    Rows with no parent Account at all, or more than one (Master-Detail only
    supports one parent), are skipped and written to a review CSV rather than
    guessed at.
#>

param(
    [string]$OrgAlias = "gsa-peo",
    [string]$ApiVersion = "67.0"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-PartnerAccountLoad"

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PARTNER ACCOUNT LOAD PREP (Airtable -> gsa-peo)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Loading Airtable Partner Accounts export..." -ForegroundColor Cyan
$AirtablePartnerAccounts = Import-AirtableTable -Label "Partner Accounts"
Write-Host "$($AirtablePartnerAccounts.Count) Airtable Partner Account rows loaded."

# ============================================================
# RESOLVE OWNERS (Account Owner -> User.Id)
# ============================================================

$OwnerEmails = @($AirtablePartnerAccounts |
    ForEach-Object { $_.fields.'Account Owner'.email } |
    Where-Object { $_ } |
    Sort-Object -Unique)

$OwnerIdByEmail = @{}

if ($OwnerEmails.Count -gt 0) {
    Write-Host ""
    Write-Host "Resolving $($OwnerEmails.Count) distinct owner email(s) against Salesforce Users..." -ForegroundColor Cyan

    $SandboxEmails = $OwnerEmails | ForEach-Object { "'$($_ + '.invalid')'" }
    $Soql = "SELECT Id, Email FROM User WHERE Email IN (" + ($SandboxEmails -join ",") + ")"
    $UserRecords = Invoke-SalesforceQuery -Soql $Soql -OrgAlias $OrgAlias -ApiVersion $ApiVersion

    foreach ($UserRecord in $UserRecords) {
        # Strip the sandbox-standard ".invalid" suffix to get back the plain
        # email Airtable stores, so it can be used as the lookup key below.
        $PlainEmail = $UserRecord.Email -replace '\.invalid$', ''
        $OwnerIdByEmail[$PlainEmail] = $UserRecord.Id
    }

    Write-Host "$($OwnerIdByEmail.Count) of $($OwnerEmails.Count) owner email(s) matched an active User."
}

# ============================================================
# TRANSFORM
# ============================================================

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()
$UnmappedOwnerRows = [System.Collections.Generic.List[object]]::new()

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

    $OwnerEmail = $Row.fields.'Account Owner'.email
    $OwnerId = ""

    if ($OwnerEmail) {
        if ($OwnerIdByEmail.ContainsKey($OwnerEmail)) {
            $OwnerId = $OwnerIdByEmail[$OwnerEmail]
        }
        else {
            $UnmappedOwnerRows.Add([PSCustomObject]@{
                AirtableRecordId   = $RecId
                AgreementShortName = $AgreementShortName
                OwnerEmail          = $OwnerEmail
                Reason               = "No active Salesforce User matches this email (checked with and without the sandbox '.invalid' suffix). Owner left blank - needs human review."
            })
        }
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
Write-Host ("{0,-40} {1,8:N0}" -f "Unmapped owner (included, blank)", $UnmappedOwnerRows.Count)
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
