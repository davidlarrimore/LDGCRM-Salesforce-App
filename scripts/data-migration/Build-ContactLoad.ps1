#Requires -Version 5.1

<#
    Chunk 2 of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md). Full field-by-field reasoning lives in
    docs/engineering/TRANSFORMATION-RULES.md's Contact section.

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
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (scripts/common/Common.Orgs.ps1).
    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # Turns off the email-domain Account inference entirely, leaving only the
    # three authored resolution paths. The first thing to reach for if an
    # inferred link ever puts a contact on the wrong agency.
    [switch]$DisableDomainInference,

    # How many contacts must already resolve to one Account on a domain before
    # that domain is trusted to assign it. 1 would let usda.gov claim 19
    # contacts off a single example; 3 is the agreed floor.
    [int]$DomainInferenceMinSupport = 3,

    # Owner for records whose own owner can't be determined. Resolved to a User
    # at run time (never a hard-coded Id - production's differs from every
    # sandbox's) and the run FAILS if it doesn't match an active User.
    [string]$FallbackOwnerEmail = "peter.marks@gsa.gov"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

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

# --- Second source: the Opportunity Contacts table -------------------------
# That table has NO link to the Contacts table - no rec... id, just a name
# string and an email - and 348 of its 520 rows name people who appear nowhere
# in the Contacts table. Those people must exist as Contacts or their
# OpportunityContactRole rows can never be created (user-confirmed 2026-08-13).
# They merge by email like any other duplicate, so anyone in BOTH tables stays
# a single Contact.
$AirtableOpportunityContacts = Import-AirtableTable -Label "Opportunity Contacts"
$ProjectedOpportunityContacts = @($AirtableOpportunityContacts | ForEach-Object { ConvertTo-ContactShapedRecord -Record $_ })
Write-Host "$($ProjectedOpportunityContacts.Count) Airtable Opportunity Contact rows folded in as a second source."

# ORDER MATTERS: Contacts-table rows first. Get-AirtableContactGroups picks the
# surviving record - whose Airtable id becomes the Salesforce external ID - and
# primary-source rows always win, so folding in this second source cannot
# re-key a Contact that has already been loaded.
$CombinedContactRecords = @($AirtableContacts) + $ProjectedOpportunityContacts

$Groups = @(Get-AirtableContactGroups -Records $CombinedContactRecords)
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
# The Account query also carries OwnerId, because Contacts inherit their
# Account's owner (decided 2026-08-13). Airtable has no Contact owner column at
# all, and Contact has org-wide-default-restricted sharing with owner-based
# sharing rules, so ownership decides who can SEE the contact - leaving all
# 1,900+ on the loading user would make that sharing model meaningless.
#
# Owner.IsActive is checked because Salesforce refuses to ASSIGN a record to an
# inactive user (INACTIVE_OWNER_OR_USER), even though existing records may
# legitimately still be owned by one. These Accounts pre-date the migration, so
# inactive owners are entirely plausible here.
#
# Owner.UserType is checked because ACTIVE IS NOT ENOUGH. A Chatter Free,
# portal or community user is active and can own nothing; assigning one fails
# the load with OP_WITH_INVALID_USER_TYPE_EXCEPTION, an error that names
# neither the field nor the user. That cost 150 Application rows on
# 2026-08-13. It has not yet bitten Contact - no Account here is currently
# owned by such a user - but these Accounts pre-date the migration and this org
# has ~2,637 Chatter-only users, so it is a matter of which Account, not
# whether.
$LoadedAccountIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$AccountOwnerByExternalId = @{}
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT LDGCRM_External_ID__c, OwnerId, Owner.IsActive, Owner.UserType FROM Account WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) {
        $LoadedAccountIds.Add($Row.LDGCRM_External_ID__c) | Out-Null
        if ($Row.OwnerId -and $Row.Owner.IsActive -and $Row.Owner.UserType -eq "Standard") {
            $AccountOwnerByExternalId[$Row.LDGCRM_External_ID__c] = $Row.OwnerId
        }
    }
}
$LoadedPartnerAccountIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT LDGCRM_External_ID__c FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) { $LoadedPartnerAccountIds.Add($Row.LDGCRM_External_ID__c) | Out-Null }
}
Write-Host "$($LoadedAccountIds.Count) Accounts, $($LoadedPartnerAccountIds.Count) Partner Accounts available to link."

Write-Host "Resolving the fallback owner ($FallbackOwnerEmail)..." -ForegroundColor Cyan
$FallbackOwnerId = Resolve-FallbackOwnerId -Email $FallbackOwnerEmail -OrgAlias $OrgAlias -ApiVersion $ApiVersion
Write-Host "Fallback owner resolves to $FallbackOwnerId."

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

# --- Account fallback 2: derive via the contact's Opportunity ---------------
# The Opportunity Contacts table (this script's second identity source) has no
# Account column, but every row links to an Opportunity, and the Opportunities
# table DOES carry "Account Record ID". So the same authored chain exists here
# as the Application one above - Opportunity Contact -> Opportunity -> Account.
#
# This matters far more than it looks. Those contacts are exactly the ones the
# Airtable Contacts table never had an Account for, so without this hop they
# are the bulk of the account-less population: it resolves 440 of 520
# Opportunity Contact rows and rescues 399 Contacts that would otherwise have
# no Account at all. Since account-less Contacts are now SKIPPED (see below),
# omitting this chain would have discarded 457 of 503 OpportunityContactRole
# rows - the junction those very contacts exist to support.
#
# NOTE the column name: "Opportunity Record ID (from Opportunities)", NOT
# "Opportunity Record ID". The latter is the Opportunity Contact row's OWN id
# (0 of 520 are real Opportunity ids) - the same trap documented for
# Build-OpportunityContactRoleLoad.ps1.
Write-Host "Building Opportunity -> Account fallback map..." -ForegroundColor Cyan
$OpportunityToAccount = @{}
foreach ($Opp in (Import-AirtableTable -Label "Opportunities")) {
    $Raw = $Opp.fields.'Account Record ID'
    if ($Raw) { $OpportunityToAccount[$Opp.id] = @($Raw)[0] }
}

# Keyed by the Airtable Opportunity Contact ROW id, because that is what a
# merge group's member rows carry.
$OpportunityContactRowToAccount = @{}
foreach ($OppContact in $AirtableOpportunityContacts) {
    $RawOpp = $OppContact.fields.'Opportunity Record ID (from Opportunities)'
    if (-not $RawOpp) { continue }
    $OppId = @($RawOpp)[0]
    if ($OppId -and $OpportunityToAccount.ContainsKey($OppId)) {
        $OpportunityContactRowToAccount[$OppContact.id] = $OpportunityToAccount[$OppId]
    }
}
Write-Host "$($OpportunityToAccount.Count) Opportunities carry an Account; $($OpportunityContactRowToAccount.Count) Opportunity Contact rows reach one."

# ============================================================
# PRE-PASS: resolve the AUTHORED Account links, then learn the domain map
# ============================================================
# Split out of the main loop for one reason: domain inference is only defensible
# if it is learned from contacts whose Account came from a link somebody
# actually recorded. That means every authored link has to be resolved before
# the first inference is attempted - which a single pass cannot do.
#
# Precedence, strongest evidence first:
#   1. Airtable's own Contacts.Account column
#   2. Application -> Partner Account -> Account
#   3. Opportunity Contact -> Opportunity -> Account
$AuthoredAccountByGroup = @{}
$AccountFromApplication = 0
$AccountFromOpportunity = 0

foreach ($Group in $Groups) {
    $Rows = $Group.Rows

    $Candidate = Get-FirstLinkedId $Rows "Account"
    $HadAirtableColumn = [bool]$Candidate
    if ($Candidate -and -not $LoadedAccountIds.Contains($Candidate)) { $Candidate = "" }

    if (-not $Candidate) {
        foreach ($Row in $Rows) {
            $RawApps = $Row.fields.'Applications Record ID (from Applications)'
            if (-not $RawApps) { continue }
            foreach ($AppId in @($RawApps)) {
                if ($ApplicationToAccount.ContainsKey($AppId)) {
                    $Try = $ApplicationToAccount[$AppId]
                    if ($LoadedAccountIds.Contains($Try)) {
                        $Candidate = $Try
                        $AccountFromApplication++
                        break
                    }
                }
            }
            if ($Candidate) { break }
        }
    }

    if (-not $Candidate) {
        foreach ($Row in $Rows) {
            if ($OpportunityContactRowToAccount.ContainsKey($Row.id)) {
                $Try = $OpportunityContactRowToAccount[$Row.id]
                if ($LoadedAccountIds.Contains($Try)) {
                    $Candidate = $Try
                    $AccountFromOpportunity++
                    break
                }
            }
        }
    }

    $AuthoredAccountByGroup[$Group.ExternalId] = [PSCustomObject]@{
        AccountId         = $Candidate
        HadAirtableColumn = $HadAirtableColumn
    }
}
Write-Host "$($AccountFromApplication) Contacts got an Account via an Application; $($AccountFromOpportunity) via an Opportunity."

# --- Learn domain -> Account, from authored links only ----------------------
# THE ONLY INFERENCE IN THIS SCRIPT, and it is hedged three ways because the
# naive version is actively wrong:
#   1. GOVERNMENT DOMAINS ONLY. A consumer domain would otherwise qualify -
#      gmail.com maps to exactly one Account in this data (one contact), so an
#      unguarded rule would sweep personal addresses onto that agency.
#   2. THE DOMAIN MUST MAP TO EXACTLY ONE ACCOUNT. gsa.gov spans 4 and is
#      correctly excluded by this alone.
#   3. MINIMUM SUPPORTING EVIDENCE. Without it, usda.gov would claim 19
#      contacts on the strength of a SINGLE known example, and usdoj.gov 7 on
#      one. -DomainInferenceMinSupport controls the bar.
#
# Worth knowing how little this now buys: adding the Opportunity chain above
# collapsed its yield from ~95 contacts to ~20, because the authored links
# already reach nearly everything recoverable. It is kept because a recovered
# Account is a contact that loads rather than being skipped, but it is the first
# thing to switch off (-DisableDomainInference) if an inferred link ever
# misassigns a contact.
$DomainToAccount = @{}
$DomainSupport = @{}
$DomainInferenceRows = [System.Collections.Generic.List[object]]::new()
$AccountFromDomain = 0

if (-not $DisableDomainInference) {
    $Observed = @{}
    foreach ($Group in $Groups) {
        $Resolved = $AuthoredAccountByGroup[$Group.ExternalId].AccountId
        if (-not $Resolved) { continue }
        $Domain = Get-EmailDomain (Get-CleanContactEmail (Get-FirstNonEmpty $Group.Rows "Email"))
        if (-not $Domain) { continue }
        if (-not $Observed.ContainsKey($Domain)) { $Observed[$Domain] = @{} }
        if (-not $Observed[$Domain].ContainsKey($Resolved)) { $Observed[$Domain][$Resolved] = 0 }
        $Observed[$Domain][$Resolved]++
    }

    foreach ($Domain in $Observed.Keys) {
        if ($Domain -notmatch '\.gov$') { continue }
        if ($Observed[$Domain].Keys.Count -ne 1) { continue }
        $Total = ($Observed[$Domain].Values | Measure-Object -Sum).Sum
        if ($Total -lt $DomainInferenceMinSupport) { continue }
        $DomainToAccount[$Domain] = @($Observed[$Domain].Keys)[0]
        $DomainSupport[$Domain] = $Total
    }
    Write-Host "$($DomainToAccount.Count) .gov domain(s) map to a single Account with $DomainInferenceMinSupport+ supporting contacts."
}

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
# NOTE: $AccountFromApplication / $AccountFromOpportunity / $AccountFromDomain
# are set by the pre-pass above and must NOT be re-initialised here - doing so
# silently zeroes the counts the summary reports.
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

    # --- Lookups ---
    # The three AUTHORED resolution paths ran in the pre-pass above (they have
    # to, because the domain-inference map is learned from their results).
    $Authored = $AuthoredAccountByGroup[$Group.ExternalId]
    $AccountId = $Authored.AccountId
    $AccountFromAirtableColumn = $Authored.HadAirtableColumn

    if (-not $AccountId -and -not $DisableDomainInference) {
        # LAST RESORT, AND THE ONLY INFERENCE IN THIS SCRIPT. Everything above
        # follows a link somebody actually recorded; this guesses from the email
        # domain, so it is deliberately hedged three ways (see the map build for
        # the full reasoning) and every hit is written to a review CSV.
        $Domain = Get-EmailDomain $Email
        if ($Domain -and $DomainToAccount.ContainsKey($Domain)) {
            $AccountId = $DomainToAccount[$Domain]
            $AccountFromDomain++
            $DomainInferenceRows.Add([PSCustomObject]@{
                ContactExternalId = $Group.ExternalId
                Email             = $Email
                Domain            = $Domain
                AccountExternalId = $AccountId
                SupportingContacts = $DomainSupport[$Domain]
                Reason            = "INFERRED, not a recorded link: every other contact on this domain that DOES have an Account maps to this one. Verify before relying on it."
            })
        }
    }

    if (-not $AccountId) {
        # SKIPPED, not loaded with a blank Account (decided 2026-08-13).
        # Two reasons: a Contact with no Account makes the FCIC trigger spawn a
        # junk "FCIC_Individual" Account, and a contact attached to no agency is
        # not useful in the CRM. Measured cost of skipping, after the two
        # authored fallbacks above: 0 of 1,880 Application-Contact junction rows
        # and 22 of 503 OpportunityContactRole rows - versus 457 OCR rows lost
        # had the Opportunity chain not been added first.
        $NoAccountCount++
        $AccountReviewRows.Add([PSCustomObject]@{
            ContactExternalId = $Group.ExternalId
            Email             = $Email
            Reason            = if ($AccountFromAirtableColumn) {
                                    "SKIPPED - not loaded. Airtable links this contact to an Account that isn't reconciled in $OrgAlias (duplicate/unmatched Airtable Account - see docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md), and neither a linked Application nor a linked Opportunity resolves to one."
                                } else {
                                    "SKIPPED - not loaded. No Account link in Airtable, and neither a linked Application nor a linked Opportunity resolves to one."
                                }
        })
        continue
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

    # --- OwnerId: inherited from the resolved Account ---
    # Every Contact reaching this point HAS an Account (account-less ones were
    # skipped above), so the fallback only applies where that Account's own
    # owner is missing or inactive.
    $OwnerId = $FallbackOwnerId
    if ($AccountId -and $AccountOwnerByExternalId.ContainsKey($AccountId)) {
        $OwnerId = $AccountOwnerByExternalId[$AccountId]
    }

    $UpsertRows.Add([PSCustomObject]([ordered]@{
        LDGCRM_External_ID__c                             = $Group.ExternalId
        OwnerId                                           = $OwnerId
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
$DomainInferenceFile = Join-Path $LogDir "Contact-domain-inferred-account-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile }
# The identity map is an input to the Application-Contact junction chunk, not
# a review artifact - it belongs alongside the load CSVs.
if ($IdentityMapRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $IdentityMapRows.ToArray() -Path $IdentityMapFile }
if ($NameReviewRows.Count -gt 0) { $NameReviewRows | Export-Csv -LiteralPath $NameReviewFile -NoTypeInformation -Encoding UTF8 }
if ($ValueReviewRows.Count -gt 0) { $ValueReviewRows | Export-Csv -LiteralPath $ValueReviewFile -NoTypeInformation -Encoding UTF8 }
if ($AccountReviewRows.Count -gt 0) { $AccountReviewRows | Export-Csv -LiteralPath $AccountReviewFile -NoTypeInformation -Encoding UTF8 }
if ($DomainInferenceRows.Count -gt 0) { $DomainInferenceRows | Export-Csv -LiteralPath $DomainInferenceFile -NoTypeInformation -Encoding UTF8 }

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
Write-Host ("{0,-52} {1,8:N0}" -f "    from Airtable's Account column", ($UpsertRows.Count - $AccountFromApplication - $AccountFromOpportunity - $AccountFromDomain))
Write-Host ("{0,-52} {1,8:N0}" -f "    recovered via Application -> Partner Acct", $AccountFromApplication)
Write-Host ("{0,-52} {1,8:N0}" -f "    recovered via Opportunity -> Account", $AccountFromOpportunity)
Write-Host ("{0,-52} {1,8:N0}" -f "    INFERRED from .gov email domain", $AccountFromDomain)
Write-Host ("{0,-52} {1,8:N0}" -f "  SKIPPED - no Account could be resolved", $NoAccountCount)
Write-Host ""
Write-Host "  Record type:" -ForegroundColor Cyan
Write-Host ("{0,-52} {1,8:N0}" -f "    Federal (partner-agency contacts)", $FederalRecordTypeCount)
Write-Host ("{0,-52} {1,8:N0}" -f "    GSA (@gsa.gov staff)", $GsaRecordTypeCount)
Write-Host ""
Write-Host ""
# Compare against the fallback Id, not against "is OwnerId set" - every row now
# carries an OwnerId, so a truthiness test would report 100% inherited.
Write-Host ("{0,-52} {1,8:N0}" -f "Owner inherited from the Account", @($UpsertRows | Where-Object { $_.OwnerId -ne $FallbackOwnerId }).Count)
Write-Host ("{0,-52} {1,8:N0}" -f "Owner = fallback ($FallbackOwnerEmail)", @($UpsertRows | Where-Object { $_.OwnerId -eq $FallbackOwnerId }).Count)
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
if ($AccountReviewRows.Count -gt 0) {
    Write-Host "SKIPPED - no Account could be resolved (not loaded):" -ForegroundColor Yellow
    Write-Host $AccountReviewFile
}
if ($DomainInferenceRows.Count -gt 0) {
    Write-Host "Accounts INFERRED from an email domain (verify these):" -ForegroundColor Yellow
    Write-Host $DomainInferenceFile
}

}
finally {
    Stop-ScriptLog
}
