#Requires -Version 5.1

<#
    THE CONSOLIDATED PRE-FLIGHT CHECK for a migration load (see CLAUDE.md,
    "METADATA IS NOT THE OPERATIONS TEAM'S JOB"). Validates that the target org
    is actually in a state where a load will produce correct data, and - with
    -ActivateFlows - preps the one part of that state the pipeline is allowed to
    change.

    WHY THIS EXISTS
    ===============
    QA was loaded on 2026-08-14 with 8,740 records and "0 unexpected failures"
    while EVERY LDGCRM Flow in the org was switched off. Nothing failed. Nothing
    was withheld. Object counts matched Dev exactly, so the Dev-vs-QA comparison
    passed too - flow activation does not change row counts, only field
    contents. The visible symptom was that Market Segment was blank on all 92
    Partner Accounts, all 842 Opportunities and all 1,026 Applications, because
    the three before-save Flows that derive it never ran.

    That is the failure mode this guards: not a load that breaks, but a load
    that succeeds against an org whose automation is off.

    WHAT IT CHECKS
    ==============
    1. Every flow in $Script:ExpectedActiveFlows exists in the target org and is
       ACTIVE.
    2. Every flow in $Script:DevOnlyFlows is ABSENT from any org except Dev.
       This is an inversion of check 1 and deliberately so - see that list.
    3. Any flow whose LATEST version is newer than its ACTIVE version, i.e.
       someone deployed a newer version and never activated it. An
       active-but-stale flow passes a naive "is it active?" test and is the
       harder of the two problems to spot.

    WHAT IT CANNOT CHECK - READ THIS BEFORE TRUSTING A PASS
    ======================================================
    It cannot compare this org's flow CONTENT against another org's. The bundle
    is self-contained and has no access to sfdx/, so it cannot diff what is
    running here against what the change set was built from.

    DO NOT TRY TO INFER THAT FROM VERSION NUMBERS - THEY ARE PER-ORG.
    A flow's VersionNumber is a local counter: every save in the source org
    increments that org's sequence, and every change set deployment increments
    the target's independently. Dev running v4 while QA runs v2 is the ordinary
    result of four saves there and two deployments here - it does NOT mean QA is
    two versions behind, and the two numbers are not comparable at all. (An
    earlier draft of this script asserted exactly that and was wrong; corrected
    2026-08-14 by the project owner.)

    So a clean pre-flight means "the flows in this org are on and each is
    running the newest version this org holds". Whether that version carries the
    intended logic is a change-set question, answered by whoever built it.
    Check 3 catches the one part of this that IS visible from inside one org:
    a newer version sitting in the org, deployed but never switched on.

    WHY ACTIVATION IS ALLOWED HERE AT ALL
    =====================================
    CLAUDE.md forbids the pipeline from deploying or retrieving metadata. Per
    the project owner (2026-08-14): "There is a difference between changing
    settings in the org via CLI and adding/updating core object definitions. We
    want change sets to migrate all xml, but allow for our pre-flight script to
    prep and validate the environment for a successful load."

    Activation flips FlowDefinition.Metadata.activeVersionNumber - an org
    setting pointing at a version that is ALREADY in the org. It moves no XML
    between orgs and creates no component. This script never deploys, never
    retrieves, and never creates a flow version; if a flow is missing or the
    wrong version, it says so precisely and stops, and someone builds a change
    set.

    NOT THE TriggerControls__c TOGGLE PATTERN - NOTHING IS RESTORED
    ==============================================================
    Invoke-SalesforceLoad.ps1's -DisableTriggerControl captures a value, flips
    it for the load, and puts it back in a finally. This does NOT do that, and
    the difference is intentional: a flow that had to be switched on for the
    load to be correct must STAY on afterwards, or the org goes straight back to
    silently producing wrong data for every record a human creates in the UI.
    Activation here is permanent and is announced as such at the gate.

    SAFE TO RUN ANY TIME. With no -ActivateFlows it touches nothing.
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (Common.Orgs.ps1). Set this
    # only to reach an org that isn't in the registry; doing so skips the
    # registry's identity checks.
    [string]$OrgAlias = "",

    [string]$ApiVersion = "67.0",

    <#
        Activate every expected flow that is present but inactive, and every
        flow whose active version is behind its latest. Without this the script
        is READ-ONLY and simply reports.

        Blocked in Prod - see the ValidateSet check below.
    #>
    [switch]$ActivateFlows,

    <#
        Limit -ActivateFlows to these flow API names. Empty (the default) means
        every flow that needs it.

        Normal use is to omit this: all nine flows are expected to be active,
        and activating all of them is the point of the pre-flight.

        It exists for the narrow cases where one flow must be handled on its
        own - re-activating a single flow someone switched off, or isolating one
        during troubleshooting - without touching the other eight.
    #>
    [string[]]$FlowName = @(),

    # Approve activation without a prompt: -Confirmation "ACTIVATE". A token
    # rather than a -Force switch, so it can't be copy-pasted from a script
    # expecting a different one. See Assert-LdgcrmTypedConfirmation.
    [string]$Confirmation = ""
)

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

<#
    THE EXPECTED-FLOW LIST IS HARD-CODED HERE, ON PURPOSE.

    The obvious implementation reads sfdx/force-app/main/default/flows/ and
    compares. The bundle cannot do that - it ships to the GSA Operations team as
    a bare /scripts folder with no sfdx/ anywhere above it, and resolving a path
    above the bundle root is the exact failure "scripts/ is a SELF-CONTAINED
    BUNDLE" exists to prevent.

    So this list is the single source of truth inside the bundle, the same
    pattern as $DefaultTables in Get-AirtableExport.ps1. If a flow is added,
    renamed or retired, update it HERE.

    Note LGDCRM_ on three of them - the transposed prefix is a real API-name
    typo in the org, not a mistake in this list.
#>
$Script:ExpectedActiveFlows = @(
    "LDGCRM_ApplicationContact_BeforeSave_NewRecordDuplicateCheck"
    "LDGCRM_Application_Before_Save_Assign_Market_Segment"
    "LDGCRM_Opportunity_Before_Save_Assign_Account_and_Market_Segment"
    "LDGCRM_Opportunity_Impediment_Before_Save_New_Record_Duplicate_Check"
    "LDGCRM_Partner_Account_After_Save_Update_Re_Parent_Cascade"
    "LDGCRM_Partner_Account_Before_Save_Create_Update_Market_Segment"
    "LGDCRM_Opportunity_After_Save_Update_Opportunity_Impediments"
    "LGDCRM_Opportunity_Before_Save_Update_Current_Status_Summary_DateTime"
    "LGDCRM_Opportunity_Impediment_Before_Save_Update_Blocked_Revenue"
)

<#
    THE INVERSE CHECK: these must NOT exist outside Dev.

    LDGCRM_Screen_Flow_Developer_Data_Delete_Flow is a screen flow whose entire
    job is to bulk-delete Account, Partner Account, Application, Application
    Contact, Market Segment, Opportunity and Opportunity Impediment records. It
    is a developer convenience and stays Active in Dev. It was removed from
    sfdx/manifest/package.xml and force-app on 2026-08-14 so it cannot be swept
    into a change set regenerated from the manifest.

    Listing it here rather than just ignoring it is the point: "absent" is the
    expected state, so FINDING it in QA/Full/Prod is a failure that wants
    investigating, not a note to suppress. Until this check existed, the only
    thing keeping it out of a non-Dev org was someone hand-picking change set
    contents.
#>
$Script:DevOnlyFlows = @(
    "LDGCRM_Screen_Flow_Developer_Data_Delete_Flow"
)

# Activation is a persistent org config change. In Prod it belongs to a human in
# Setup under change control, not to a load pipeline running unattended - the
# same reasoning that makes Invoke-AccountBootstrap.ps1 Dev/QA-only at bind
# time. Validation still runs everywhere, including Prod, because it is
# read-only and is exactly what you want before a production load.
if ($ActivateFlows -and $Environment -eq "Prod") {
    throw ("-ActivateFlows is not available for -Environment Prod. Activating a Flow in production is a " +
           "change-controlled action for a human in Setup. Re-run without -ActivateFlows to get the " +
           "report, and hand it to whoever owns production config.")
}

# Out-Null, not $Timestamp = : Start-ScriptLog returns a run timestamp for
# callers that name output files with it. This script writes no such files - its
# only output is the transcript and the exit code.
Start-ScriptLog -Category "data-migration" -ScriptName "Invoke-LoadPreflight" | Out-Null

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " LOAD PRE-FLIGHT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# | Out-Null because this RETURNS the parsed `sf org display` result, which
# carries the org's ACCESS TOKEN. Left uncaptured it prints into the script
# transcript. It also writes the target banner itself, so there is no separate
# Write-LdgcrmOrgBanner call here.
Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias | Out-Null
Write-Host ""

if ($ActivateFlows) {
    Write-Host "Mode: VALIDATE + ACTIVATE (this will change org configuration)" -ForegroundColor Yellow
}
else {
    Write-Host "Mode: VALIDATE ONLY - nothing in the org will be changed." -ForegroundColor Green
}
Write-Host ""

# ---------------------------------------------------------------------------
# Read the org's flow state
# ---------------------------------------------------------------------------

function Get-LdgcrmFlowState {
    <#
        Returns one row per LDGCRM/LGDCRM FlowDefinition in the org, carrying its
        active and latest version NUMBERS (the tooling object stores Ids, which
        are useless in a report).

        CALLER CONTRACT: wrap the call in @(), per Invoke-SalesforceQuery.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Org,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $Definitions = @(Invoke-SalesforceToolingQuery -Org $Org -Version $Version -Soql (
        "SELECT Id, DeveloperName, ActiveVersionId, LatestVersionId FROM FlowDefinition " +
        "WHERE DeveloperName LIKE 'LDGCRM%' OR DeveloperName LIKE 'LGDCRM%'"))

    # Version Id -> version number, so the report can say "v2 active, v4 latest"
    # instead of two 18-character Ids nobody can compare by eye.
    $Versions = @(Invoke-SalesforceToolingQuery -Org $Org -Version $Version -Soql (
        "SELECT Id, VersionNumber FROM Flow " +
        "WHERE Definition.DeveloperName LIKE 'LDGCRM%' OR Definition.DeveloperName LIKE 'LGDCRM%'"))

    $NumberById = @{}
    foreach ($V in $Versions) { $NumberById[$V.Id] = [int]$V.VersionNumber }

    $Rows = New-Object System.Collections.Generic.List[object]

    foreach ($D in $Definitions) {
        $ActiveNumber = $null
        $LatestNumber = $null

        if ($D.ActiveVersionId -and $NumberById.ContainsKey($D.ActiveVersionId)) {
            $ActiveNumber = $NumberById[$D.ActiveVersionId]
        }
        if ($D.LatestVersionId -and $NumberById.ContainsKey($D.LatestVersionId)) {
            $LatestNumber = $NumberById[$D.LatestVersionId]
        }

        $Rows.Add([PSCustomObject]@{
            DefinitionId  = $D.Id
            DeveloperName = $D.DeveloperName
            IsActive      = [bool]$D.ActiveVersionId
            ActiveVersion = $ActiveNumber
            LatestVersion = $LatestNumber
        })
    }

    # Plain array + caller wraps in @() -> return bare. See the Common.ps1
    # convention note; a `return ,$Rows` here would nest one level down.
    return $Rows.ToArray()
}

function Invoke-SalesforceToolingQuery {
    <#
        SOQL against the Tooling API. Invoke-SalesforceQuery (Common.DataMigration.ps1)
        does not pass --use-tooling-api, and FlowDefinition/Flow only exist there.

        CALLER CONTRACT: wrap the call in @().
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Soql,
        [Parameter(Mandatory = $true)][string]$Org,
        [Parameter(Mandatory = $true)][string]$Version
    )

    # NEVER redirect stderr here (no 2>&1). PS 5.1 turns the CLI's
    # "update available" banner into a NativeCommandError that kills the script
    # and blames this line. See CLAUDE.md's PowerShell traps.
    $Raw = & sf data query --target-org $Org --api-version $Version --query $Soql --use-tooling-api --json

    if ($LASTEXITCODE -ne 0) {
        throw "Tooling query failed (exit $LASTEXITCODE): $Soql"
    }

    $Parsed = $Raw | ConvertFrom-Json

    if ($Parsed.status -ne 0) {
        $Message = $Parsed.message
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "Unknown Salesforce CLI error." }
        throw $Message
    }

    if ($null -eq $Parsed.result.records) { return @() }

    # Same silent-truncation guard as Invoke-SalesforceQuery: a partial result
    # is indistinguishable from a small one at the call site, and here it would
    # mean reporting a flow as absent when it merely fell off the page.
    $Returned = @($Parsed.result.records).Count
    $Total = [int]$Parsed.result.totalSize
    if ($Returned -lt $Total) {
        throw "Tooling query returned $Returned of $Total records (truncated). SOQL: $Soql"
    }

    # ASSIGN, THEN RETURN. Piping ConvertFrom-Json output straight out of a
    # function collapses a JSON array into ONE pipeline item in PS 5.1, so the
    # caller's @() measures Count = 1 no matter how many rows came back. This
    # broke the Notes load on 2026-08-13; see Invoke-NotesLoad.ps1.
    $Records = $Parsed.result.records
    return $Records
}

function Set-LdgcrmFlowActiveVersion {
    <#
        Activates one flow by PATCHing FlowDefinition.Metadata.activeVersionNumber
        via the Tooling REST API.

        WHY REST AND NOT `sf data update record`: Metadata is a compound field;
        --values cannot express a nested object.

        WHY `sf api request rest` DESPITE ITS BETA WARNING: it is already the
        transport for the Notes load (Invoke-NotesLoad.ps1), so this adds no new
        dependency. Its warnings share a stream with the response body, hence
        the JSON-line filtering below.

        A SUCCESSFUL PATCH RETURNS 204 NO CONTENT - an empty response is the
        success case here, which is the opposite of every other call in this
        repo. Only a JSON body carrying an errorCode means failure.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DefinitionId,
        [Parameter(Mandatory = $true)][int]$VersionNumber,
        [Parameter(Mandatory = $true)][string]$Org,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$BodyDirectory
    )

    $Body = [PSCustomObject]@{
        Metadata = [PSCustomObject]@{ activeVersionNumber = $VersionNumber }
    } | ConvertTo-Json -Depth 5

    # UTF-8 NO BOM. A BOM in front of the first brace makes the body invalid
    # JSON, the same way it breaks a Bulk API CSV (see Export-DataLoaderCsv).
    $BodyFile = Join-Path $BodyDirectory "activate-$DefinitionId.json"
    [System.IO.File]::WriteAllText($BodyFile, $Body, (New-Object System.Text.UTF8Encoding $false))

    $Path = "/services/data/v$Version/tooling/sobjects/FlowDefinition/$DefinitionId"
    $Output = & sf api request rest $Path --method PATCH --body "@$BodyFile" --target-org $Org

    $Lines = @($Output | ForEach-Object { "$_" })
    $JsonStart = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Trimmed = $Lines[$i].TrimStart()
        if ($Trimmed.StartsWith("[") -or $Trimmed.StartsWith("{")) { $JsonStart = $i; break }
    }

    if ($JsonStart -ge 0) {
        $Payload = ($Lines[$JsonStart..($Lines.Count - 1)] -join "`n")
        $Parsed = $null
        try { $Parsed = $Payload | ConvertFrom-Json } catch { $Parsed = $null }

        foreach ($Item in @($Parsed)) {
            if ($Item -and $Item.errorCode) {
                return "$($Item.errorCode): $($Item.message)"
            }
        }
    }

    if ($LASTEXITCODE -ne 0) {
        return "Salesforce CLI exited $LASTEXITCODE. Raw output: $($Lines -join ' ')"
    }

    return ""   # empty string = success
}

Write-Host "Reading flow state from $OrgAlias..." -ForegroundColor Cyan
$FlowState = @(Get-LdgcrmFlowState -Org $OrgAlias -Version $ApiVersion)
$StateByName = @{}
foreach ($F in $FlowState) { $StateByName[$F.DeveloperName] = $F }
Write-Host "  $($FlowState.Count) LDGCRM/LGDCRM flow definition(s) found."
Write-Host ""

# ---------------------------------------------------------------------------
# Check 1 + 3: expected flows present, active, and not behind their latest
# ---------------------------------------------------------------------------

$Missing   = New-Object System.Collections.Generic.List[object]
$Inactive  = New-Object System.Collections.Generic.List[object]
$Stale     = New-Object System.Collections.Generic.List[object]
$Healthy   = New-Object System.Collections.Generic.List[object]

foreach ($Name in $Script:ExpectedActiveFlows) {
    if (-not $StateByName.ContainsKey($Name)) {
        $Missing.Add([PSCustomObject]@{ DeveloperName = $Name })
        continue
    }

    $F = $StateByName[$Name]

    if (-not $F.IsActive) { $Inactive.Add($F); continue }

    if ($null -ne $F.LatestVersion -and $null -ne $F.ActiveVersion -and $F.LatestVersion -gt $F.ActiveVersion) {
        $Stale.Add($F)
        continue
    }

    $Healthy.Add($F)
}

# ---------------------------------------------------------------------------
# Check 2: Dev-only flows must be absent everywhere else
# ---------------------------------------------------------------------------

$Trespassing = New-Object System.Collections.Generic.List[object]

if ($Environment -ne "Dev") {
    foreach ($Name in $Script:DevOnlyFlows) {
        if ($StateByName.ContainsKey($Name)) { $Trespassing.Add($StateByName[$Name]) }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

Write-Host "------------------------------------------------------------"
Write-Host " FLOW STATE"
Write-Host "------------------------------------------------------------"

foreach ($F in $Healthy) {
    Write-Host ("  [OK]       {0}  (v{1})" -f $F.DeveloperName, $F.ActiveVersion) -ForegroundColor Green
}
foreach ($F in $Stale) {
    Write-Host ("  [STALE]    {0}  (v{1} active, v{2} exists)" -f $F.DeveloperName, $F.ActiveVersion, $F.LatestVersion) -ForegroundColor Yellow
}
foreach ($F in $Inactive) {
    $LatestText = "no versions"
    if ($null -ne $F.LatestVersion) { $LatestText = "latest v$($F.LatestVersion)" }
    Write-Host ("  [INACTIVE] {0}  ({1})" -f $F.DeveloperName, $LatestText) -ForegroundColor Red
}
foreach ($F in $Missing) {
    Write-Host ("  [ABSENT]   {0}" -f $F.DeveloperName) -ForegroundColor Red
}
foreach ($F in $Trespassing) {
    Write-Host ("  [TRESPASS] {0}  must NOT exist in {1}" -f $F.DeveloperName, $Environment) -ForegroundColor Red
}

Write-Host ""

# ---------------------------------------------------------------------------
# Activate
# ---------------------------------------------------------------------------

$Activatable = New-Object System.Collections.Generic.List[object]
foreach ($F in $Inactive) { if ($null -ne $F.LatestVersion) { $Activatable.Add($F) } }
foreach ($F in $Stale)    { $Activatable.Add($F) }

if ($FlowName.Count -gt 0) {
    # An unrecognised -FlowName is a typo, and silently activating nothing while
    # reporting success is exactly the class of failure this script exists to
    # catch. Fail on it instead.
    $Selectable = @($Activatable | ForEach-Object { $_.DeveloperName })
    $Unknown = @($FlowName | Where-Object { $Selectable -notcontains $_ })
    if ($Unknown.Count -gt 0) {
        throw ("-FlowName named flow(s) that do not need activating in this org: " +
               ($Unknown -join ", ") + ". Activatable here: " +
               $(if ($Selectable.Count -gt 0) { $Selectable -join ", " } else { "(none)" }))
    }

    $Filtered = New-Object System.Collections.Generic.List[object]
    foreach ($F in $Activatable) { if ($FlowName -contains $F.DeveloperName) { $Filtered.Add($F) } }
    $Activatable = $Filtered

    Write-Host ("-FlowName limits activation to $($Activatable.Count) of $($Selectable.Count) activatable flow(s).") -ForegroundColor Yellow
    Write-Host ""
}

$ActivationFailures = New-Object System.Collections.Generic.List[object]
$Activated = New-Object System.Collections.Generic.List[object]

if ($ActivateFlows -and $Activatable.Count -gt 0) {
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " ACTIVATION" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "$($Activatable.Count) flow(s) will be activated in $OrgAlias ($Environment):" -ForegroundColor Yellow
    foreach ($F in $Activatable) {
        Write-Host ("  {0} -> v{1}" -f $F.DeveloperName, $F.LatestVersion)
    }
    Write-Host ""
    Write-Host "THIS IS PERMANENT. Unlike the TriggerControls__c bypass, nothing is" -ForegroundColor Yellow
    Write-Host "restored afterwards - a flow switched on for the load must stay on, or" -ForegroundColor Yellow
    Write-Host "the org resumes producing wrong data for every record created in the UI." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "It activates the newest version THIS org holds. Version numbers are a" -ForegroundColor Yellow
    Write-Host "per-org counter and are not comparable between orgs, so this cannot tell" -ForegroundColor Yellow
    Write-Host "you whether that version carries the logic the change set intended - only" -ForegroundColor Yellow
    Write-Host "whoever built the change set can confirm that." -ForegroundColor Yellow
    Write-Host ""

    $Approved = Assert-LdgcrmTypedConfirmation `
        -Token "ACTIVATE" `
        -Action "activate $($Activatable.Count) Flow(s) in $OrgAlias ($Environment)" `
        -Provided $Confirmation

    if ($Approved) {
        $RunDirectory = Get-LogDirectory -Category "data-migration"

        foreach ($F in $Activatable) {
            Write-Host ("  activating {0} -> v{1} ..." -f $F.DeveloperName, $F.LatestVersion) -NoNewline

            # NOT $Error - that is a PowerShell automatic variable holding the
            # session's error history, and assigning to it breaks error
            # reporting for everything downstream in the run.
            $ActivationError = Set-LdgcrmFlowActiveVersion `
                -DefinitionId $F.DefinitionId `
                -VersionNumber ([int]$F.LatestVersion) `
                -Org $OrgAlias `
                -Version $ApiVersion `
                -BodyDirectory $RunDirectory

            if ($ActivationError) {
                Write-Host " FAILED" -ForegroundColor Red
                $ActivationFailures.Add([PSCustomObject]@{ DeveloperName = $F.DeveloperName; Error = $ActivationError })
            }
            else {
                Write-Host " done" -ForegroundColor Green
                $Activated.Add($F)
            }
        }

        # VERIFYING RE-QUERY, same principle as the TriggerControls__c restore in
        # Invoke-SalesforceLoad.ps1: a PATCH that returns 204 is not proof the
        # org agrees. Re-read the state rather than trusting the write.
        Write-Host ""
        Write-Host "Re-reading flow state to verify..." -ForegroundColor Cyan

        $FlowState = @(Get-LdgcrmFlowState -Org $OrgAlias -Version $ApiVersion)
        $StateByName = @{}
        foreach ($F in $FlowState) { $StateByName[$F.DeveloperName] = $F }

        $Inactive = New-Object System.Collections.Generic.List[object]
        $Stale    = New-Object System.Collections.Generic.List[object]
        $Missing  = New-Object System.Collections.Generic.List[object]
        $Healthy  = New-Object System.Collections.Generic.List[object]

        foreach ($Name in $Script:ExpectedActiveFlows) {
            if (-not $StateByName.ContainsKey($Name)) { $Missing.Add([PSCustomObject]@{ DeveloperName = $Name }); continue }
            $F = $StateByName[$Name]
            if (-not $F.IsActive) { $Inactive.Add($F); continue }
            if ($null -ne $F.LatestVersion -and $null -ne $F.ActiveVersion -and $F.LatestVersion -gt $F.ActiveVersion) { $Stale.Add($F); continue }
            $Healthy.Add($F)
        }

        Write-Host ("  verified: {0} active and current, {1} inactive, {2} stale, {3} absent" -f `
            $Healthy.Count, $Inactive.Count, $Stale.Count, $Missing.Count)
    }
    else {
        Write-Host "Activation declined - nothing was changed." -ForegroundColor Yellow
    }

    Write-Host ""
}
elseif ($ActivateFlows) {
    Write-Host "-ActivateFlows was passed, but nothing needs activating." -ForegroundColor Green
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

$Blockers = New-Object System.Collections.Generic.List[string]

foreach ($F in $Missing) {
    $Blockers.Add("ABSENT   $($F.DeveloperName) - not in this org at all. Needs a CHANGE SET.")
}
foreach ($F in $Inactive) {
    if ($null -eq $F.LatestVersion) {
        $Blockers.Add("INACTIVE $($F.DeveloperName) - present but has NO versions. Needs a CHANGE SET.")
    }
    else {
        $Blockers.Add("INACTIVE $($F.DeveloperName) - v$($F.LatestVersion) is in the org but switched off. Re-run with -ActivateFlows.")
    }
}
foreach ($F in $Stale) {
    $Blockers.Add("STALE    $($F.DeveloperName) - v$($F.ActiveVersion) active but v$($F.LatestVersion) exists. Re-run with -ActivateFlows.")
}
foreach ($F in $Trespassing) {
    $Blockers.Add("TRESPASS $($F.DeveloperName) - must not exist in $Environment. Investigate how it got here; do not just deactivate it.")
}
foreach ($F in $ActivationFailures) {
    $Blockers.Add("FAILED   $($F.DeveloperName) - activation rejected: $($F.Error)")
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PRE-FLIGHT RESULT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($Blockers.Count -eq 0) {
    Write-Host "PASS - all $($Script:ExpectedActiveFlows.Count) expected flows are active and current." -ForegroundColor Green
    if ($Activated.Count -gt 0) {
        Write-Host "$($Activated.Count) of them were activated by this run." -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "This proves every expected flow in $OrgAlias is ON and running the newest" -ForegroundColor Yellow
    Write-Host "version this org holds. Whether that version carries the intended logic is a" -ForegroundColor Yellow
    Write-Host "change-set question - version numbers are per-org and prove nothing across orgs." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

Write-Host "FAIL - $($Blockers.Count) issue(s) must be resolved before loading:" -ForegroundColor Red
Write-Host ""
foreach ($B in $Blockers) { Write-Host "  $B" -ForegroundColor Red }
Write-Host ""
Write-Host "A load will still SUCCEED with these outstanding - that is the problem." -ForegroundColor Yellow
Write-Host "Rows load, counts match, and the fields those flows populate stay empty." -ForegroundColor Yellow
Write-Host ""
Write-Host "Anything marked ABSENT or 'NO versions' cannot be fixed from here: the" -ForegroundColor Yellow
Write-Host "pipeline does not deploy metadata. Hand the list to whoever builds the" -ForegroundColor Yellow
Write-Host "change set - see CLAUDE.md, 'Metadata promotion is by CHANGE SET only'." -ForegroundColor Yellow
Write-Host ""

exit 1

}
finally {
    Stop-ScriptLog
}
