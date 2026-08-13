#Requires -Version 5.1

<#
    Chunk 2 of the Airtable -> Salesforce data-migration pipeline (see
    docs/README.md). Full field-by-field reasoning lives in
    docs/TRANSFORMATION-RULES.md's Contact section.

    Contact is an independent parent - nothing has to be loaded before it -
    but it does carry optional lookups to Account and LDGCRM_Partner_Account__c,
    so it queries gsa-peo for what exists and blanks (never guesses) a lookup
    it can't resolve. Blanking rather than skipping is right here because
    neither lookup is required.

    TWO THINGS MAKE THIS OBJECT DIFFERENT FROM EVERY OTHER CHUNK:

    1. ROWS ARE MERGED, NOT 1:1. Airtable has no person-to-Application
       junction, so the same human is entered once per association: one row
       carries their name and roles, the rest are stubs with a blank Name and a
       different Applications list (47 of 61 duplicate-email groups differ
       exactly there). Salesforce HAS that junction, so rows sharing an email
       collapse into one Contact via Get-AirtableContactGroups in
       Common.DataMigration.ps1. That grouping is shared, not local, because
       the Application-Contact junction chunk must map EVERY Airtable Contact
       record ID onto whichever Contact was actually created - two
       implementations could drift.

    2. LastName IS REQUIRED BUT MOSTLY ABSENT. Only 491 of 1,599 rows have a
       Name at all. The waterfall, user-confirmed 2026-08-13:
         a. Airtable Name on the row (or on a merged sibling - merging alone
            recovers 34).
         b. FirstName/LastName from an existing Salesforce Contact matched on
            email. Recovers ~nothing in gsa-peo today (3 Contacts exist) but is
            the behaviour production needs, where real Contacts already exist.
         c. The email address itself as LastName - deliberately ugly so it is
            obvious in the UI which records still need a real name.
       Every row that lands on (b) or (c) is written to a review CSV, and the
       whole issue is written up for the data owners: a large share of these
       are service/shared mailboxes that arguably shouldn't be Contacts at all.

    Fields NOT written, deliberately:
      - Source_Detail_Formula__c: the object's only formula field.
      - Roles: these describe a person's relationship to an Application, so
        they belong on LDGCRM_Application_Contact__c, not here (see CLAUDE.md).
      - No Flow, trigger or validation rule exists on Contact in this org, so
        unlike Opportunity/Partner Account there is no Flow-owned field to
        avoid.
#>

param(
    [string]$OrgAlias = "gsa-peo",
    [string]$ApiVersion = "67.0"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-ContactLoad"

# LDGCRM_Subscription_Type__c is a restricted multiselect allowing only
# "Newsletter Recipient" and "Technical POC". Airtable's dominant value
# "Technical Emails" (716 rows) matches neither. It is NOT auto-mapped onto
# "Technical POC": a subscription preference and a role are different concepts,
# and guessing would silently invent role data. Unmapped values are dropped and
# logged for a human decision.
$SubscriptionTypeMap = @{
    "Newsletter Recipient" = "Newsletter Recipient"
    "Technical POC"        = "Technical POC"
}

function Split-ContactName {
    <#
        Airtable stores a single "Name" string. Salesforce needs FirstName
        (optional, 40) and LastName (required, 80). Splitting on the LAST
        space keeps multi-word surnames intact ("Krishna-Priya Mandala" ->
        Krishna-Priya / Mandala) and handles the 12 single-token names by
        putting everything in LastName, which is the safe side: LastName is
        the required one.
    #>
    param([string]$FullName)

    $Clean = ($FullName -replace '\s+', ' ').Trim()
    if (-not $Clean) { return @{ First = ""; Last = "" } }

    $LastSpace = $Clean.LastIndexOf(' ')
    if ($LastSpace -lt 1) { return @{ First = ""; Last = $Clean } }

    return @{
        First = $Clean.Substring(0, $LastSpace).Trim()
        Last  = $Clean.Substring($LastSpace + 1).Trim()
    }
}

function Get-FirstNonEmpty {
    <#
        Across a merged group's rows, take the first row that actually has a
        value for the field. Merging must not lose data that only one of the
        duplicate rows carried.
    #>
    param($Rows, [string]$Field)

    foreach ($Row in $Rows) {
        $Value = $Row.fields.$Field
        if ($Value -and "$Value".Trim()) { return "$Value".Trim() }
    }
    return ""
}

function Get-FirstLinkedId {
    param($Rows, [string]$Field)

    foreach ($Row in $Rows) {
        $Raw = $Row.fields.$Field
        if (-not $Raw) { continue }          # null-check BEFORE @() - @($null) is a 1-element array
        return @($Raw)[0]
    }
    return ""
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " CONTACT LOAD PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Reads Salesforce (read-only queries) - writes local files only." -ForegroundColor Yellow
Write-Host ""

$AirtableContacts = Import-AirtableTable -Label "Contacts"
Write-Host "$($AirtableContacts.Count) Airtable Contact rows loaded."

$Groups = @(Get-AirtableContactGroups -Records $AirtableContacts)
$MergedGroupCount = @($Groups | Where-Object { $_.MemberRecordIds.Count -gt 1 }).Count
$ConflictGroupCount = @($Groups | Where-Object { $_.NameConflict }).Count
Write-Host "$($Groups.Count) Contacts after merging rows that share an email."
Write-Host "  (from $MergedGroupCount merged groups; $ConflictGroupCount rows left unmerged on a name conflict)"

# --- Record types ----------------------------------------------------------
# Contact has FIVE active record types. This migration creates ONLY Federal and
# GSA contacts (user-confirmed 2026-08-13): GSA for anyone with an @gsa.gov
# address - they're GSA staff, not partner-agency contacts - and Federal for
# everyone else. The three FCIC_*/TTS_Individual record types belong to other
# apps and are never used here.
#
# Record type also silently narrows which picklist values a load may write
# (Federal exposes all 36 TTS_Office_s__c values, the others only 7) - the same
# trap that failed the first Opportunity load. This script doesn't write that
# field, but stamp the record type explicitly rather than relying on the
# loading user's default, or that becomes a live risk the moment it does.
Write-Host ""
Write-Host "Looking up the Federal and GSA Contact record types..." -ForegroundColor Cyan
$RecordTypeRows = @(Invoke-SalesforceQuery `
    -Soql "SELECT Id, DeveloperName FROM RecordType WHERE SObjectType = 'Contact' AND DeveloperName IN ('Federal','GSA')" `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
if ($RecordTypeRows.Count -ne 2) {
    throw "Expected the Federal and GSA Contact record types, found $($RecordTypeRows.Count)."
}
$FederalRecordTypeId = ($RecordTypeRows | Where-Object { $_.DeveloperName -eq 'Federal' }).Id
$GsaRecordTypeId = ($RecordTypeRows | Where-Object { $_.DeveloperName -eq 'GSA' }).Id
Write-Host "Federal: $FederalRecordTypeId   GSA: $GsaRecordTypeId"

# --- Existing Salesforce Contacts, for the name waterfall ------------------
Write-Host "Querying $OrgAlias for existing Contacts (to recover real names by email)..." -ForegroundColor Cyan
$ExistingContacts = @(Invoke-SalesforceQuery `
    -Soql "SELECT FirstName, LastName, Email FROM Contact WHERE Email != null" `
    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)
$ExistingByEmail = @{}
foreach ($Existing in $ExistingContacts) {
    $Key = "$($Existing.Email)".Trim().ToLower()
    if ($Key -and -not $ExistingByEmail.ContainsKey($Key)) { $ExistingByEmail[$Key] = $Existing }
}
Write-Host "$($ExistingByEmail.Count) existing Contacts with an email in $OrgAlias."

# --- Resolvable lookups ----------------------------------------------------
Write-Host "Querying $OrgAlias for Accounts and Partner Accounts..." -ForegroundColor Cyan
$LoadedAccountIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT LDGCRM_External_ID__c FROM Account WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) { $LoadedAccountIds.Add($Row.LDGCRM_External_ID__c) | Out-Null }
}
$LoadedPartnerAccountIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT LDGCRM_External_ID__c FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) { $LoadedPartnerAccountIds.Add($Row.LDGCRM_External_ID__c) | Out-Null }
}
Write-Host "$($LoadedAccountIds.Count) Accounts, $($LoadedPartnerAccountIds.Count) Partner Accounts available to link."

# --- Account fallback: derive via the contact's Applications ---------------
# A Contact with no AccountId is not just missing data - the unrelated FCIC
# Apex trigger (GSA_FCIC_ContactTrigger) reacts to a blank AccountId by
# creating a junk "FCIC_Individual" Account named after the person. So every
# Account link recovered here is one less polluted Account record.
#
# Airtable's Contacts.Account column covers most rows, but where it's missing
# or points at an unreconciled Account, the contact's linked Applications lead
# to the same place: Application -> Partner Account -> Account. Building those
# two hops locally is cheap and needs no extra Salesforce query.
Write-Host "Building Application -> Partner Account -> Account fallback map..." -ForegroundColor Cyan
$PartnerAccountToAccount = @{}
foreach ($Pa in (Import-AirtableTable -Label "Partner Accounts")) {
    $Raw = $Pa.fields.'Account Record ID'
    if ($Raw) { $PartnerAccountToAccount[$Pa.id] = @($Raw)[0] }
}
$ApplicationToAccount = @{}
foreach ($App in (Import-AirtableTable -Label "Applications")) {
    $Raw = $App.fields.'Partner Account Record ID (from Partner Agreement)'
    if (-not $Raw) { continue }
    $PaId = @($Raw)[0]
    if ($PartnerAccountToAccount.ContainsKey($PaId)) {
        $ApplicationToAccount[$App.id] = $PartnerAccountToAccount[$PaId]
    }
}
Write-Host "$($ApplicationToAccount.Count) Applications resolve to an Account."

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$NameReviewRows = [System.Collections.Generic.List[object]]::new()
$ValueReviewRows = [System.Collections.Generic.List[object]]::new()
$IdentityMapRows = [System.Collections.Generic.List[object]]::new()
$NameFromAirtable = 0
$NameFromExistingContact = 0
$NameFromEmail = 0
$NoNameAtAll = 0
$FederalRecordTypeCount = 0
$GsaRecordTypeCount = 0
$AccountFromApplication = 0
$NoAccountCount = 0
$AccountReviewRows = [System.Collections.Generic.List[object]]::new()

foreach ($Group in $Groups) {
    $Rows = $Group.Rows
    $Email = Get-CleanContactEmail (Get-FirstNonEmpty $Rows "Email")

    # Every member record ID maps to this Contact - the junction chunk needs
    # this to resolve its Contact references.
    foreach ($MemberId in $Group.MemberRecordIds) {
        $IdentityMapRows.Add([PSCustomObject]@{
            AirtableContactRecordId = $MemberId
            ContactExternalId       = $Group.ExternalId
            Email                   = $Email
            MergedRowCount          = $Group.MemberRecordIds.Count
        })
    }

    # --- Name waterfall ---
    $RawName = Get-FirstNonEmpty $Rows "Name"
    $FirstName = ""
    $LastName = ""

    if ($RawName) {
        $Split = Split-ContactName $RawName
        $FirstName = $Split.First
        $LastName = $Split.Last
        $NameFromAirtable++
    }
    elseif ($Email -and $ExistingByEmail.ContainsKey($Email)) {
        $Match = $ExistingByEmail[$Email]
        $FirstName = "$($Match.FirstName)".Trim()
        $LastName = "$($Match.LastName)".Trim()
        $NameFromExistingContact++
        $NameReviewRows.Add([PSCustomObject]@{
            ContactExternalId = $Group.ExternalId
            Email             = $Email
            AppliedFirstName  = $FirstName
            AppliedLastName   = $LastName
            Source            = "Existing Salesforce Contact (matched on email)"
            Reason            = "Airtable has no Name for this contact; reused the name from a Contact already in $OrgAlias with the same email."
        })
    }
    elseif ($Email) {
        # Deliberately ugly, so it's obvious in the UI which records still need
        # a real name. LastName is capped at 80; every address here is shorter,
        # but truncate defensively rather than fail the row.
        $LastName = $Email
        if ($LastName.Length -gt 80) { $LastName = $LastName.Substring(0, 80) }
        $NameFromEmail++
        $NameReviewRows.Add([PSCustomObject]@{
            ContactExternalId = $Group.ExternalId
            Email             = $Email
            AppliedFirstName  = ""
            AppliedLastName   = $LastName
            Source            = "Email address (placeholder)"
            Reason            = "No Name in Airtable and no existing Salesforce Contact with this email. LastName is required, so the address was used as a placeholder - needs a real name, or a decision on whether this is a service/shared mailbox that shouldn't be a Contact."
        })
    }
    else {
        # No name and no email - nothing to key a person on at all.
        $NoNameAtAll++
        $NameReviewRows.Add([PSCustomObject]@{
            ContactExternalId = $Group.ExternalId
            Email             = ""
            AppliedFirstName  = ""
            AppliedLastName   = ""
            Source            = "(skipped)"
            Reason            = "No Name and no Email - nothing identifies this person. Skipped; LastName is required and there is no defensible placeholder."
        })
        continue
    }

    if ($FirstName.Length -gt 40) { $FirstName = $FirstName.Substring(0, 40) }

    # --- Lookups: blank rather than guess when unresolvable ---
    $AccountId = Get-FirstLinkedId $Rows "Account"
    $AccountFromAirtableColumn = [bool]$AccountId
    if ($AccountId -and -not $LoadedAccountIds.Contains($AccountId)) { $AccountId = "" }

    if (-not $AccountId) {
        # Fall back through the contact's Applications (see the map built
        # above). Not a guess: it walks a real Application -> Partner Account
        # -> Account chain that already exists in the source data.
        foreach ($Row in $Rows) {
            $RawApps = $Row.fields.'Applications Record ID (from Applications)'
            if (-not $RawApps) { continue }
            foreach ($AppId in @($RawApps)) {
                if ($ApplicationToAccount.ContainsKey($AppId)) {
                    $Candidate = $ApplicationToAccount[$AppId]
                    if ($LoadedAccountIds.Contains($Candidate)) {
                        $AccountId = $Candidate
                        $AccountFromApplication++
                        break
                    }
                }
            }
            if ($AccountId) { break }
        }
    }

    if (-not $AccountId) {
        # Still nothing - this Contact will make the FCIC trigger spawn a junk
        # Account unless that trigger is disabled for the load.
        $NoAccountCount++
        $AccountReviewRows.Add([PSCustomObject]@{
            ContactExternalId = $Group.ExternalId
            Email             = $Email
            Reason            = if ($AccountFromAirtableColumn) {
                                    "Airtable links this contact to an Account that isn't reconciled in $OrgAlias (duplicate/unmatched Airtable Account - see docs/AIRTABLE-DATA-QUALITY-REQUESTS.md), and no linked Application resolves to one either."
                                } else {
                                    "No Account link in Airtable, and no linked Application resolves to one."
                                }
        })
    }

    $PartnerAccountId = Get-FirstLinkedId $Rows "Partner Account Record ID"
    if ($PartnerAccountId -and -not $LoadedPartnerAccountIds.Contains($PartnerAccountId)) { $PartnerAccountId = "" }

    # --- Subscription Type (restricted multiselect) ---
    $SubTags = [System.Collections.Generic.List[string]]::new()
    foreach ($Row in $Rows) {
        foreach ($Value in @($Row.fields.'Subscription Type')) {
            if (-not $Value) { continue }
            $Key = "$Value".Trim()
            if ($SubscriptionTypeMap.ContainsKey($Key)) {
                if (-not $SubTags.Contains($SubscriptionTypeMap[$Key])) { $SubTags.Add($SubscriptionTypeMap[$Key]) }
            }
            else {
                $ValueReviewRows.Add([PSCustomObject]@{
                    ContactExternalId = $Group.ExternalId
                    Field             = "Subscription Type"
                    OriginalValue     = $Key
                    AppliedValue      = ""
                    Reason            = "Not one of LDGCRM_Subscription_Type__c's 2 allowed values (Newsletter Recipient, Technical POC). Dropped rather than guessed - needs a mapping decision."
                })
            }
        }
    }

    $Title = Get-FirstNonEmpty $Rows "Title"
    if ($Title.Length -gt 128) { $Title = $Title.Substring(0, 128) }

    $Phone = Get-FirstNonEmpty $Rows "Phone"
    if ($Phone.Length -gt 40) { $Phone = $Phone.Substring(0, 40) }

    $Notes = Get-FirstNonEmpty $Rows "Notes"

    # GSA staff (@gsa.gov) get the GSA record type; every other contact is a
    # partner-agency contact and gets Federal.
    if ($Email -like '*@gsa.gov') {
        $RecordTypeId = $GsaRecordTypeId
        $GsaRecordTypeCount++
    }
    else {
        $RecordTypeId = $FederalRecordTypeId
        $FederalRecordTypeCount++
    }

    $UpsertRows.Add([PSCustomObject]([ordered]@{
        LDGCRM_External_ID__c                             = $Group.ExternalId
        RecordTypeId                                      = $RecordTypeId
        FirstName                                         = $FirstName
        LastName                                          = $LastName
        Email                                             = $Email
        Phone                                             = $Phone
        Title                                             = $Title
        Description                                       = $Notes
        "Account.LDGCRM_External_ID__c"                   = $AccountId
        "LDGCRM_Partner_Account__r.LDGCRM_External_ID__c" = $PartnerAccountId
        LDGCRM_Subscription_Type__c                       = ($SubTags -join ";")
    }))
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "Contact-upsert.csv"
$IdentityMapFile = Join-Path $LoadDir "Contact-identity-map.csv"
$NameReviewFile = Join-Path $LogDir "Contact-name-review-$Timestamp.csv"
$ValueReviewFile = Join-Path $LogDir "Contact-value-review-$Timestamp.csv"
$AccountReviewFile = Join-Path $LogDir "Contact-no-account-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile }
# The identity map is an input to the Application-Contact junction chunk, not
# a review artifact - it belongs alongside the load CSVs.
if ($IdentityMapRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $IdentityMapRows.ToArray() -Path $IdentityMapFile }
if ($NameReviewRows.Count -gt 0) { $NameReviewRows | Export-Csv -LiteralPath $NameReviewFile -NoTypeInformation -Encoding UTF8 }
if ($ValueReviewRows.Count -gt 0) { $ValueReviewRows | Export-Csv -LiteralPath $ValueReviewFile -NoTypeInformation -Encoding UTF8 }
if ($AccountReviewRows.Count -gt 0) { $AccountReviewRows | Export-Csv -LiteralPath $AccountReviewFile -NoTypeInformation -Encoding UTF8 }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " CONTACT PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-52} {1,8:N0}" -f "Airtable Contact rows", $AirtableContacts.Count)
Write-Host ("{0,-52} {1,8:N0}" -f "Contacts after merging shared emails", $Groups.Count)
Write-Host ("{0,-52} {1,8:N0}" -f "Ready for upsert", $UpsertRows.Count)
Write-Host ""
Write-Host "  Name source:" -ForegroundColor Cyan
Write-Host ("{0,-52} {1,8:N0}" -f "    real Name from Airtable", $NameFromAirtable)
Write-Host ("{0,-52} {1,8:N0}" -f "    recovered from an existing Salesforce Contact", $NameFromExistingContact)
Write-Host ("{0,-52} {1,8:N0}" -f "    email address used as placeholder", $NameFromEmail)
Write-Host ("{0,-52} {1,8:N0}" -f "    skipped - no name AND no email", $NoNameAtAll)
Write-Host ""
Write-Host "  Account link:" -ForegroundColor Cyan
Write-Host ("{0,-52} {1,8:N0}" -f "    from Airtable's Account column", ($UpsertRows.Count - $AccountFromApplication - $NoAccountCount))
Write-Host ("{0,-52} {1,8:N0}" -f "    recovered via Application -> Partner Acct", $AccountFromApplication)
Write-Host ("{0,-52} {1,8:N0}" -f "    NO Account (FCIC trigger will spawn one)", $NoAccountCount)
Write-Host ""
Write-Host "  Record type:" -ForegroundColor Cyan
Write-Host ("{0,-52} {1,8:N0}" -f "    Federal (partner-agency contacts)", $FederalRecordTypeCount)
Write-Host ("{0,-52} {1,8:N0}" -f "    GSA (@gsa.gov staff)", $GsaRecordTypeCount)
Write-Host ""
Write-Host ("{0,-52} {1,8:N0}" -f "Values dropped for review (Subscription Type)", $ValueReviewRows.Count)
Write-Host ""

if ($UpsertRows.Count -gt 0) {
    Write-Host "Upsert file:" -ForegroundColor Cyan
    Write-Host $UpsertFile
    Write-Host "Identity map (input to the Application-Contact junction chunk):" -ForegroundColor Cyan
    Write-Host $IdentityMapFile
}
if ($NameReviewRows.Count -gt 0) {
    Write-Host "Contacts needing a real name:" -ForegroundColor Yellow
    Write-Host $NameReviewFile
}
if ($ValueReviewRows.Count -gt 0) {
    Write-Host "Dropped values for review:" -ForegroundColor Yellow
    Write-Host $ValueReviewFile
}

}
finally {
    Stop-ScriptLog
}
