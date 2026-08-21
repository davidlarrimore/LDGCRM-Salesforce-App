#Requires -Version 5.1

<#
    Chunk 4 of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md). Builds OpportunityContactRole from the Airtable
    "Opportunity Contacts" table. Full reasoning lives in
    docs/engineering/TRANSFORMATION-RULES.md's OpportunityContactRole section.

    THIS OBJECT CANNOT BE UPSERTED - IT IS THE ONLY ONE IN THE PIPELINE THAT
    RESOLVES REAL SALESFORCE IDs INSTEAD.

    Every other object keys on LDGCRM_External_ID__c. That is impossible here:
    Salesforce refuses to make the field an External ID at all. Deploying
    externalId=true fails with

        "Fields on Opportunity Contact Role do not support the property
         Is External Identifier."

    so `sf data upsert bulk --external-id` can never work against it. (The field
    still exists as plain text and is populated for traceability - it just can't
    be a key.) CLAUDE.md previously recorded this as "needs a metadata fix";
    it does not, because no such fix exists.

    Idempotency therefore comes from a read-then-diff, the same approach
    Build-AccountReconciliation.ps1 uses for Account: query what is already in
    the org, key it on (OpportunityId, ContactId, Role), and emit an INSERT file
    containing only the rows that don't exist yet. Re-running is safe because
    the diff re-runs too.

    CONTACT RESOLUTION IS INDIRECT. The Opportunity Contacts table has no
    rec... link to the Contacts table - just a name string and an email. Its
    rows are folded into Contact as a second source by Build-ContactLoad.ps1
    (see ConvertTo-ContactShapedRecord), where they merge by email with anyone
    already present. So a row's own Airtable id may NOT be the surviving
    Contact's external ID. This script re-derives the same grouping through the
    shared Get-AirtableContactGroups to find the survivor, then resolves that
    external ID to a real Salesforce Id.

    ONE ROW PER ROLE (user-confirmed 2026-08-13). 62 rows carry 2+ Contact
    Types while Role holds a single value, so each type becomes its own
    OpportunityContactRole record on that Opportunity. Salesforce permits
    multiple roles for the same contact on the same opportunity - VERIFY THIS ON
    A SMALL TEST BATCH before the full load, because it is the assumption the
    whole design rests on.

    IsPrimary is set on AT MOST ONE row per Opportunity. Salesforce enforces a
    single primary contact role per Opportunity, so when a contact with several
    roles is flagged Primary in Airtable, only their highest-precedence role row
    carries the flag - otherwise the load would fight itself.
#>

param(
    [ValidateSet("Dev", "QA", "UAT", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (powershell-scripts/Common.Orgs.ps1).
    # Set this only to reach an org that isn't in the registry; doing so skips
    # the registry's identity checks.
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-OpportunityContactRoleLoad"

# Seniority order, used ONLY to decide which of a contact's several role rows
# carries IsPrimary. Every role still gets its own record.
$RolePrecedence = @("Decision Maker", "Senior POC", "Day-to-Day POC")

function Get-RoleRank {
    param([string]$Role)
    $Index = $RolePrecedence.IndexOf($Role)
    if ($Index -lt 0) { return 999 }
    return $Index
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " OPPORTUNITY CONTACT ROLE PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Builds an INSERT file by diffing against existing rows (no upsert on this" -ForegroundColor Yellow
Write-Host "object). Reads Salesforce - writes local files only." -ForegroundColor Yellow
Write-Host ""

$AirtableOpportunityContacts = Import-AirtableTable -Label "Opportunity Contacts"
Write-Host "$($AirtableOpportunityContacts.Count) Airtable Opportunity Contact rows loaded."

# --- Re-derive the Contact grouping so each row maps to its surviving Contact
$AirtableContacts = Import-AirtableTable -Label "Contacts"
$ProjectedOpportunityContacts = @($AirtableOpportunityContacts | ForEach-Object { ConvertTo-ContactShapedRecord -Record $_ })
$Groups = @(Get-AirtableContactGroups -Records (@($AirtableContacts) + $ProjectedOpportunityContacts))

$RowToContactExternalId = @{}
foreach ($Group in $Groups) {
    foreach ($MemberId in $Group.MemberRecordIds) { $RowToContactExternalId[$MemberId] = $Group.ExternalId }
}
Write-Host "$($Groups.Count) merged Contacts; every Opportunity Contact row mapped to its survivor."

# --- Resolve external IDs to real Salesforce Ids ---------------------------
Write-Host ""
Write-Host "Resolving Salesforce Ids..." -ForegroundColor Cyan
$ContactIdByExternalId = @{}
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT Id, LDGCRM_External_ID__c FROM Contact WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) { $ContactIdByExternalId[$Row.LDGCRM_External_ID__c] = $Row.Id }
}
$OpportunityIdByExternalId = @{}
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT Id, LDGCRM_External_ID__c FROM Opportunity WHERE LDGCRM_External_ID__c != null" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    if ($Row.LDGCRM_External_ID__c) { $OpportunityIdByExternalId[$Row.LDGCRM_External_ID__c] = $Row.Id }
}
Write-Host "$($ContactIdByExternalId.Count) Contacts, $($OpportunityIdByExternalId.Count) Opportunities resolvable."

# --- What already exists, so this can be re-run safely ---------------------
$ExistingKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$ExistingPrimaryByOpportunity = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Row in @(Invoke-SalesforceQuery -Soql "SELECT Id, OpportunityId, ContactId, Role, IsPrimary FROM OpportunityContactRole" -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
    $ExistingKeys.Add("$($Row.OpportunityId)|$($Row.ContactId)|$($Row.Role)") | Out-Null
    if ($Row.IsPrimary -eq $true -or "$($Row.IsPrimary)" -eq "True") {
        $ExistingPrimaryByOpportunity.Add($Row.OpportunityId) | Out-Null
    }
}
Write-Host "$($ExistingKeys.Count) OpportunityContactRole rows already exist."

$InsertRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()
$AlreadyExists = 0
# Salesforce allows only ONE primary contact role per Opportunity - track which
# Opportunities have already been given one, across this run AND what's in the org.
$PrimaryClaimed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($OppId in $ExistingPrimaryByOpportunity) { $PrimaryClaimed.Add($OppId) | Out-Null }

foreach ($Row in $AirtableOpportunityContacts) {
    # BEWARE: 'Opportunity Record ID' on THIS table is the row's OWN record id,
    # not a link to an Opportunity - 0 of its 520 values are real Opportunity
    # ids, and every one equals the row's own .id. That inverts the convention
    # every other table follows, where "<X> Record ID" IS the link to X. The
    # real link is 'Opportunity Record ID (from Opportunities)' (520/520 valid),
    # a lookup column Airtable names after its source. Using the obvious-looking
    # column skipped all 520 rows.
    $OpportunityExternalId = ""
    $RawOpportunity = $Row.fields.'Opportunity Record ID (from Opportunities)'
    if ($RawOpportunity) { $OpportunityExternalId = @($RawOpportunity)[0] }
    $ContactExternalId = $RowToContactExternalId[$Row.id]

    $OpportunityId = $null
    if ($OpportunityExternalId) { $OpportunityId = $OpportunityIdByExternalId[$OpportunityExternalId] }
    $ContactId = $null
    if ($ContactExternalId) { $ContactId = $ContactIdByExternalId[$ContactExternalId] }

    if (-not $OpportunityId -or -not $ContactId) {
        $Missing = @()
        if (-not $OpportunityId) { $Missing += "Opportunity $OpportunityExternalId" }
        if (-not $ContactId) { $Missing += "Contact (from row $($Row.id))" }
        $SkippedRows.Add([PSCustomObject]@{
            AirtableRowId         = $Row.id
            ContactName           = $Row.fields.'Contact'
            Email                 = $Row.fields.Email
            OpportunityExternalId = $OpportunityExternalId
            NotResolved           = ($Missing -join "; ")
            Reason                = "Both sides must resolve to a real Salesforce Id. The missing side was withheld by its own load - re-run once it exists."
        })
        continue
    }

    # One record per Contact Type, most senior first so IsPrimary lands on it.
    $Roles = @($Row.fields.'Contact Type') | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
    if ($Roles.Count -eq 0) { $Roles = @("") }
    $Roles = @($Roles | Sort-Object { Get-RoleRank $_ })

    $WantsPrimary = [bool]$Row.fields.Primary

    foreach ($Role in $Roles) {
        $Key = "$OpportunityId|$ContactId|$Role"
        if ($ExistingKeys.Contains($Key)) { $AlreadyExists++; continue }

        $IsPrimary = "false"
        if ($WantsPrimary -and -not $PrimaryClaimed.Contains($OpportunityId)) {
            $IsPrimary = "true"
            $PrimaryClaimed.Add($OpportunityId) | Out-Null
        }

        $InsertRows.Add([PSCustomObject]([ordered]@{
            OpportunityId         = $OpportunityId
            ContactId             = $ContactId
            Role                  = $Role
            IsPrimary             = $IsPrimary
            # Not a key - just traceability back to the Airtable row.
            LDGCRM_External_ID__c = "$($Row.id)|$Role"
        }))
        $ExistingKeys.Add($Key) | Out-Null   # guard against duplicates inside this run
    }
}

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$InsertFile = Join-Path $LoadDir "OpportunityContactRole-insert.csv"
$SkippedFile = Join-Path $LogDir "OpportunityContactRole-skipped-$Timestamp.csv"

if ($InsertRows.Count -gt 0) { Export-DataLoaderCsv -InputObject $InsertRows.ToArray() -Path $InsertFile }
if ($SkippedRows.Count -gt 0) { $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8 }

$PrimaryCount = @($InsertRows | Where-Object { $_.IsPrimary -eq "true" }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " OPPORTUNITY CONTACT ROLE PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("{0,-52} {1,8:N0}" -f "Airtable Opportunity Contact rows", $AirtableOpportunityContacts.Count)
Write-Host ("{0,-52} {1,8:N0}" -f "Ready to INSERT (one row per role)", $InsertRows.Count)
Write-Host ("{0,-52} {1,8:N0}" -f "  ...flagged IsPrimary", $PrimaryCount)
Write-Host ("{0,-52} {1,8:N0}" -f "Already in the org (skipped, re-run safe)", $AlreadyExists)
Write-Host ("{0,-52} {1,8:N0}" -f "Skipped - Opportunity or Contact unresolved", $SkippedRows.Count)
Write-Host ""
Write-Host "Role distribution:" -ForegroundColor Cyan
$InsertRows | Group-Object Role | Sort-Object Count -Descending | ForEach-Object {
    Write-Host ("    {0,-24} {1,6:N0}" -f $_.Name, $_.Count)
}
Write-Host ""

if ($InsertRows.Count -gt 0) {
    Write-Host "Insert file (NO external-ID upsert possible - see this script's header):" -ForegroundColor Cyan
    Write-Host $InsertFile
    Write-Host "Load with:  -Operation Insert" -ForegroundColor Yellow
}
if ($SkippedRows.Count -gt 0) {
    Write-Host "Skipped rows for review:" -ForegroundColor Yellow
    Write-Host $SkippedFile
}

}
finally {
    Stop-ScriptLog
}
