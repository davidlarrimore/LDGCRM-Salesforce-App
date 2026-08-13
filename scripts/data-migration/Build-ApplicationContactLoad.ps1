#Requires -Version 5.1

<#
    Chunk 3 of the Airtable -> Salesforce data-migration pipeline (see
    docs/README.md). Builds the LDGCRM_Application_Contact__c junction linking
    LDGCRM_application__c to Contact. Full reasoning lives in
    docs/TRANSFORMATION-RULES.md's Application Contact section.

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

    3. THE PARTNER PORTAL ADMIN FLAG COMES FROM Contacts.Roles, NOT FROM THE
       APPLICATIONS TABLE. Applications has a "Partner Portal Admin" column
       that looks like the obvious source, but it is a flattened roll-up of all
       the linked contacts' Roles and is NOT positionally aligned with
       "Contacts Record ID" - the two arrays differ in length on 709 of 875
       rows, so there is no way to tell which contact a given entry refers to.
       Using it would assign the flag essentially at random. Contacts.Roles on
       the individual row is the real per-association source.

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
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (scripts/common/Common.Orgs.ps1).
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

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-ApplicationContactLoad"

# The Airtable role that maps to the junction's Partner Portal Admin checkbox.
# Every other Role value (Technical POC, Program POC, Help Desk POC, Exec POC,
# PAG POC, ConMon Attendee, Archive, Threat Intel POC, UX POC) has no field on
# this object - see docs/TRANSFORMATION-RULES.md.
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
                SourceRowIds          = [System.Collections.Generic.List[string]]::new()
            }
        }
        # OR the flag across every source row that produced this pair: if any
        # of the merged rows says this person is a Partner Portal Admin on this
        # Application, the junction says so too.
        if ($IsPartnerPortalAdmin) { $Pairs[$Key].PartnerPortalAdmin = $true }
        $Pairs[$Key].SourceRowIds.Add($Row.id)
    }
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

if ($UpsertRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $UpsertRows.ToArray() -Path $UpsertFile }
if ($SkippedRows.Count -gt 0) { $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8 }

$PartnerPortalAdminCount = @($UpsertRows | Where-Object { $_.LGDCRM_P3_Partner_Portal_Admin__c -eq "true" }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " APPLICATION-CONTACT PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-54} {1,8:N0}" -f "Raw (Airtable row, Application) pairs", $RawPairCount)
Write-Host ("{0,-54} {1,8:N0}" -f "Distinct (Contact, Application) pairs", $Pairs.Count)
Write-Host ("{0,-54} {1,8:N0}" -f "  collisions collapsed by the Contact merge", ($RawPairCount - $Pairs.Count))
Write-Host ("{0,-54} {1,8:N0}" -f "Ready for upsert (both sides loaded)", $UpsertRows.Count)
Write-Host ("{0,-54} {1,8:N0}" -f "Skipped (a side isn't loaded yet)", $SkippedRows.Count)
Write-Host ("{0,-54} {1,8:N0}" -f "  ...flagged Partner Portal Admin", $PartnerPortalAdminCount)
Write-Host ""

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
