#Requires -Version 5.1

<#
    Readiness check for a migration load. Read-only: queries and describes only,
    so it takes no confirmation token and runs against any environment including
    Prod. Fixes nothing - each finding names the command that would.

    Checks:
      1. Config      .env, Airtable token shape (PAT starts "pat"), data/ and
                     logs/ writable, production Account export present.
      2. Airtable    all 10 Migration tables pulled, row counts, export age,
                     and identity-platform column shape (multi-select, not
                     rec... ids).
      3. Environments  each registry entry probed for reachability and identity.
                     Only the target failing is a FAIL.
      4. Access      running user, profile, UserType; fallback owner resolves.
      5. Metadata    each object exists, LDGCRM_External_ID__c is externalId,
                     and every column in each load CSV resolves to a writable
                     field. Driven off the CSVs so it tracks what the transforms
                     currently emit.
      6. Automation  nine Flows active, Dev-only flow absent outside Dev,
                     Contact trigger switch, Market Segment resolvability.
                     Reported here; Invoke-FullMigrationLoad.ps1 enforces them.

    Exit 0 unless a check FAILED; warnings exit 0.
    Runs inside Invoke-FullMigrationLoad.ps1 as -Readiness.
#>

[CmdletBinding()]
param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (Common.Orgs.ps1).
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # Probe every environment in the registry for reachability, not just the
    # target. Costs one `sf org display` per environment.
    [switch]$AllEnvironments,

    # Skip everything that talks to Salesforce. Useful on a machine with no org
    # authorized yet, to check the bundle and the Airtable pull alone.
    [switch]$SkipOrgChecks,

    # Print every check, not just the ones that are not PASS.
    [switch]$Detailed,

    # Warn if the newest Airtable JSON is older than this.
    [int]$MaxExportAgeDays = 7,

    [string]$FallbackOwnerEmail = "peter.marks@gsa.gov"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

# ============================================================================
#  RESULT COLLECTION
# ============================================================================
# Single path for all findings: printed line, summary, CSV and exit code.

$Script:Results = New-Object System.Collections.Generic.List[object]
$Script:SectionName = ""
$Script:SectionStart = 0

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "WARN", "FAIL", "INFO")][string]$Status,
        [string]$Detail = "",
        # Command or action that resolves a WARN/FAIL.
        [string]$Fix = ""
    )

    $Script:Results.Add([PSCustomObject]@{
        Category = $Category
        Name     = $Name
        Status   = $Status
        Detail   = $Detail
        Fix      = $Fix
    })
}

function Complete-Section {
    # One line per section. Individual checks print only when not PASS, or with
    # -Detailed. The CSV always holds every result.
    if (-not $Script:SectionName) { return }

    $Slice = @($Script:Results | Select-Object -Skip $Script:SectionStart)
    if ($Slice.Count -eq 0) { return }

    $Fails = @($Slice | Where-Object { $_.Status -eq "FAIL" })
    $Warns = @($Slice | Where-Object { $_.Status -eq "WARN" })
    $Infos = @($Slice | Where-Object { $_.Status -eq "INFO" })
    $Oks   = @($Slice | Where-Object { $_.Status -eq "PASS" })

    $Parts = @("{0} ok" -f $Oks.Count)
    if ($Warns.Count -gt 0) { $Parts += "{0} warning{1}" -f $Warns.Count, $(if ($Warns.Count -eq 1) { "" } else { "s" }) }
    if ($Fails.Count -gt 0) { $Parts += "{0} FAILED" -f $Fails.Count }
    if ($Infos.Count -gt 0) { $Parts += "{0} n/a" -f $Infos.Count }

    $Colour = "Green"
    if ($Warns.Count -gt 0) { $Colour = "Yellow" }
    if ($Fails.Count -gt 0) { $Colour = "Red" }

    Write-Host ("  {0,-14} {1}" -f $Script:SectionName, ($Parts -join ", ")) -ForegroundColor $Colour

    # Only what needs action. INFO and PASS are counted, not listed.
    $Show = if ($Detailed) { $Slice } else { @($Slice | Where-Object { $_.Status -eq "WARN" -or $_.Status -eq "FAIL" }) }
    foreach ($R in $Show) {
        $RowColour = "DarkGray"
        if ($R.Status -eq "WARN") { $RowColour = "Yellow" }
        elseif ($R.Status -eq "FAIL") { $RowColour = "Red" }
        Write-Host ("      {0,-5} {1} - {2}" -f $R.Status, $R.Name, $R.Detail) -ForegroundColor $RowColour
        if ($R.Fix -and ($R.Status -eq "WARN" -or $R.Status -eq "FAIL")) {
            Write-Host ("            fix: {0}" -f $R.Fix) -ForegroundColor DarkGray
        }
    }
}

function Write-Section {
    param([string]$Title)
    Complete-Section
    $Script:SectionName = $Title
    $Script:SectionStart = $Script:Results.Count
}

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Test-LdgcrmReadiness"

try {

$TargetAlias = ""
if (-not $SkipOrgChecks) {
    $TargetAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias
}

Write-Host ""
Write-Host "LDGCRM READINESS CHECK" -ForegroundColor Cyan
if ($SkipOrgChecks) {
    Write-Host "Read-only. Org checks skipped (-SkipOrgChecks)." -ForegroundColor DarkGray
}
else {
    Write-Host ("Read-only. Target {0} ({1})." -f $Environment, $TargetAlias) -ForegroundColor DarkGray
}
Write-Host ""

$Root = Get-LdgcrmRoot

# ============================================================================
#  1. BUNDLE AND CONFIGURATION
# ============================================================================
Write-Section "Config"

$EnvFile = Join-Path $Root ".env"
if (Test-Path -LiteralPath $EnvFile) {
    Add-Result -Category "Config" -Name ".env present" -Status "PASS" -Detail $EnvFile
    Import-DotEnv

    $Token = $env:AIRTABLE_API_KEY
    $BaseId = $env:AIRTABLE_BASE_ID

    if ([string]::IsNullOrWhiteSpace($Token)) {
        Add-Result -Category "Config" -Name "AIRTABLE_API_KEY set" -Status "FAIL" `
            -Detail "empty" -Fix "Add a Personal Access Token to .env. See docs/SETUP.md."
    }
    elseif ($Token -like "key*") {
        # Named after the deprecated concept, so the wrong VALUE looks right.
        Add-Result -Category "Config" -Name "AIRTABLE_API_KEY set" -Status "FAIL" `
            -Detail "looks like a legacy API key (starts 'key')" `
            -Fix "Airtable removed key... API keys in Feb 2024. Create a Personal Access Token (starts 'pat')."
    }
    elseif ($Token -notlike "pat*") {
        Add-Result -Category "Config" -Name "AIRTABLE_API_KEY set" -Status "WARN" `
            -Detail "does not start 'pat'" `
            -Fix "A Personal Access Token starts 'pat'. Verify the value in .env."
    }
    else {
        Add-Result -Category "Config" -Name "AIRTABLE_API_KEY set" -Status "PASS" -Detail "PAT shape ok"
    }

    if ([string]::IsNullOrWhiteSpace($BaseId)) {
        Add-Result -Category "Config" -Name "AIRTABLE_BASE_ID set" -Status "FAIL" -Detail "empty" `
            -Fix "Add the app... base id to .env."
    }
    elseif ($BaseId -notlike "app*") {
        Add-Result -Category "Config" -Name "AIRTABLE_BASE_ID set" -Status "WARN" `
            -Detail "does not start 'app'" -Fix "A base id starts 'app'."
    }
    else {
        Add-Result -Category "Config" -Name "AIRTABLE_BASE_ID set" -Status "PASS" -Detail $BaseId
    }
}
else {
    Add-Result -Category "Config" -Name ".env present" -Status "FAIL" -Detail "not found at $EnvFile" `
        -Fix "Copy-Item .env.example .env, then fill it in. See docs/SETUP.md."
}

# Writability, checked by actually writing - permissions on Windows are not
# reliably inferable from anything cheaper.
foreach ($Pair in @(
    @{ Name = "data/ writable"; Path = (Join-Path $Root "data") },
    @{ Name = "logs/ writable"; Path = (Join-Path $Root "logs") }
)) {
    try {
        if (-not (Test-Path -LiteralPath $Pair.Path)) {
            New-Item -ItemType Directory -Path $Pair.Path -Force | Out-Null
        }
        $Probe = Join-Path $Pair.Path (".readiness-probe-{0}" -f $Timestamp)
        [System.IO.File]::WriteAllText($Probe, "probe")
        Remove-Item -LiteralPath $Probe -Force
        Add-Result -Category "Config" -Name $Pair.Name -Status "PASS" -Detail $Pair.Path
    }
    catch {
        Add-Result -Category "Config" -Name $Pair.Name -Status "FAIL" -Detail $_.Exception.Message `
            -Fix "Check folder permissions on $($Pair.Path)."
    }
}

# The Account bootstrap source. Only meaningful where Accounts may be rebuilt -
# in Full and Prod its absence is correct, not a gap.
if (Test-LdgcrmAccountRebuildAllowed -Environment $Environment) {
    try {
        $ProdExport = Resolve-ProdAccountExportPath
        if ($ProdExport) {
            $Format = Get-ProdAccountExportFormat -Path $ProdExport
            Add-Result -Category "Config" -Name "Production Account export" -Status "PASS" `
                -Detail ("{0} ({1})" -f (Split-Path $ProdExport -Leaf), $Format)
        }
        else {
            Add-Result -Category "Config" -Name "Production Account export" -Status "WARN" `
                -Detail "none in data/prod-accounts/" `
                -Fix "Needed by Invoke-AccountBootstrap.ps1 after a factory reset. See data/prod-accounts/README.md."
        }
    }
    catch {
        Add-Result -Category "Config" -Name "Production Account export" -Status "WARN" `
            -Detail $_.Exception.Message -Fix "See data/prod-accounts/README.md."
    }
}
else {
    Add-Result -Category "Config" -Name "Production Account export" -Status "INFO" `
        -Detail "not applicable - Accounts are never rebuilt in $Environment"
}

# ============================================================================
#  2. AIRTABLE PULL
# ============================================================================
Write-Section "Airtable"

$ExportDir = Join-Path $Root "data\airtable-exports"
$Catalog = @(Get-LdgcrmAirtableTableCatalog)
$MigrationTables = @($Catalog | Where-Object { $_.Purpose -eq "Migration" })

if (-not (Test-Path -LiteralPath $ExportDir)) {
    Add-Result -Category "Airtable" -Name "Export folder" -Status "FAIL" -Detail "missing: $ExportDir" `
        -Fix ".\powershell-scripts\Get-AirtableExport.ps1"
}
else {
    $MissingTables = New-Object System.Collections.Generic.List[string]
    $EmptyTables = New-Object System.Collections.Generic.List[string]
    $RowCounts = [ordered]@{}
    $NewestWrite = $null

    foreach ($Table in $Catalog) {
        $Path = Join-Path $ExportDir ("{0}.json" -f $Table.Label)
        if (-not (Test-Path -LiteralPath $Path)) {
            if ($Table.Purpose -eq "Migration") { $MissingTables.Add($Table.Label) }
            continue
        }

        $Info = Get-Item -LiteralPath $Path
        if ($null -eq $NewestWrite -or $Info.LastWriteTime -gt $NewestWrite) { $NewestWrite = $Info.LastWriteTime }

        if ($Table.Purpose -ne "Migration") { continue }

        try {
            # Assigned BARE, never @(...) around the call - see the caller
            # contract on Import-AirtableTable. Wrapping it reports 1 row per
            # table, which is exactly the bug this line used to have.
            $Rows = Import-AirtableTable -Label $Table.Label
            $Count = @($Rows).Count
            $RowCounts[$Table.Label] = $Count
            if ($Count -eq 0) { $EmptyTables.Add($Table.Label) }
        }
        catch {
            $RowCounts[$Table.Label] = -1
            $EmptyTables.Add($Table.Label)
        }
    }

    if ($MissingTables.Count -eq 0) {
        Add-Result -Category "Airtable" -Name "Migration tables present" -Status "PASS" `
            -Detail ("all {0}" -f $MigrationTables.Count)
    }
    else {
        Add-Result -Category "Airtable" -Name "Migration tables present" -Status "FAIL" `
            -Detail ("missing: {0}" -f ($MissingTables -join ", ")) `
            -Fix ".\powershell-scripts\Get-AirtableExport.ps1 -MigrationOnly"
    }

    if ($EmptyTables.Count -gt 0) {
        Add-Result -Category "Airtable" -Name "Tables with rows" -Status "FAIL" `
            -Detail ("empty or unreadable: {0}" -f ($EmptyTables -join ", ")) `
            -Fix "Re-pull. An empty table silently withholds every record that depends on it."
    }
    else {
        Add-Result -Category "Airtable" -Name "Tables with rows" -Status "PASS" `
            -Detail (($RowCounts.Keys | ForEach-Object { "{0}={1}" -f $_, $RowCounts[$_] }) -join "  ")
    }

    if ($null -ne $NewestWrite) {
        $AgeDays = [math]::Round(((Get-Date) - $NewestWrite).TotalDays, 1)
        if ($AgeDays -gt $MaxExportAgeDays) {
            Add-Result -Category "Airtable" -Name "Export freshness" -Status "WARN" `
                -Detail ("newest file is {0} day(s) old" -f $AgeDays) `
                -Fix "Re-pull unless you deliberately want this snapshot. Re-pulling shifts every documented count."
        }
        else {
            Add-Result -Category "Airtable" -Name "Export freshness" -Status "PASS" `
                -Detail ("newest file is {0} day(s) old" -f $AgeDays)
        }
    }

    # --- Column SHAPE, not just presence. -----------------------------------
    # The failure this catches: Airtable converted Opportunities' identity
    # platform columns from linked records (rec... ids) to plain multi-selects.
    # A transform written for one shape reads the other as garbage, and 453
    # values went quietly missing. Build-OpportunityLoad.ps1 hard-fails on it,
    # but only once you are mid-load; this reports it up front.
    if ($RowCounts.Contains("Opportunities") -and $RowCounts["Opportunities"] -gt 0) {
        try {
            $Opps = Import-AirtableTable -Label "Opportunities"
            $Unresolved = 0
            $Checked = 0
            foreach ($Row in $Opps) {
                foreach ($Col in @("Existing Identity Platforms", "Alternative Identity Platforms")) {
                    $Value = $Row.fields.$Col
                    if ($null -eq $Value) { continue }
                    foreach ($Item in @($Value)) {
                        $Checked++
                        if ("$Item" -match '^rec[A-Za-z0-9]{14}$') { $Unresolved++ }
                    }
                }
            }
            if ($Unresolved -gt 0) {
                Add-Result -Category "Airtable" -Name "Identity platform column shape" -Status "FAIL" `
                    -Detail ("{0} of {1} values are still rec... ids" -f $Unresolved, $Checked) `
                    -Fix "The export predates Airtable's conversion to multi-select. Re-run Get-AirtableExport.ps1."
            }
            else {
                Add-Result -Category "Airtable" -Name "Identity platform column shape" -Status "PASS" `
                    -Detail ("{0} values, all plain names" -f $Checked)
            }
        }
        catch {
            Add-Result -Category "Airtable" -Name "Identity platform column shape" -Status "WARN" `
                -Detail $_.Exception.Message
        }
    }
}

# ============================================================================
#  3. ENVIRONMENTS
# ============================================================================
Write-Section "Environments"

if ($SkipOrgChecks) {
    Add-Result -Category "Environment" -Name "Environment probe" -Status "INFO" -Detail "skipped (-SkipOrgChecks)"
}
else {
    $EnvTable = Get-LdgcrmEnvironmentTable
    $ToProbe = @($Environment)
    if ($AllEnvironments) { $ToProbe = @($EnvTable.Keys) }

    foreach ($Key in $ToProbe) {
        $Entry = $EnvTable[$Key]
        $Name = "{0} ({1})" -f $Key, $Entry.Alias

        try {
            Assert-LdgcrmOrgTarget -Environment $Key -Quiet | Out-Null
            $Status = "PASS"
            $Detail = $Entry.InstanceUrl
            if ($Entry.IsProduction) { $Detail = "PRODUCTION - " + $Detail }
            Add-Result -Category "Environment" -Name $Name -Status $Status -Detail $Detail
        }
        catch {
            # Not reachable is not necessarily wrong: Full and Prod are
            # deliberately unauthorized on most machines. Only the TARGET
            # environment being unreachable is a failure.
            $Message = $_.Exception.Message
            if ($Message.Length -gt 70) { $Message = $Message.Substring(0, 70) + "..." }

            if ($Key -eq $Environment) {
                Add-Result -Category "Environment" -Name $Name -Status "FAIL" -Detail $Message `
                    -Fix ("sf org login web --alias {0} --instance-url {1}" -f $Entry.Alias, $Entry.InstanceUrl)
            }
            else {
                Add-Result -Category "Environment" -Name $Name -Status "INFO" -Detail "not authorized here"
            }
        }
    }
}

# ============================================================================
#  4-6. TARGET ORG
# ============================================================================
# Every object this migration touches, with the CSV each step loads. The CSV is
# how the field check stays self-maintaining - see the header.
$MigrationObjects = @(
    [PSCustomObject]@{ Object = "LDGCRM_Market_Segment__c";         Csv = "LDGCRM_Market_Segment__c-upsert.csv" }
    [PSCustomObject]@{ Object = "LDGCRM_Impediment__c";             Csv = "LDGCRM_Impediment__c-upsert.csv" }
    [PSCustomObject]@{ Object = "Account";                          Csv = "Account-update.csv" }
    [PSCustomObject]@{ Object = "LDGCRM_Partner_Account__c";        Csv = "LDGCRM_Partner_Account__c-upsert.csv" }
    [PSCustomObject]@{ Object = "Contact";                          Csv = "Contact-upsert.csv" }
    [PSCustomObject]@{ Object = "Opportunity";                      Csv = "Opportunity-upsert.csv" }
    [PSCustomObject]@{ Object = "LDGCRM_application__c";            Csv = "LDGCRM_application__c-upsert.csv" }
    [PSCustomObject]@{ Object = "LDGCRM_Opportunity_Impediment__c"; Csv = "LDGCRM_Opportunity_Impediment__c-upsert.csv" }
    [PSCustomObject]@{ Object = "LDGCRM_Application_Contact__c";    Csv = "LDGCRM_Application_Contact__c-upsert.csv" }
    [PSCustomObject]@{ Object = "OpportunityContactRole";           Csv = "OpportunityContactRole-insert.csv" }
)

if (-not $SkipOrgChecks) {

    # ------------------------------------------------------------------------
    #  4. ACCESS
    # ------------------------------------------------------------------------
    Write-Section "Access"

    # Identify the running user from the CLI, then look up what that user can
    # actually do. Profile and UserType matter: an ACTIVE user can still be
    # ineligible to own records (Chatter Free, portal, community), which fails a
    # load with OP_WITH_INVALID_USER_TYPE_EXCEPTION - an error naming neither the
    # field nor the user.
    $DisplayJson = & sf org display --target-org $TargetAlias --json
    if ($LASTEXITCODE -ne 0) {
        Add-Result -Category "Access" -Name "Authenticated as" -Status "FAIL" -Detail "sf org display failed" `
            -Fix "Re-authenticate: sf org login web --alias $TargetAlias"
    }
    else {
        $Display = $DisplayJson | ConvertFrom-Json
        $Username = $Display.result.username
        $Escaped = $Username -replace "'", "\'"

        $Me = @(Invoke-SalesforceQuery `
            -Soql ("SELECT Name, Profile.Name, UserType, IsActive FROM User WHERE Username = '{0}'" -f $Escaped) `
            -OrgAlias $TargetAlias -ApiVersion $ApiVersion)

        if ($Me.Count -eq 1) {
            Add-Result -Category "Access" -Name "Authenticated as" -Status "PASS" `
                -Detail ("{0} ({1}, {2})" -f $Username, $Me[0].Profile.Name, $Me[0].UserType)
        }
        else {
            Add-Result -Category "Access" -Name "Authenticated as" -Status "PASS" -Detail $Username
        }
    }

    try {
        $Owner = Resolve-FallbackOwnerId -Email $FallbackOwnerEmail -OrgAlias $TargetAlias -ApiVersion $ApiVersion
        Add-Result -Category "Access" -Name "Fallback owner resolves" -Status "PASS" `
            -Detail ("{0} -> {1}" -f $FallbackOwnerEmail, $Owner)
    }
    catch {
        Add-Result -Category "Access" -Name "Fallback owner resolves" -Status "FAIL" `
            -Detail $_.Exception.Message `
            -Fix "Every transform resolves this and throws without it. Pass -FallbackOwnerEmail, or activate the user."
    }

    # ------------------------------------------------------------------------
    #  5. METADATA
    # ------------------------------------------------------------------------
    Write-Section "Metadata"

    $LoadDir = Join-Path $Root "data\salesforce-loads"

    foreach ($Entry in $MigrationObjects) {
        $ObjectName = $Entry.Object

        try {
            $Fields = Get-SalesforceFieldMetadata -ObjectApiName $ObjectName -OrgAlias $TargetAlias -ApiVersion $ApiVersion
        }
        catch {
            Add-Result -Category "Metadata" -Name $ObjectName -Status "FAIL" -Detail "describe failed: $($_.Exception.Message)" `
                -Fix "The object does not exist in this org, or you cannot see it. Needs a change set."
            continue
        }

        # External ID must still be an external id, or every upsert breaks.
        # OpportunityContactRole is the documented exception: Salesforce forbids
        # External ID fields on that object entirely, which is why it is the one
        # object loaded by insert + read-then-diff.
        $ExtId = $Fields["LDGCRM_External_ID__c"]
        if ($ObjectName -eq "OpportunityContactRole") {
            if ($ExtId) {
                Add-Result -Category "Metadata" -Name "$ObjectName external id" -Status "INFO" `
                    -Detail "present, externalId=$($ExtId.externalId) - insert+diff by design, not upsert"
            }
        }
        elseif (-not $ExtId) {
            Add-Result -Category "Metadata" -Name "$ObjectName external id" -Status "FAIL" `
                -Detail "LDGCRM_External_ID__c does not exist" -Fix "Needs a change set."
        }
        elseif (-not $ExtId.externalId) {
            Add-Result -Category "Metadata" -Name "$ObjectName external id" -Status "FAIL" `
                -Detail "LDGCRM_External_ID__c is not marked External Id" `
                -Fix "Upsert-on-external-id cannot work. Needs a change set."
        }
        else {
            Add-Result -Category "Metadata" -Name "$ObjectName external id" -Status "PASS" -Detail "externalId=true"
        }

        # Column-by-column check against whatever the transforms last produced.
        $CsvPath = Join-Path $LoadDir $Entry.Csv
        if (-not (Test-Path -LiteralPath $CsvPath)) {
            Add-Result -Category "Metadata" -Name "$ObjectName load columns" -Status "INFO" `
                -Detail "no load CSV on disk - run the transforms to check columns"
            continue
        }

        $Header = @(Get-Content -LiteralPath $CsvPath -TotalCount 1 -Encoding UTF8)
        if ($Header.Count -eq 0) {
            Add-Result -Category "Metadata" -Name "$ObjectName load columns" -Status "WARN" -Detail "CSV is empty"
            continue
        }

        $Columns = @($Header[0] -split "," | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
        $Missing = New-Object System.Collections.Generic.List[string]
        $NotWritable = New-Object System.Collections.Generic.List[string]

        foreach ($Column in $Columns) {
            # Id is not a field to write, it is the addressing key on an Update.
            if ($Column -eq "Id") { continue }

            $FieldName = $Column
            if ($Column -match '\.') {
                # Relationship form: <Rel>__r.<ExternalIdField> or Account.<f>.
                # Verify the LOOKUP exists on this object, not the far-side field.
                $RelationshipName = ($Column -split '\.')[0]
                if ($RelationshipName -match '__r$') {
                    $FieldName = ($RelationshipName -replace '__r$', '__c')
                }
                else {
                    # Standard relationship, e.g. Account.LDGCRM_External_ID__c
                    $FieldName = $RelationshipName + "Id"
                }
            }

            $Field = $Fields[$FieldName]
            if (-not $Field) { $Missing.Add("$Column (looked for $FieldName)"); continue }
            if (-not ($Field.createable -or $Field.updateable)) { $NotWritable.Add($Column) }
        }

        if ($Missing.Count -gt 0) {
            Add-Result -Category "Metadata" -Name "$ObjectName load columns" -Status "FAIL" `
                -Detail ("{0} of {1} do not exist: {2}" -f $Missing.Count, $Columns.Count, ($Missing -join "; ")) `
                -Fix "The load will fail on this object. The field must be added by CHANGE SET."
        }
        elseif ($NotWritable.Count -gt 0) {
            Add-Result -Category "Metadata" -Name "$ObjectName load columns" -Status "FAIL" `
                -Detail ("not writable: {0}" -f ($NotWritable -join "; ")) `
                -Fix "A formula/rollup field, or one your profile cannot edit. Check FLS first."
        }
        else {
            Add-Result -Category "Metadata" -Name "$ObjectName load columns" -Status "PASS" `
                -Detail ("all {0} columns exist and are writable" -f $Columns.Count)
        }
    }

    # ------------------------------------------------------------------------
    #  6. AUTOMATION
    # ------------------------------------------------------------------------
    # Reported, never changed. The load enforces these itself; duplicating the
    # enforcement here would mean two places to keep honest.
    Write-Section "Automation"

    try {
        $Segments = @(Invoke-SalesforceQuery `
            -Soql "SELECT Id, LDGCRM_External_ID__c FROM LDGCRM_Market_Segment__c" `
            -OrgAlias $TargetAlias -ApiVersion $ApiVersion)
        $Resolvable = @($Segments | Where-Object { $_.LDGCRM_External_ID__c }).Count
        if ($Resolvable -eq 0) {
            # Normal after a factory reset: the reset deletes the tagged
            # segments and step 1 of the load recreates them. Only a problem if
            # that step is skipped, which this script cannot know.
            Add-Result -Category "Automation" -Name "Market Segments resolvable" -Status "INFO" `
                -Detail ("{0} present, 0 tagged - loaded by the MarketSegment step" -f $Segments.Count)
        }
        else {
            Add-Result -Category "Automation" -Name "Market Segments resolvable" -Status "PASS" `
                -Detail ("{0} of {1} carry an external id" -f $Resolvable, $Segments.Count)
        }
    }
    catch {
        Add-Result -Category "Automation" -Name "Market Segments resolvable" -Status "WARN" -Detail $_.Exception.Message
    }

    try {
        $Controls = @(Invoke-SalesforceQuery `
            -Soql "SELECT Id, On__c FROM TriggerControls__c WHERE Name = 'Contact'" `
            -OrgAlias $TargetAlias -ApiVersion $ApiVersion)
        if ($Controls.Count -eq 1) {
            Add-Result -Category "Automation" -Name "Contact trigger kill switch" -Status "PASS" `
                -Detail ("present, On__c={0}" -f $Controls[0].On__c)
        }
        else {
            Add-Result -Category "Automation" -Name "Contact trigger kill switch" -Status "FAIL" `
                -Detail ("expected 1 TriggerControls__c named 'Contact', found {0}" -f $Controls.Count) `
                -Fix "Without it the Contact step cannot bypass the FCIC trigger, which creates a junk Account per blank AccountId."
        }
    }
    catch {
        Add-Result -Category "Automation" -Name "Contact trigger kill switch" -Status "WARN" -Detail $_.Exception.Message
    }

    # The nine Flows. Blank Market Segment across three objects is what an
    # inactive Flow costs, and no row count anywhere would show it.
    try {
        $FlowState = @(Get-LdgcrmFlowState -Org $TargetAlias -Version $ApiVersion)
        $StateByName = @{}
        foreach ($F in $FlowState) { $StateByName[$F.DeveloperName] = $F }

        # Check the NINE BY NAME, not "how many LDGCRM flows are active". A
        # count is the wrong test: Dev legitimately carries a tenth (the
        # developer delete flow), so "10 of 10 active" looked like a pass while
        # saying nothing about whether the nine that matter were on.
        $Expected = @(Get-LdgcrmExpectedActiveFlows)
        $Absent = New-Object System.Collections.Generic.List[string]
        $Inactive = New-Object System.Collections.Generic.List[string]
        $Stale = New-Object System.Collections.Generic.List[string]

        foreach ($Name in $Expected) {
            if (-not $StateByName.ContainsKey($Name)) { $Absent.Add($Name); continue }
            $F = $StateByName[$Name]
            if (-not $F.IsActive) { $Inactive.Add($Name); continue }
            if ($null -ne $F.LatestVersion -and $null -ne $F.ActiveVersion -and $F.LatestVersion -gt $F.ActiveVersion) {
                $Stale.Add(("{0} (active v{1}, latest v{2})" -f $Name, $F.ActiveVersion, $F.LatestVersion))
            }
        }

        if ($Absent.Count -gt 0) {
            Add-Result -Category "Automation" -Name "LDGCRM Flows active" -Status "FAIL" `
                -Detail ("{0} ABSENT from this org: {1}" -f $Absent.Count, ($Absent -join ", ")) `
                -Fix "An absent flow cannot be activated - it needs a CHANGE SET. The load cannot create one."
        }
        elseif ($Inactive.Count -gt 0) {
            Add-Result -Category "Automation" -Name "LDGCRM Flows active" -Status "WARN" `
                -Detail ("{0} of {1} inactive: {2}" -f $Inactive.Count, $Expected.Count, ($Inactive -join ", ")) `
                -Fix "The load switches these on itself, in every environment, before the first row is written."
        }
        else {
            Add-Result -Category "Automation" -Name "LDGCRM Flows active" -Status "PASS" `
                -Detail ("all {0} expected flows active" -f $Expected.Count)
        }

        if ($Stale.Count -gt 0) {
            Add-Result -Category "Automation" -Name "Flow versions current" -Status "WARN" `
                -Detail ($Stale -join "; ") `
                -Fix "A newer version is deployed in THIS org but never switched on. Activate it in Setup."
        }

        # The inverse check: the Dev-only delete flow must not have escaped.
        $Trespassing = New-Object System.Collections.Generic.List[string]
        if ($Environment -ne "Dev") {
            foreach ($Name in @(Get-LdgcrmDevOnlyFlows)) {
                if ($StateByName.ContainsKey($Name)) { $Trespassing.Add($Name) }
            }
        }
        if ($Trespassing.Count -gt 0) {
            Add-Result -Category "Automation" -Name "Dev-only flows absent" -Status "FAIL" `
                -Detail ($Trespassing -join ", ") `
                -Fix "This flow BULK-DELETES migrated records and must exist only in Dev. Find out how it got here."
        }
        elseif ($Environment -ne "Dev") {
            Add-Result -Category "Automation" -Name "Dev-only flows absent" -Status "PASS" -Detail "none present"
        }
    }
    catch {
        Add-Result -Category "Automation" -Name "LDGCRM Flows active" -Status "WARN" `
            -Detail ("could not read flow state: {0}" -f $_.Exception.Message)
    }
}

# ============================================================================
#  SUMMARY
# ============================================================================
Complete-Section

$Failed = @($Script:Results | Where-Object { $_.Status -eq "FAIL" })
$Warned = @($Script:Results | Where-Object { $_.Status -eq "WARN" })
$Passed = @($Script:Results | Where-Object { $_.Status -eq "PASS" })

$ReportPath = Join-Path (Get-LogDirectory -Category "data-migration") ("readiness-{0}.csv" -f $Timestamp)
$Script:Results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8

Write-Host ""
if ($Failed.Count -gt 0) {
    Write-Host ("NOT READY - {0} failed, {1} ok" -f $Failed.Count, $Passed.Count) -ForegroundColor Red
    Write-Host "All results: $ReportPath" -ForegroundColor DarkGray
    exit 1
}

$WarnSuffix = ""
if ($Warned.Count -gt 0) {
    $WarnSuffix = ", {0} warning{1}" -f $Warned.Count, $(if ($Warned.Count -eq 1) { "" } else { "s" })
}
Write-Host ("READY - {0} ok{1}" -f $Passed.Count, $WarnSuffix) -ForegroundColor Green
Write-Host "All results: $ReportPath" -ForegroundColor DarkGray

}
finally {
    Stop-ScriptLog
}
