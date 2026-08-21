#Requires -Version 5.1

<#
    Chunk 3 of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md). Builds the LDGCRM_Application_Contact__c junction linking
    LDGCRM_application__c to Contact. Full reasoning lives in
    docs/engineering/TRANSFORMATION-RULES.md's Application Contact section.

    Requires BOTH Application and Contact to be loaded first - a junction row
    whose either side can't resolve fails outright, so unresolvable pairs are
    skipped rather than submitted.

    OwnerId is set to the FALLBACK owner on every row. This object does have one
    (it joins its two parents by plain Lookup, not Master-Detail, so it is not
    owner-inheriting the way LDGCRM_Opportunity_Impediment__c is), but Airtable
    records no owner for an application-contact association - only the
    association itself. Inheriting the Contact's or the Application's owner
    would be inventing a rule nobody agreed to, so the ownership rule agreed
    2026-08-13 applies its fallback. It is written explicitly rather than left
    blank because blank means "whoever ran the load", which in production is a
    GSA IT Operations engineer rather than the agreed owner.

    THREE THINGS DRIVE THE DESIGN:

    1. THE SOURCE IS THE AIRTABLE CONTACT *ROWS*, NOT THE MERGED CONTACTS.
       Build-ContactLoad.ps1 merges Airtable rows that share an email into one
       Salesforce Contact, because Airtable has no person-to-Application
       junction and enters the same person once per association. But that means
       the per-association detail - which Applications, and which Roles - lives
       on the individual ROW, not on the merged person. So this script iterates
       the raw rows and maps each one onto its surviving Contact through
       Get-AirtableContactGroups (the same shared helper Build-ContactLoad.ps1
       uses, so the two can't drift).

    2. MERGING CREATES COLLISIONS THAT MUST BE DEDUPED. Two Airtable rows for
       the same person can both link to the same Application; once merged they
       become the same (Contact, Application) pair. 33 such collisions exist.
       A before-save Flow (LDGCRM_ApplicationContact_BeforeSave_NewRecordDuplicateCheck)
       enforces one row per Application/Contact combination and THROWS, so
       submitting them would fail those records.

       Rather than dedupe defensively and hope, the junction's own
       LDGCRM_External_ID__c is the COMPOSITE KEY "<contactExtId>|<applicationExtId>".
       That makes uniqueness structural: the upsert key itself cannot produce a
       second row for the same pair, so re-running is idempotent and the Flow
       never has a duplicate to reject. (35 chars against the field's 50 - fits.)

    3. THE PARTNER PORTAL ADMIN FLAG HAS TWO REAL SOURCES, AND THEY ARE UNIONED.
       Not the Applications table's "Partner Portal Admin" column, though - that
       looks like the obvious source but is a flattened roll-up of all the linked
       contacts' Roles, NOT positionally aligned with "Contacts Record ID" (the
       arrays differ in length on 709 of 875 rows), so there is no way to tell
       which contact an entry refers to. Using it would assign the flag
       essentially at random. It stays excluded.

       The two real sources:
         a) Contacts.Roles on the individual Airtable row contains
            "Partner Portal Admin". The original source; per-association,
            because Airtable duplicates contact rows per association.
         b) NEW 2026-08-13: the ISSUER STRINGS table's "Partner Portal Admin
            Email" column, which names the admin per issuer string, and each
            issuer string links to its Application(s).

       Measured against the 2026-08-13 export, the two agree on 882 pairs but
       each sees some the other doesn't - Roles-only 117, Issuer-Strings-only 86.
       They are UNIONed (admin if EITHER says so) rather than intersected: both
       are authored data, and dropping a flag because the other source is silent
       would lose real information.

       ** The 86 matter more than the count suggests: NONE of them had a junction
       row at all. ** They are 34 people administering 68 Applications they are
       not recorded as contacts on in the Contacts table (e.g. a DOL admin on
       "State of Alaska Unemployment Insurance"). So Issuer Strings does not just
       set a flag on existing pairs - it CREATES associations, and skipping it
       would have lost the association entirely, not merely mislabelled it.
       Per the project owner (2026-08-13): a Partner Portal Admin should be an
       Application Contact with the checkbox checked.

    Fields NOT written, deliberately:
      - Name: the object's nameField is an AUTONUMBER. Supplying it fails.
      - LDGCRM_Email__c, LDGCRM_P3_Team_UUID__c, LDGCRM_P3_Partner_Portal_Team_Name__c:
        all three are formula fields.

    Watch the API names - both carry typos that are easy to "correct" into a
    field that doesn't exist:
      - LDGCRM_contact__c   (lower-case "contact")
      - LGDCRM_P3_Partner_Portal_Admin__c   ("LGDCRM", transposed prefix)
#>

param(
    [ValidateSet("Dev", "QA", "UAT", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (powershell-scripts/Common.Orgs.ps1).
    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # Owner for every junction row, since Airtable records the association but
    # no owner for it. Resolved to a User at run time; the run FAILS if it
    # doesn't match an active User.
    [string]$FallbackOwnerEmail = "peter.marks@gsa.gov"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-ApplicationContactLoad"

# The Airtable role that maps to the junction's Partner Portal Admin checkbox.
# Every other Role value (Technical POC, Program POC, Help Desk POC, Exec POC,
# PAG POC, ConMon Attendee, Archive, Threat Intel POC, UX POC) has no field on
# this object - see docs/engineering/TRANSFORMATION-RULES.md.
$PartnerPortalAdminRole = "Partner Portal Admin"

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " APPLICATION-CONTACT JUNCTION PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Reads Salesforce (read-only queries) - writes local files only." -ForegroundColor Yellow
Write-Host ""

$AirtableContacts = Import-AirtableTable -Label "Contacts"
Write-Host "$($AirtableContacts.Count) Airtable Contact rows loaded."

# Same grouping Build-ContactLoad.ps1 used, so every Airtable row resolves to
# the Contact that actually exists in Salesforce.
$Groups = @(Get-AirtableContactGroups -Records $AirtableContacts)
$RowToContactExternalId = @{}
foreach ($Group in $Groups) {
    foreach ($MemberId in $Group.MemberRecordIds) {
        $RowToContactExternalId[$MemberId] = $Group.ExternalId
    }
}
Write-Host "$($Groups.Count) merged Contacts; $($RowToContactExternalId.Count) Airtable rows mapped onto them."

Write-Host ""
Write-Host "Resolving the fallback owner ($FallbackOwnerEmail)..." -ForegroundColor Cyan
$FallbackOwnerId = Resolve-FallbackOwnerId -Email $FallbackOwnerEmail -OrgAlias $OrgAlias -ApiVersion $ApiVersion
Write-Host "Fallback owner resolves to $FallbackOwnerId."

Write-Host "Querying $OrgAlias for loaded Contacts and Applications..." -ForegroundColor Cyan
$LoadedContactIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT LDGCRM_External_ID__c FROM Contact WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) { $LoadedContactIds.Add($Row.LDGCRM_External_ID__c) | Out-Null }
}
$LoadedApplicationIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT LDGCRM_External_ID__c FROM LDGCRM_application__c WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) { $LoadedApplicationIds.Add($Row.LDGCRM_External_ID__c) | Out-Null }
}
Write-Host "$($LoadedContactIds.Count) Contacts, $($LoadedApplicationIds.Count) Applications present in $OrgAlias."

# --- Collapse (row, application) pairs onto (contact, application) ----------
$Pairs = @{}
$RawPairCount = 0

foreach ($Row in $AirtableContacts) {
    $RawApplications = $Row.fields.'Applications Record ID (from Applications)'
    if (-not $RawApplications) { continue }          # null-check before @()

    $ContactExternalId = $RowToContactExternalId[$Row.id]
    if (-not $ContactExternalId) { continue }        # shouldn't happen; guards a grouping bug

    $Roles = @($Row.fields.Roles) | ForEach-Object { "$_" }
    $IsPartnerPortalAdmin = ($Roles -contains $PartnerPortalAdminRole)

    foreach ($ApplicationId in @($RawApplications)) {
        if (-not $ApplicationId) { continue }
        $RawPairCount++

        $Key = "$ContactExternalId|$ApplicationId"
        if (-not $Pairs.ContainsKey($Key)) {
            $Pairs[$Key] = [PSCustomObject]@{
                ContactExternalId     = $ContactExternalId
                ApplicationExternalId = $ApplicationId
                PartnerPortalAdmin    = $false
                AdminFromRoles        = $false
                AdminFromIssuerString = $false
                FromIssuerStringOnly  = $false
                SourceRowIds          = [System.Collections.Generic.List[string]]::new()
            }
        }
        # OR the flag across every source row that produced this pair: if any
        # of the merged rows says this person is a Partner Portal Admin on this
        # Application, the junction says so too.
        if ($IsPartnerPortalAdmin) {
            $Pairs[$Key].PartnerPortalAdmin = $true
            $Pairs[$Key].AdminFromRoles = $true
        }
        $Pairs[$Key].SourceRowIds.Add($Row.id)
    }
}

# Snapshot BEFORE the Issuer Strings pass. The merge-collision figure below is
# derived as (raw pairs - distinct pairs), which is only meaningful against the
# pairs the Contacts table produced; Issuer Strings adds pairs that had no raw
# row at all, and counting those would silently understate the collisions.
$PairsFromContactRows = $Pairs.Count

# --- Second source: Issuer Strings' "Partner Portal Admin Email" -------------
# See design point 3. This both SETS the flag on pairs that already exist and
# CREATES pairs that the Contacts table never recorded - the latter is the
# majority of what it contributes, so treating it as flag-only would silently
# drop the associations.
#
# Matching is by EMAIL, through the same Get-CleanContactEmail used to build the
# merged Contacts, so an address that is dirty in Airtable (embedded name/phone,
# stray whitespace) resolves the same way on both sides instead of missing.
Write-Host ""
Write-Host "Loading Airtable Issuer Strings for Partner Portal Admins..." -ForegroundColor Cyan
$AirtableIssuerStrings = Import-AirtableTable -Label "Issuer Strings"
Write-Host "$($AirtableIssuerStrings.Count) Airtable Issuer String rows loaded."

$ContactExternalIdByEmail = @{}
foreach ($Row in $AirtableContacts) {
    $Email = Get-CleanContactEmail $Row.fields.Email
    if ($Email -and $RowToContactExternalId[$Row.id]) {
        $ContactExternalIdByEmail[$Email] = $RowToContactExternalId[$Row.id]
    }
}

$UnmatchedAdminEmails = @{}
$AdminPairsFromIssuerStrings = 0

foreach ($IssuerRow in $AirtableIssuerStrings) {
    $RawApplications = $IssuerRow.fields.'Applications'
    if (-not $RawApplications) { continue }                  # null-check before @()
    if (-not $IssuerRow.fields.'Partner Portal Admin Email') { continue }

    foreach ($RawEmail in @($IssuerRow.fields.'Partner Portal Admin Email')) {
        $Email = Get-CleanContactEmail $RawEmail
        if (-not $Email) { continue }

        if (-not $ContactExternalIdByEmail.ContainsKey($Email)) {
            # Currently 0 of 239 - but an admin who isn't a Contact at all can't
            # be given a junction row, so it must be reported rather than assumed
            # impossible.
            $UnmatchedAdminEmails[$Email] = $true
            continue
        }

        $ContactExternalId = $ContactExternalIdByEmail[$Email]

        foreach ($ApplicationId in @($RawApplications)) {
            if ([string]::IsNullOrWhiteSpace([string]$ApplicationId)) { continue }

            $Key = "$ContactExternalId|$ApplicationId"
            if (-not $Pairs.ContainsKey($Key)) {
                $Pairs[$Key] = [PSCustomObject]@{
                    ContactExternalId     = $ContactExternalId
                    ApplicationExternalId = [string]$ApplicationId
                    PartnerPortalAdmin    = $false
                    AdminFromRoles        = $false
                    AdminFromIssuerString = $false
                    FromIssuerStringOnly  = $true      # no Contacts-table association at all
                    SourceRowIds          = [System.Collections.Generic.List[string]]::new()
                }
                $AdminPairsFromIssuerStrings++
            }

            $Pairs[$Key].PartnerPortalAdmin = $true
            $Pairs[$Key].AdminFromIssuerString = $true
        }
    }
}

Write-Host "$AdminPairsFromIssuerStrings association(s) exist ONLY because Issuer Strings names an admin."
if ($UnmatchedAdminEmails.Count -gt 0) {
    Write-Host ("$($UnmatchedAdminEmails.Count) Partner Portal Admin email(s) match no Airtable Contact - " +
                "no junction row can be created for them. See the review CSV.") -ForegroundColor Yellow
}

$UpsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()

foreach ($Key in $Pairs.Keys) {
    $Pair = $Pairs[$Key]
    $ContactLoaded = $LoadedContactIds.Contains($Pair.ContactExternalId)
    $ApplicationLoaded = $LoadedApplicationIds.Contains($Pair.ApplicationExternalId)

    if (-not $ContactLoaded -or -not $ApplicationLoaded) {
        $Missing = @()
        if (-not $ContactLoaded) { $Missing += "Contact $($Pair.ContactExternalId)" }
        if (-not $ApplicationLoaded) { $Missing += "Application $($Pair.ApplicationExternalId)" }
        $SkippedRows.Add([PSCustomObject]@{
            ContactExternalId     = $Pair.ContactExternalId
            ApplicationExternalId = $Pair.ApplicationExternalId
            NotLoaded             = ($Missing -join "; ")
            Reason                = "Junction needs both sides present; the missing side was itself withheld by its own load (usually the unreconciled-Account data-quality issue). Re-run once it loads - no code change needed."
        })
        continue
    }

    $UpsertRows.Add([PSCustomObject]([ordered]@{
        # Composite key - see the header. This is what makes one row per
        # (Contact, Application) structural rather than merely intended.
        LDGCRM_External_ID__c                             = $Key
        OwnerId                                           = $FallbackOwnerId
        "LDGCRM_contact__r.LDGCRM_External_ID__c"         = $Pair.ContactExternalId
        "LDGCRM_Application__r.LDGCRM_External_ID__c"     = $Pair.ApplicationExternalId
        LGDCRM_P3_Partner_Portal_Admin__c                 = if ($Pair.PartnerPortalAdmin) { "true" } else { "false" }
    }))
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$UpsertFile = Join-Path $LoadDir "LDGCRM_Application_Contact__c-upsert.csv"
$SkippedFile = Join-Path $LogDir "ApplicationContact-skipped-$Timestamp.csv"
$AdminSourceFile = Join-Path $LogDir "ApplicationContact-admin-source-$Timestamp.csv"

if ($UpsertRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile }
if ($SkippedRows.Count -gt 0) { $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8 }

# Provenance for every admin flag. Written because the two sources disagree on a
# few hundred pairs and the union hides which one asserted what - without this,
# "why is this person an admin?" is unanswerable after the fact.
$AdminSourceRows = [System.Collections.Generic.List[object]]::new()
foreach ($Key in $Pairs.Keys) {
    $Pair = $Pairs[$Key]
    if (-not $Pair.PartnerPortalAdmin) { continue }

    $Source = if ($Pair.AdminFromRoles -and $Pair.AdminFromIssuerString) { "BOTH" }
              elseif ($Pair.AdminFromRoles) { "Contacts.Roles only" }
              else { "Issuer Strings only" }

    $AdminSourceRows.Add([PSCustomObject]@{
        ContactExternalId     = $Pair.ContactExternalId
        ApplicationExternalId = $Pair.ApplicationExternalId
        AdminSource           = $Source
        NewAssociation        = if ($Pair.FromIssuerStringOnly) { "YES - no Contacts-table link" } else { "no" }
        Note                  = "Flag is the UNION of Contacts.Roles and Issuer Strings' Partner Portal Admin Email. 'Issuer Strings only' rows are ones Contacts.Roles does not call an admin; 'Contacts.Roles only' rows are ones Issuer Strings does not name. Both are authored data, so neither is dropped."
    })
}
foreach ($Email in $UnmatchedAdminEmails.Keys) {
    $AdminSourceRows.Add([PSCustomObject]@{
        ContactExternalId     = "(none - email matched no Contact)"
        ApplicationExternalId = ""
        AdminSource           = "Issuer Strings only"
        NewAssociation        = "NO - cannot be created"
        Note                  = "Partner Portal Admin email '$Email' does not match any Airtable Contact, so no junction row can be created. Needs the person added as a Contact in Airtable."
    })
}
if ($AdminSourceRows.Count -gt 0) {
    $AdminSourceRows | Export-Csv -LiteralPath $AdminSourceFile -NoTypeInformation -Encoding UTF8
}

$PartnerPortalAdminCount = @($UpsertRows | Where-Object { $_.LGDCRM_P3_Partner_Portal_Admin__c -eq "true" }).Count
$AdminBoth       = @($AdminSourceRows | Where-Object { $_.AdminSource -eq "BOTH" }).Count
$AdminRolesOnly  = @($AdminSourceRows | Where-Object { $_.AdminSource -eq "Contacts.Roles only" }).Count
$AdminIssuerOnly = @($AdminSourceRows | Where-Object { $_.AdminSource -eq "Issuer Strings only" -and $_.ApplicationExternalId }).Count

# How many of the Issuer-Strings-only associations actually made the load - the
# rest wait on their Application, same as any other skipped pair.
$LoadedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Loaded in $UpsertRows) { $LoadedKeys.Add($Loaded.LDGCRM_External_ID__c) | Out-Null }
$AdminIssuerOnlyLoaded = 0
foreach ($Key in $Pairs.Keys) {
    if ($Pairs[$Key].FromIssuerStringOnly -and $LoadedKeys.Contains($Key)) { $AdminIssuerOnlyLoaded++ }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " APPLICATION-CONTACT PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-54} {1,8:N0}" -f "Raw (Airtable row, Application) pairs", $RawPairCount)
Write-Host ("{0,-54} {1,8:N0}" -f "Distinct (Contact, Application) pairs", $PairsFromContactRows)
Write-Host ("{0,-54} {1,8:N0}" -f "  collisions collapsed by the Contact merge", ($RawPairCount - $PairsFromContactRows))
Write-Host ("{0,-54} {1,8:N0}" -f "  + associations added by Issuer Strings", $AdminPairsFromIssuerStrings)
Write-Host ("{0,-54} {1,8:N0}" -f "Total distinct pairs", $Pairs.Count)
Write-Host ("{0,-54} {1,8:N0}" -f "Ready for upsert (both sides loaded)", $UpsertRows.Count)
Write-Host ("{0,-54} {1,8:N0}" -f "Skipped (a side isn't loaded yet)", $SkippedRows.Count)
Write-Host ""
Write-Host ("{0,-54} {1,8:N0}" -f "Flagged Partner Portal Admin, IN THE LOAD", $PartnerPortalAdminCount)
Write-Host ("{0,-54} {1,8:N0}" -f "  ...of which Issuer Strings added the association", $AdminIssuerOnlyLoaded)
Write-Host ""
# NOTE: this breakdown counts ALL admin pairs, including ones skipped above
# because a side isn't loaded - so it does NOT sum to the in-the-load figure.
# Said explicitly because two admin totals that don't reconcile look like a bug.
Write-Host ("{0,-54} {1,8:N0}" -f "Admin flags across ALL pairs (incl. skipped)", ($AdminBoth + $AdminRolesOnly + $AdminIssuerOnly))
Write-Host ("{0,-54} {1,8:N0}" -f "  ...asserted by BOTH sources", $AdminBoth)
Write-Host ("{0,-54} {1,8:N0}" -f "  ...by Contacts.Roles only", $AdminRolesOnly)
Write-Host ("{0,-54} {1,8:N0}" -f "  ...by Issuer Strings only", $AdminIssuerOnly)
if ($UnmatchedAdminEmails.Count -gt 0) {
    Write-Host ("{0,-54} {1,8:N0}" -f "  admin emails matching no Contact (lost)", $UnmatchedAdminEmails.Count) -ForegroundColor Yellow
}
Write-Host ""

if ($AdminSourceRows.Count -gt 0) {
    Write-Host "Partner Portal Admin provenance (which source asserted each flag):" -ForegroundColor Cyan
    Write-Host $AdminSourceFile
}

if ($UpsertRows.Count -gt 0) {
    Write-Host "Upsert file (composite external ID = <contact>|<application>):" -ForegroundColor Cyan
    Write-Host $UpsertFile
}
if ($SkippedRows.Count -gt 0) {
    Write-Host "Skipped pairs (re-run after the missing side loads):" -ForegroundColor Yellow
    Write-Host $SkippedFile
}

}
finally {
    Stop-ScriptLog
}
