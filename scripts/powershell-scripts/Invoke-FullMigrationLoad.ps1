#Requires -Version 5.1

<#
    THE FULL MIGRATION LOAD
    =======================
    Runs every transform and every load, in dependency order, as one operation.

    WHY THIS EXISTS
      The load order is a hard dependency chain - parents before children,
      Opportunity before Application, Impediment before its junction, Notes dead
      last - and until now it lived only in prose (docs/engineering/ARCHITECTURE.md "Load order")
      and a checklist a human walked by hand. That is fine for a developer who
      has read both. It is not fine for the Operations team, who will run this
      against QA, Full and eventually production, and for whom "run these
      eighteen commands in exactly this order" is a defect waiting to happen.

      Getting the order wrong does not fail loudly. It silently WITHHOLDS rows:
      every transform skips records whose parent isn't in the org yet, so a
      mis-ordered run produces a smaller migration and a clean-looking summary.
      That is the failure this script exists to prevent.

    WHAT IT DOES NOT DO
      It does not reset the org. Invoke-SandboxFactoryReset.ps1 is deliberately
      separate: it is destructive, and it is blocked from production entirely,
      whereas this script legitimately targets production. Fusing them would
      mean the production-capable script contained a delete path.

      It does not decide anything. Every transform and loader keeps its own
      preflight, its own review CSVs and its own confirmation; this only
      sequences them.

    HOW A RUN IS APPROVED
      -Confirmation "LOAD" is passed through to every load step, so the whole
      sequence is approved once rather than eighteen times. Against production
      -ProductionConfirmation <alias> is ALSO required, by every step, and is
      deliberately not stored anywhere - see the notes on that parameter.

      -PlanOnly runs every TRANSFORM and no loads. Transforms are read-only, so
      this doubles as the readiness check: it proves each script runs, queries
      the org successfully, and reports exactly how many rows each step would
      load, without writing anything.

    RESUMING
      Steps run as child processes and the sequence stops at the first failure,
      because everything after a failed step would silently withhold rows that
      depend on it. -StartAtStep resumes from a named step once the cause is
      fixed; -OnlySteps runs a subset. Both take the Name column printed in the
      plan.
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    [string]$OrgAlias = "",

    # Approve every load step in the sequence. Same token the individual
    # scripts take: -Confirmation "LOAD".
    [string]$Confirmation = "",

    # Required IN ADDITION to -Confirmation when -Environment Prod. Two separate
    # tokens on purpose: an operator who automated a sandbox run must not be
    # able to retarget it at production by changing -Environment alone.
    #
    # Do not bake this into a saved script or a CI variable. A production
    # migration is a scheduled, supervised event, not a job that can fire on its
    # own.
    [string]$ProductionConfirmation = "",

    # Run every transform, load nothing. Read-only, and the readiness check:
    # proves each script runs and reports what it would load.
    [switch]$PlanOnly,

    # Resume from a named step (see the Name column in the plan).
    [string]$StartAtStep = "",

    # Comma-separated subset of step names to run.
    [string]$OnlySteps = "",

    # Rebuild the Account tree from the production export first. Sandbox only -
    # in production the Accounts already exist and this would be wrong.
    [switch]$BootstrapAccounts,

    # Keep going after a failed step. OFF by default: everything downstream of a
    # failure withholds rows that depend on it, so continuing usually produces a
    # quietly incomplete migration rather than an obvious error.
    [switch]$ContinueOnError,

    <#
        Run Test-LdgcrmReadiness.ps1 before pre-flight and stop on any failure.

        Readiness checks the bundle, the Airtable pull and the org's SHAPE -
        every field a load writes exists and is writable, every Migration table
        was pulled. Pre-flight checks run-time state (Flows, duplicate rules,
        trigger switch) and runs with or without this switch.

        Off by default: costs one describe per object, roughly 30s. Read-only.
    #>
    [switch]$Readiness
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")
. (Join-Path $PSScriptRoot "Common.LoadReport.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Invoke-FullMigrationLoad"

# When this run began. Used to tell a CSV this run produced from one left over
# by an earlier run - see the staleness check in the step loop.
$RunStart = Get-Date

# =============================================================================
# THE SEQUENCE
# =============================================================================
# Order is the dependency chain from docs/engineering/ARCHITECTURE.md. Each entry is data, not
# code, so adding an object is a table edit.
#
#   Name        short handle for -StartAtStep / -OnlySteps
#   Build       transform script (read-only; writes a CSV)
#   Object      Salesforce object for the load step
#   Csv         file in data/salesforce-loads/ the transform produces
#   Operation   Upsert (default) | Update | Insert
#   Loader      Standard (Invoke-SalesforceLoad.ps1) | Notes (Invoke-NotesLoad.ps1)
#   TriggerOff  TriggerControls__c record to disable for the load
#   Why         one line explaining the position, printed in the plan
#   ExpectedFailures
#               error substrings that mark a row failure as a KNOWN, ACCEPTED
#               outcome for this object. Anything else is a real failure and
#               still halts. Kept here, next to the object, rather than inside
#               the loader - the policy is per-object and reviewable in one
#               place. See the classification block in Invoke-SalesforceLoad.ps1.
$Steps = @(
    [ordered]@{
        # FIRST, and it must stay first. Three before-save Flows derive Market
        # Segment from the parent chain, and Build-AccountReconciliation.ps1
        # resolves a segment through LDGCRM_Market_Segment__r.LDGCRM_External_ID__c
        # - so segments that do not exist, or exist untagged, silently produce a
        # blank Market Segment on every downstream record with no error anywhere.
        # Added 2026-08-14 after QA was found holding all five segments with NO
        # external IDs; pre-flight passed on a count and the data would have been
        # empty org-wide.
        Name = "MarketSegment"; Build = "Build-MarketSegmentLoad.ps1"
        Object = "LDGCRM_Market_Segment__c"; Csv = "LDGCRM_Market_Segment__c-upsert.csv"
        Why = "FIRST - everything downstream derives its Market Segment from these, via Flows and the Account reconciliation."
    }
    [ordered]@{
        Name = "Impediment"; Build = "Build-ImpedimentLoad.ps1"
        Object = "LDGCRM_Impediment__c"; Csv = "LDGCRM_Impediment__c-upsert.csv"
        Why = "Independent parent - no lookups, so it can go first."
    }
    [ordered]@{
        # BEFORE the reconciliation, and that order is load-bearing. These
        # Accounts do not exist yet, so the reconciliation cannot match them;
        # creating them first means the very next step tags them with their
        # external ID and sets Market Segment and Type in the same run. Run the
        # other way round and every created Account stays untagged until
        # somebody runs the pipeline a second time.
        #
        # INSERT, not upsert: LDGCRM_External_ID__c is externalId=true but
        # unique=false on Account, so an upsert cannot key on it reliably, and
        # these records are by definition absent.
        #
        # The transform only proposes an Account after sweeping the whole org -
        # see Build-AccountCreationLoad.ps1. Run it with -PlanOnly to see what
        # would be created without creating anything.
        Name = "AccountCreate"; Build = "Build-AccountCreationLoad.ps1"
        Object = "Account"; Csv = "Account-insert.csv"; Operation = "Insert"
        Why = "Creates the Accounts Airtable needs that the org does not have. Must precede the reconciliation, which tags them."
    }
    [ordered]@{
        Name = "Account"; Build = "Build-AccountReconciliation.ps1"
        Object = "Account"; Csv = "Account-update.csv"; Operation = "Update"
        Why = "UPDATE, not upsert - matches Airtable rows onto Accounts that already exist, including any just created."
    }
    [ordered]@{
        Name = "PartnerAccount"; Build = "Build-PartnerAccountLoad.ps1"
        Object = "LDGCRM_Partner_Account__c"; Csv = "LDGCRM_Partner_Account__c-upsert.csv"
        Why = "Master-Detail child of Account - needs Account reconciled first."
        # Parent Account is one of the unmatched Airtable rows. Documented in
        # AIRTABLE-DATA-QUALITY-REQUESTS.md; 2 of 94 on the 2026-08-13 reload,
        # ~20 of 94 before the Account work.
        ExpectedFailures = @("Foreign key external ID")
    }
    [ordered]@{
        Name = "Contact"; Build = "Build-ContactLoad.ps1"
        Object = "Contact"; Csv = "Contact-upsert.csv"; TriggerOff = "Contact"
        Why = "Disables FCIC's Contact trigger, which creates a junk Account per blank AccountId."
        # The org's first+last-name duplicate rule. Not in this repo's metadata
        # (the manifest is app-scoped), so it is invisible to any amount of
        # reading force-app. Catches the same person under two email addresses -
        # 12 of 1,882 on the 2026-08-13 reload.
        ExpectedFailures = @("DUPLICATES_DETECTED")
    }
    [ordered]@{
        Name = "Opportunity"; Build = "Build-OpportunityLoad.ps1"
        Object = "Opportunity"; Csv = "Opportunity-upsert.csv"
        Why = "Must precede Application - an unresolvable Opportunity lookup fails the whole row."
    }
    [ordered]@{
        Name = "Application"; Build = "Build-ApplicationLoad.ps1"
        Object = "LDGCRM_application__c"; Csv = "LDGCRM_application__c-upsert.csv"
        Why = "Needs Partner Account (required) and Opportunity (optional but fatal if dangling)."
    }
    [ordered]@{
        # NAMED FOR THE FIELD IT FILLS, NOT FOR RECORDS IT CREATES - it creates
        # none. The previous name, "BrokerParent", read as "load the broker
        # parents", which invites the reasonable objection that parents should
        # surely be loaded BEFORE their children. They are: a broker parent IS
        # an ordinary Application, created by the Application step above along
        # with everything else. This step only sets a pointer on the child.
        Name = "PopulateBrokerParent"; Build = ""
        Object = "LDGCRM_application__c"; Csv = "LDGCRM_application__c-broker-parent-upsert.csv"
        Why = "SECOND PASS - sets LDGCRM_Broker_App_Parent__c on Applications the step above already created. Creates nothing; Bulk can't resolve a self-lookup inside its own batch."
    }
    [ordered]@{
        Name = "OpportunityImpediment"; Build = "Build-OpportunityImpedimentLoad.ps1"
        Object = "LDGCRM_Opportunity_Impediment__c"; Csv = "LDGCRM_Opportunity_Impediment__c-upsert.csv"
        Why = "Two Master-Details - both Impediment and Opportunity must already exist."
    }
    [ordered]@{
        Name = "ApplicationContact"; Build = "Build-ApplicationContactLoad.ps1"
        Object = "LDGCRM_Application_Contact__c"; Csv = "LDGCRM_Application_Contact__c-upsert.csv"
        Why = "Junction - needs Application and Contact."
    }
    [ordered]@{
        Name = "OpportunityContactRole"; Build = "Build-OpportunityContactRoleLoad.ps1"
        Object = "OpportunityContactRole"; Csv = "OpportunityContactRole-insert.csv"; Operation = "Insert"
        Why = "INSERT + read-then-diff - Salesforce forbids External IDs on this object."
    }
    [ordered]@{
        Name = "Notes"; Build = "Build-NotesLoad.ps1"
        Object = "ContentNote"; Csv = "ContentNote-staging.csv"; Loader = "Notes"
        Why = "LAST - a note attaches to a record that must already exist. Loads over REST, not Bulk."
    }
)

# Defined in Common.DataMigration.ps1, shared with Test-LdgcrmReadiness.ps1.
$ExpectedActiveFlows = @(Get-LdgcrmExpectedActiveFlows)
$DevOnlyFlows = @(Get-LdgcrmDevOnlyFlows)

function Get-StepProperty {
    param($Step, [string]$Key, $Default = "")
    if ($Step.Contains($Key) -and $Step[$Key]) { return $Step[$Key] }
    return $Default
}

# Invoke-LdgcrmToolingQuery and Get-LdgcrmFlowState live in
# Common.DataMigration.ps1 (read-only, shared with the readiness check).
# Set-LdgcrmFlowActiveVersion stays here because it writes.

function Set-LdgcrmFlowActiveVersion {
    <#
        Activates one flow by PATCHing FlowDefinition.Metadata.activeVersionNumber
        over the Tooling REST API. Returns "" on success, an error string on
        failure.

        THIS IS A SETTING, NOT A METADATA DEPLOY. It points an org at a flow
        version ALREADY IN that org. It moves no XML between orgs and creates no
        component, which is what keeps it on the right side of CLAUDE.md's
        "METADATA IS NOT THE OPERATIONS TEAM'S JOB" rule (project owner,
        2026-08-14: "There is a difference between changing settings in the org
        via CLI and adding/updating core object definitions").

        WHY REST AND NOT `sf data update record`: Metadata is a compound field
        and --values cannot express a nested object.

        WHY `sf api request rest` DESPITE ITS BETA WARNING: it is already the
        transport for the Notes load (Invoke-NotesLoad.ps1), so this adds no new
        dependency. Its warnings share a stream with the response body, hence
        the JSON-line scan below.

        A SUCCESSFUL PATCH RETURNS 204 NO CONTENT - an empty response is the
        success case, the opposite of every other call in this repo. Only a JSON
        body carrying an errorCode means failure.
    #>
    param([string]$DefinitionId, [int]$VersionNumber, [string]$Org, [string]$Version, [string]$BodyDirectory)

    $Body = [PSCustomObject]@{ Metadata = [PSCustomObject]@{ activeVersionNumber = $VersionNumber } } | ConvertTo-Json -Depth 5

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
            if ($Item -and $Item.errorCode) { return "$($Item.errorCode): $($Item.message)" }
        }
    }

    if ($LASTEXITCODE -ne 0) { return "Salesforce CLI exited $LASTEXITCODE. Raw output: $($Lines -join ' ')" }
    return ""
}

function Invoke-LdgcrmRuleDeploy {
    <#
        Deploys one prepared metadata directory and returns "" on success or an
        error string. Split out because the duplicate-rule and matching-rule
        passes deploy separately and in order.

        CHECK numberComponentErrors, NOT just success. CLAUDE.md records a
        deploy that reported "Succeeded" having deployed 0 components; the
        component counters are the truthful answer.
    #>
    param([string]$Directory, [string]$Org, [string]$Version)

    # NEVER redirect stderr (no 2>&1) - PS 5.1 turns the CLI's update banner
    # into a NativeCommandError that kills the script.
    $Raw = & sf project deploy start --metadata-dir $Directory --target-org $Org --api-version $Version --wait 10 --json
    $Parsed = $null
    try { $Parsed = ($Raw | Out-String) | ConvertFrom-Json } catch { $Parsed = $null }

    if ($null -eq $Parsed) { return "Could not parse the deploy response. Raw: $($Raw -join ' ')" }

    $Result = $Parsed.result
    if ($null -eq $Result) { return "Deploy returned no result object. Message: $($Parsed.message)" }

    $ErrorCount = 0
    if ($null -ne $Result.numberComponentErrors) { $ErrorCount = [int]$Result.numberComponentErrors }

    if ("$($Result.success)" -ne "true" -or $ErrorCount -gt 0) {
        $Detail = ""
        foreach ($F in @($Result.details.componentFailures)) {
            if ($F.problem) { $Detail += " [$($F.fullName): $($F.problem)]" }
        }
        if (-not $Detail) { $Detail = " status=$($Result.status)" }
        return "Deploy failed ($ErrorCount component error(s)).$Detail"
    }

    if ([int]$Result.numberComponentsDeployed -lt 1) {
        return "Deploy reported success but deployed 0 components - nothing changed."
    }

    return ""
}

function Disable-LdgcrmContactDuplicateRules {
    <#
        Switches OFF every ACTIVE Contact duplicate rule in the target org, then
        the matching rules behind them, as part of the load. Returns a result
        object carrying Blocking/Warning message lists.

        WHY THIS IS A METADATA DEPLOY AND NOT A SETTING PATCH. Flow activation
        gets to be a one-field PATCH because FlowDefinition exposes a Metadata
        compound field. Neither object here does: DuplicateRule is not a Tooling
        API object at all (INVALID_TYPE) and its IsActive is updateable=false on
        the standard API, while MatchingRule has no Metadata field. The Metadata
        API is the ONLY route, so this retrieves the component from the target
        org, flips one line, and deploys it straight back.

        THAT IS STILL A SETTING FLIP, NOT A PROMOTION. It moves no XML between
        orgs, creates no component, and changes no definition - the rule's own
        retrieved body is what gets redeployed, with a single status element
        altered. It is the same category as -ActivateFlows and falls under the
        project owner's rule (2026-08-14): "There is a difference between
        changing settings in the org via CLI and adding/updating core object
        definitions... allow for our pre-flight script to prep and validate the
        environment for a successful load."

        RUNS IN EVERY ENVIRONMENT, PRODUCTION INCLUDED (project owner,
        2026-08-15). The rules block the Contact load identically everywhere
        and the decision is that they stay off everywhere, so making Prod the
        one org where an operator must remember a manual step is how a
        production load acquires a silent 167-record hole. Flow activation was
        brought under the same rule on 2026-08-18.

        NOTHING IS RESTORED. Deliberate, same as flow activation: the rules stay
        off permanently. Do not add a finally block that puts them back.

        FOUR MECHANICS THAT ARE NOT OBVIOUS:
          1. The retrieve needs NO sfdx project. `--target-metadata-dir` works
             from any directory, which is what lets this live in the bundle at
             all - scripts/ has no sfdx-project.json and must never reach up to
             the repo's sfdx/ folder.
          2. DuplicateRule members MUST be object-qualified ("Contact.X"). An
             unqualified name fails with "Need to specify full name, Required
             Delimiter: ." while the retrieve still reports Succeeded.
          3. --unzip nests the payload (unpackaged/unpackaged/...), so the
             package.xml is located by search rather than by assumed path.
          4. MatchingRules is a PER-OBJECT container file - one Contact
             .matchingRule holds every Contact matching rule. A targeted
             retrieve returns only the requested rules, and the same file is
             deployed back, so this is a round-trip of the org's own content.

        ORDER MATTERS AND IS NOT NEGOTIABLE: a matching rule cannot be
        deactivated while an active duplicate rule consumes it. Duplicate rules
        first, always.

        THE MATCHING-RULE PASS IS NON-FATAL BY DESIGN. Once no active duplicate
        rule consumes it, a matching rule enforces nothing, so the load is
        already safe after the first pass. Its deploy is also the riskier of the
        two - a container file, and Salesforce is fussy about status-only
        changes on matching rules - and failing a production load over a
        cosmetic tidy-up would be the wrong trade.
    #>
    param([string]$Org, [string]$Version, [string]$WorkDirectory)

    $Outcome = [ordered]@{ Blocking = @(); Warning = @(); Deactivated = @() }

    $ActiveDuplicates = @(Invoke-SalesforceQuery `
        -Soql "SELECT DeveloperName, IsActive FROM DuplicateRule WHERE SobjectType = 'Contact'" `
        -OrgAlias $Org -ApiVersion $Version |
        Where-Object { "$($_.IsActive)" -eq "true" })

    if ($ActiveDuplicates.Count -eq 0) {
        Write-Host "  Contact dup rules      none active"
        return $Outcome
    }

    Write-Host ""
    Write-Host ("  Switching off $($ActiveDuplicates.Count) active Contact duplicate rule(s) in $Org.") -ForegroundColor Yellow
    Write-Host "  Permanent: these are not restored after the load." -ForegroundColor Yellow

    $RuleRoot = Join-Path $WorkDirectory "contact-duplicate-rules"
    New-Item -ItemType Directory -Path $RuleRoot -Force | Out-Null
    $RetrieveDir = Join-Path $RuleRoot "retrieved"

    $ActiveMatching = @(Invoke-LdgcrmToolingQuery `
        -Soql "SELECT DeveloperName, RuleStatus FROM MatchingRule WHERE SobjectType = 'Contact'" `
        -Org $Org -Version $Version |
        Where-Object { $_.RuleStatus -eq "Active" })

    $RetrieveArgs = @()
    foreach ($R in $ActiveDuplicates) { $RetrieveArgs += @("--metadata", "DuplicateRule:Contact.$($R.DeveloperName)") }
    foreach ($R in $ActiveMatching)   { $RetrieveArgs += @("--metadata", "MatchingRule:Contact.$($R.DeveloperName)") }

    $RetrieveRaw = & sf project retrieve start @RetrieveArgs --target-metadata-dir $RetrieveDir --unzip --target-org $Org --api-version $Version --json
    $RetrieveParsed = $null
    try { $RetrieveParsed = ($RetrieveRaw | Out-String) | ConvertFrom-Json } catch { $RetrieveParsed = $null }

    if ($null -eq $RetrieveParsed -or "$($RetrieveParsed.result.success)" -ne "true") {
        $Outcome.Blocking += ("Could not retrieve the Contact duplicate rule definitions from $Org, so they cannot be " +
                              "switched off automatically. Deactivate them in Setup > Duplicate Rules (then Matching " +
                              "Rules) and re-run. Detail: $($RetrieveParsed.result.status) $($RetrieveParsed.message)")
        return $Outcome
    }

    $PackageFile = @(Get-ChildItem -Path $RetrieveDir -Filter "package.xml" -Recurse -File | Select-Object -First 1)
    if ($PackageFile.Count -eq 0) {
        $Outcome.Blocking += "Retrieve succeeded but no package.xml was found under $RetrieveDir - cannot locate the retrieved rules."
        return $Outcome
    }
    $Unpackaged = $PackageFile[0].Directory.FullName

    # --- pass 1: duplicate rules (REQUIRED) ---------------------------------
    $DupSource = Join-Path $Unpackaged "duplicateRules"
    $DupFiles  = @(Get-ChildItem -Path $DupSource -File -ErrorAction SilentlyContinue)

    if ($DupFiles.Count -eq 0) {
        $Outcome.Blocking += "No duplicateRules were retrieved from $Org despite $($ActiveDuplicates.Count) being active."
        return $Outcome
    }

    $DupDeploy = Join-Path $RuleRoot "deploy-duplicate"
    New-Item -ItemType Directory -Path (Join-Path $DupDeploy "duplicateRules") -Force | Out-Null
    $Members = New-Object System.Collections.Generic.List[string]

    foreach ($File in $DupFiles) {
        # -Encoding UTF8 is mandatory: PS 5.1 decodes a BOM-less UTF-8 file as
        # ANSI, which corrupts any non-ASCII in a rule's alertText.
        $Xml = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
        $Xml = $Xml -replace "<isActive>true</isActive>", "<isActive>false</isActive>"
        [System.IO.File]::WriteAllText(
            (Join-Path (Join-Path $DupDeploy "duplicateRules") $File.Name),
            $Xml, (New-Object System.Text.UTF8Encoding $false))
        $Members.Add([System.IO.Path]::GetFileNameWithoutExtension($File.Name))
    }

    Write-LdgcrmRulePackage -Path (Join-Path $DupDeploy "package.xml") -TypeName "DuplicateRule" -Members $Members -Version $Version

    Write-Host "    duplicate rules ..." -NoNewline
    $DeployError = Invoke-LdgcrmRuleDeploy -Directory $DupDeploy -Org $Org -Version $Version

    if ($DeployError) {
        Write-Host " FAILED" -ForegroundColor Red
        $Outcome.Blocking += ("Could not switch off the Contact duplicate rule(s) in $Org. $DeployError " +
                              "Deactivate them in Setup > Duplicate Rules and re-run.")
        return $Outcome
    }
    Write-Host " done" -ForegroundColor Green

    # --- pass 2: matching rules (NON-FATAL) ---------------------------------
    $MatchSource = Join-Path $Unpackaged "matchingRules"
    $MatchFiles  = @(Get-ChildItem -Path $MatchSource -File -ErrorAction SilentlyContinue)

    if ($MatchFiles.Count -gt 0) {
        $MatchDeploy = Join-Path $RuleRoot "deploy-matching"
        New-Item -ItemType Directory -Path (Join-Path $MatchDeploy "matchingRules") -Force | Out-Null
        $MatchMembers = New-Object System.Collections.Generic.List[string]

        foreach ($File in $MatchFiles) {
            $Xml = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
            $Xml = $Xml -replace "<ruleStatus>Active</ruleStatus>", "<ruleStatus>Inactive</ruleStatus>"
            [System.IO.File]::WriteAllText(
                (Join-Path (Join-Path $MatchDeploy "matchingRules") $File.Name),
                $Xml, (New-Object System.Text.UTF8Encoding $false))
            foreach ($R in $ActiveMatching) { $MatchMembers.Add("Contact.$($R.DeveloperName)") }
        }

        Write-LdgcrmRulePackage -Path (Join-Path $MatchDeploy "package.xml") -TypeName "MatchingRule" -Members $MatchMembers -Version $Version

        Write-Host "    matching rules  ..." -NoNewline
        $MatchError = Invoke-LdgcrmRuleDeploy -Directory $MatchDeploy -Org $Org -Version $Version

        if ($MatchError) {
            Write-Host " not switched off" -ForegroundColor DarkGray
            $Outcome.Warning += ("The Contact matching rule(s) in $Org could not be switched off automatically, which " +
                                 "does NOT affect this load - a matching rule enforces nothing once no active " +
                                 "duplicate rule consumes it, and the duplicate rules are now off. Tidy them up in " +
                                 "Setup > Matching Rules when convenient. Detail: $MatchError")
        }
        else { Write-Host " done" -ForegroundColor Green }
    }

    foreach ($R in $ActiveDuplicates) { $Outcome.Deactivated += $R.DeveloperName }
    return $Outcome
}

function Write-LdgcrmRulePackage {
    <# Writes a one-type package.xml. UTF-8 NO BOM - a BOM ahead of the XML
       declaration makes the manifest unparseable. #>
    param([string]$Path, [string]$TypeName, $Members, [string]$Version)

    $Lines = New-Object System.Collections.Generic.List[string]
    $Lines.Add('<?xml version="1.0" encoding="UTF-8"?>')
    $Lines.Add('<Package xmlns="http://soap.sforce.com/2006/04/metadata">')
    $Lines.Add('    <types>')
    foreach ($M in @($Members | Sort-Object -Unique)) { $Lines.Add("        <members>$M</members>") }
    $Lines.Add("        <name>$TypeName</name>")
    $Lines.Add('    </types>')
    $Lines.Add("    <version>$Version</version>")
    $Lines.Add('</Package>')

    [System.IO.File]::WriteAllText($Path, ($Lines -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
}

function Invoke-PreflightChecks {
    <#
        Everything that should stop a run BEFORE the first row is written.

        Each check exists because it has actually gone wrong at least once in
        this migration, and every one of them fails SILENTLY at load time rather
        than loudly: a stale Airtable export migrates yesterday's data, a missing
        Market Segment leaves the before-save Flows with nothing to assign,
        deactivated Flows leave every derived field empty on a load that reports
        complete success, an unresolvable fallback owner aborts halfway through
        the sequence rather than at the start.

        All checks are read-only EXCEPT flow activation, which runs unasked in
        every environment on a real load, and is skipped entirely on -PlanOnly.
        That is the one thing pre-flight is allowed to fix rather than just
        report - it is an org setting, not metadata. Everything else it can only
        diagnose; a missing flow or field needs a change set and someone else's
        hands.

        Returns a hashtable of findings; the caller decides whether to stop.
    #>
    param(
        [string]$Org,
        [string]$Version,
        [string]$Env,
        # Names of the steps this run will actually execute. Lets a check warn
        # only when the step that would fix the condition is being skipped.
        [string[]]$SelectedSteps = @()
    )

    $Findings = [ordered]@{ Blocking = @(); Warning = @() }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " PRE-FLIGHT" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # 1. Airtable export present, and how stale. The whole migration reads these
    #    files; loading from a week-old pull is the quietest possible mistake.
    $ExportDir = Join-Path (Get-LdgcrmRoot) "data\airtable-exports"
    $Exports = @(Get-ChildItem -Path $ExportDir -Filter *.json -ErrorAction SilentlyContinue)

    if ($Exports.Count -eq 0) {
        $Findings.Blocking += "No Airtable export found in $ExportDir. Run Get-AirtableExport.ps1 first."
        Write-Host "  Airtable export        MISSING" -ForegroundColor Red
    }
    else {
        $Newest = ($Exports | Sort-Object LastWriteTime | Select-Object -Last 1)
        $AgeDays = [math]::Round(((Get-Date) - $Newest.LastWriteTime).TotalDays, 1)
        Write-Host ("  Airtable export        {0} file(s), newest {1} day(s) old" -f $Exports.Count, $AgeDays)
        if ($AgeDays -gt 7) {
            $Findings.Warning += "Airtable export is $AgeDays days old. Re-run Get-AirtableExport.ps1 unless you deliberately want this snapshot."
        }
    }

    # 2. Market Segment - REPORTED, NOT BLOCKING (changed 2026-08-14).
    #
    #    It used to hard-fail on a count of zero, which was wrong twice over: the
    #    pipeline demanded a precondition it refused to satisfy, and a COUNT does
    #    not answer the question that matters. QA held all five segments with the
    #    right names and NO external IDs; the count check passed and the data
    #    would have been silently empty, because Build-AccountReconciliation.ps1
    #    resolves a segment through LDGCRM_Market_Segment__r.LDGCRM_External_ID__c,
    #    not through Name.
    #
    #    Market Segment is now step 1 of the load, so blocking here would refuse
    #    to run the very step that fixes it. What this reports instead is whether
    #    segments are RESOLVABLE - tagged with an external ID - which is the
    #    property everything downstream actually depends on.
    $Segments = @(Invoke-SalesforceQuery `
        -Soql "SELECT Id, LDGCRM_External_ID__c FROM LDGCRM_Market_Segment__c" `
        -OrgAlias $Org -ApiVersion $Version)
    $Resolvable = @($Segments | Where-Object { $_.LDGCRM_External_ID__c }).Count

    # 0 resolvable is the normal state after a factory reset, which deletes the
    # tagged segments. It only matters when the step that reloads them is not
    # going to run, so the warning is conditional on that.
    $LoadsMarketSegment = ($SelectedSteps -contains "MarketSegment")

    Write-Host ("  Market Segments        {0} present, {1} resolvable (external ID set)" -f $Segments.Count, $Resolvable)

    if ($Resolvable -eq 0 -and -not $LoadsMarketSegment) {
        $Findings.Warning += ("No LDGCRM_Market_Segment__c record carries an external ID and the MarketSegment " +
                              "step is not in this run. Every downstream record will load with a blank Market " +
                              "Segment, and nothing will error.")
    }
    elseif ($Resolvable -eq 0) {
        Write-Host "                         loaded by step 1" -ForegroundColor DarkGray
    }

    # 3. Fallback owner. Every transform resolves it and throws if it can't -
    #    better to find that here than eight steps in.
    try {
        $OwnerId = Resolve-FallbackOwnerId -Email "peter.marks@gsa.gov" -OrgAlias $Org -ApiVersion $Version
        Write-Host ("  Fallback owner         resolved ({0})" -f $OwnerId)
    }
    catch {
        $Findings.Blocking += "Fallback owner did not resolve: $($_.Exception.Message)"
        Write-Host "  Fallback owner         UNRESOLVED" -ForegroundColor Red
    }

    # 4. The FCIC trigger kill switch the Contact step depends on. If the record
    #    is missing, that step fails at the point it tries to flip it - after
    #    several other objects have already loaded.
    $Controls = @(Invoke-SalesforceQuery -Soql "SELECT Id, On__c FROM TriggerControls__c WHERE Name = 'Contact'" -OrgAlias $Org -ApiVersion $Version)
    if ($Controls.Count -eq 1) {
        Write-Host ("  Contact trigger switch present (currently On__c={0})" -f $Controls[0].On__c)
    }
    else {
        $Findings.Blocking += "Expected exactly one TriggerControls__c record named 'Contact', found $($Controls.Count). The Contact step cannot bypass the FCIC trigger without it, and loading Contact with that trigger active creates a junk Account per blank AccountId."
        Write-Host "  Contact trigger switch NOT USABLE" -ForegroundColor Red
    }

    # 5. Notes need the related list on the parent layouts or they load
    #    successfully and are invisible. Layout metadata isn't queryable here, so
    #    this is a reminder rather than a check - stated because it has already
    #    been missed once.
    Write-Host "  Note related lists     not checkable via API - confirm RelatedContentNoteList" -ForegroundColor DarkGray
    Write-Host "                         is on the Partner Account and Application layouts" -ForegroundColor DarkGray

    <#
        6. THE NINE FLOWS ARE ACTIVE. The most consequential check here, and the
        last one added (2026-08-14).

        QA was loaded with 8,740 records and "0 unexpected failures" while every
        LDGCRM Flow in the org was switched off. Nothing failed. Nothing was
        withheld. Object counts matched Dev exactly, so even the Dev-vs-QA
        comparison passed - flow activation changes field CONTENTS, not row
        counts. The visible damage was Market Segment blank on all 92 Partner
        Accounts, all 842 Opportunities and all 1,026 Applications, because the
        three before-save Flows that derive it never ran.

        That is the failure this guards: not a load that breaks, but a load that
        SUCCEEDS against an org whose automation is off.

        Blocking, not a warning. A warning here is indistinguishable from the
        run that caused this check to exist.
    #>
    $FlowState = @(Get-LdgcrmFlowState -Org $Org -Version $Version)
    $StateByName = @{}
    foreach ($F in $FlowState) { $StateByName[$F.DeveloperName] = $F }

    $FlowsMissing  = New-Object System.Collections.Generic.List[object]
    $FlowsInactive = New-Object System.Collections.Generic.List[object]
    $FlowsStale    = New-Object System.Collections.Generic.List[object]
    $FlowsOk       = New-Object System.Collections.Generic.List[object]

    foreach ($Name in $ExpectedActiveFlows) {
        if (-not $StateByName.ContainsKey($Name)) { $FlowsMissing.Add([PSCustomObject]@{ DeveloperName = $Name }); continue }
        $F = $StateByName[$Name]
        if (-not $F.IsActive) { $FlowsInactive.Add($F); continue }

        # STALE = a newer version sits in THIS org, deployed but never switched
        # on. Comparing one org's active against its own latest is the only
        # version comparison that means anything (see Get-LdgcrmFlowState).
        if ($null -ne $F.LatestVersion -and $null -ne $F.ActiveVersion -and $F.LatestVersion -gt $F.ActiveVersion) {
            $FlowsStale.Add($F); continue
        }
        $FlowsOk.Add($F)
    }

    $FlowsTrespassing = New-Object System.Collections.Generic.List[object]
    if ($Env -ne "Dev") {
        foreach ($Name in $DevOnlyFlows) {
            if ($StateByName.ContainsKey($Name)) { $FlowsTrespassing.Add($StateByName[$Name]) }
        }
    }

    Write-Host ("  LDGCRM Flows           {0} of {1} active and current" -f $FlowsOk.Count, $ExpectedActiveFlows.Count)

    <#
        --- prep: switching the flows on --------------------------------------

        THERE IS NO -ActivateFlows SWITCH. There was until 2026-08-18, and it
        was sandbox-only. Both went, at the project owner's direction.

        Activation now happens in EVERY environment, production included, and
        without being asked - the same treatment the Contact duplicate and
        matching rules already get in the Contact step, for the same reason.
        The flows have to be on for the load to be correct everywhere, so
        making production the one org where that depends on somebody
        remembering a manual step is how a production migration acquires a
        defect nobody sees until afterwards.

        It is also the LIGHTER of the two actions this script takes against
        production configuration: a one-field setting PATCH pointing an org at
        a flow version already in it, against the full metadata retrieve-and-
        redeploy the duplicate rules need. It deploys nothing, creates nothing,
        and moves nothing between orgs - see Set-LdgcrmFlowActiveVersion.

        NOT RESTORED AFTERWARDS, unlike the TriggerControls__c bypass. A flow
        that had to be on for the load to be correct must stay on.

        A flow that is ABSENT, or present with no versions, still needs a
        CHANGE SET and still blocks. -PlanOnly activates nothing.
    #>
    $Activatable = New-Object System.Collections.Generic.List[object]
    foreach ($F in $FlowsInactive) { if ($null -ne $F.LatestVersion) { $Activatable.Add($F) } }
    foreach ($F in $FlowsStale)    { $Activatable.Add($F) }

    # A dry run must not write. Report what a real run would switch on, and let
    # the findings below stay non-blocking for anything a real run would fix.
    if ($PlanOnly -and $Activatable.Count -gt 0) {
        Write-Host ""
        Write-Host "  -PlanOnly: NOT activating. A real run would switch on $($Activatable.Count) flow(s):" -ForegroundColor Yellow
        foreach ($F in $Activatable) {
            Write-Host ("    {0} -> v{1}" -f $F.DeveloperName, $F.LatestVersion) -ForegroundColor Yellow
        }
        Write-Host ""
    }

    if (-not $PlanOnly -and $Activatable.Count -gt 0) {
        Write-Host ""
        Write-Host "  Switching on $($Activatable.Count) inactive flow(s) in $Org." -ForegroundColor Yellow
        Write-Host "  Permanent: these are not switched back off after the load." -ForegroundColor Yellow
        Write-Host ""

        foreach ($F in $Activatable) {
            Write-Host ("    {0} -> v{1} ..." -f $F.DeveloperName, $F.LatestVersion) -NoNewline

            # NOT $Error - that is a PowerShell automatic variable holding the
            # session's error history; assigning to it breaks error reporting
            # for the rest of the run.
            $ActivationError = Set-LdgcrmFlowActiveVersion `
                -DefinitionId $F.DefinitionId -VersionNumber ([int]$F.LatestVersion) `
                -Org $Org -Version $Version -BodyDirectory (Get-LogDirectory -Category "data-migration")

            if ($ActivationError) {
                Write-Host " FAILED" -ForegroundColor Red
                $Findings.Blocking += "Could not activate $($F.DeveloperName): $ActivationError"
            }
            else { Write-Host " done" -ForegroundColor Green }
        }

        # VERIFYING RE-QUERY, the same principle as the TriggerControls__c
        # restore in Invoke-SalesforceLoad.ps1: a PATCH returning 204 is not
        # proof the org agrees. Re-read rather than trust the write.
        Write-Host ""
        Write-Host "  re-reading flow state to verify..." -ForegroundColor DarkGray

        $FlowState = @(Get-LdgcrmFlowState -Org $Org -Version $Version)
        $StateByName = @{}
        foreach ($F in $FlowState) { $StateByName[$F.DeveloperName] = $F }

        $FlowsMissing  = New-Object System.Collections.Generic.List[object]
        $FlowsInactive = New-Object System.Collections.Generic.List[object]
        $FlowsStale    = New-Object System.Collections.Generic.List[object]
        $FlowsOk       = New-Object System.Collections.Generic.List[object]

        foreach ($Name in $ExpectedActiveFlows) {
            if (-not $StateByName.ContainsKey($Name)) { $FlowsMissing.Add([PSCustomObject]@{ DeveloperName = $Name }); continue }
            $F = $StateByName[$Name]
            if (-not $F.IsActive) { $FlowsInactive.Add($F); continue }
            if ($null -ne $F.LatestVersion -and $null -ne $F.ActiveVersion -and $F.LatestVersion -gt $F.ActiveVersion) { $FlowsStale.Add($F); continue }
            $FlowsOk.Add($F)
        }

        Write-Host ("  LDGCRM Flows           {0} of {1} active and current after activation" -f $FlowsOk.Count, $ExpectedActiveFlows.Count)
    }

    # --- findings -----------------------------------------------------------
    foreach ($F in $FlowsMissing) {
        $Findings.Blocking += ("Flow $($F.DeveloperName) does not exist in this org. The pipeline cannot deploy " +
                               "metadata - this needs a CHANGE SET. See CLAUDE.md, 'Metadata promotion is by CHANGE SET only'.")
    }
    foreach ($F in $FlowsInactive) {
        if ($null -eq $F.LatestVersion) {
            $Findings.Blocking += "Flow $($F.DeveloperName) is present but has no versions. Needs a CHANGE SET."
        }
        elseif ($PlanOnly) {
            # A real run activates this. Reporting it is right; stopping a dry
            # run over something the load itself fixes is not.
            $Findings.Warning += ("Flow $($F.DeveloperName) is switched off (v$($F.LatestVersion) is in the org). " +
                                  "A real run switches it on; -PlanOnly does not write.")
        }
        else {
            # Reached only after activation ran AND the verifying re-query still
            # says off, so the PATCH did not take.
            $Findings.Blocking += ("Flow $($F.DeveloperName) is still switched off after activation was attempted " +
                                   "(v$($F.LatestVersion) is in the org). Switch it on in Setup and re-run.")
        }
    }
    foreach ($F in $FlowsStale) {
        if ($PlanOnly) {
            $Findings.Warning += ("Flow $($F.DeveloperName) runs v$($F.ActiveVersion) but v$($F.LatestVersion) is in this org. " +
                                  "A real run points it at the newer version; -PlanOnly does not write.")
        }
        else {
            $Findings.Blocking += ("Flow $($F.DeveloperName) still runs v$($F.ActiveVersion) after activation was attempted; " +
                                   "v$($F.LatestVersion) is in this org. Switch it on in Setup and re-run.")
        }
    }
    foreach ($F in $FlowsTrespassing) {
        $Findings.Blocking += ("Flow $($F.DeveloperName) must not exist in $Env - it bulk-deletes migrated records and is " +
                               "Dev-only. Investigate how it reached this org; do not simply deactivate it.")
    }

    <#
        7. RECORD OWNERS THE BUSINESS EXPECTS TO EXIST (added 2026-08-15).

        WHAT THIS IS NOT: it is not an ownership rule and it cannot change one.
        A record still goes to its Airtable owner where that person resolves to
        an active User, and to the fallback owner where they do not, exactly as
        before. Nothing below reassigns anything or stops a load.

        WHAT IT IS FOR: making a silent outcome a stated one, BEFORE the load
        rather than after. The fallback is deliberate and correct for someone
        who has left the team - that needs no action and should not be reported
        as a problem. It is NOT correct for someone who is current staff and
        simply never got provisioned; those records land on the fallback owner
        looking exactly like the intended case, and nothing in the run output
        distinguishes them. reference/salesforce-user-roster.csv is where the
        business states which is which, so this check can tell them apart.

        AN ABSENT OWNER NEVER BLOCKS. The load's behaviour is correct, so
        refusing to run would be stopping a working pipeline over a staffing
        question that only the business can answer.

        A PRESENT-BUT-UNUSABLE OWNER DOES BLOCK (added 2026-08-15), in Full and
        Prod only - which is automatic, since this whole check is inside the
        Full/Prod gate. Dev and QA discard these owners as missing and assign
        the fallback, exactly as before. Two cases:

          - the User exists under a DIFFERENT email address;
          - the User exists at the right address on a licence that cannot own
            a record (Chatter Free / portal).

        Neither is a staffing question. In both the person already exists and
        their records should reach them; something small and fixable stands in
        the way. Left as warnings they are indistinguishable from the legitimate
        absence printed directly above them in the same report.

        FULL AND PROD ONLY. Dev and QA are developer sandboxes seeded from
        partial refreshes and carry no expectation that the Partnerships team
        have logins at all - the project owner confirmed on 2026-08-15 that
        there is no guarantee these users exist there. Running it anyway would
        print a page of warnings on every development run, which is how a check
        stops being read.
    #>
    if ($Env -eq "Full" -or $Env -eq "Prod") {
        $RosterPath = Join-Path (Get-LdgcrmRoot) "reference\salesforce-user-roster.csv"

        if (-not (Test-Path -LiteralPath $RosterPath)) {
            $Findings.Warning += ("No owner roster at $RosterPath, so nothing can distinguish 'left the team' " +
                                  "from 'never provisioned' when a record lands on the fallback owner. See " +
                                  "reference/README.md.")
            Write-Host "  Owner roster           not found - skipping" -ForegroundColor Yellow
        }
        else {
            $Roster = @(Import-Csv -LiteralPath $RosterPath)

            # Live counts come from the export, never from the roster - a tracked
            # file carrying record counts is stale the next time Airtable is pulled.
            $OwnerCounts = @{}
            foreach ($Pair in @(
                @{ File = "Opportunities.json";    Field = "Pod Opportunity Lead" },
                @{ File = "Partner Accounts.json"; Field = "Account Owner" })) {

                $Path = Join-Path $ExportDir $Pair.File
                if (-not (Test-Path -LiteralPath $Path)) { continue }

                $Parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($Rec in @($Parsed)) {
                    $Collab = $Rec.fields.($Pair.Field)
                    if (-not $Collab -or -not $Collab.email) { continue }
                    $Key = ([string]$Collab.email).Trim().ToLower()
                    if (-not $OwnerCounts.ContainsKey($Key)) { $OwnerCounts[$Key] = 0 }
                    $OwnerCounts[$Key] = $OwnerCounts[$Key] + 1
                }
            }

            $RosterEmails = @($Roster | ForEach-Object { ([string]$_.Email).Trim().ToLower() } |
                              Where-Object { $_ } | Sort-Object -Unique)
            $Active = @{}
            if ($RosterEmails.Count -gt 0) {
                $Lookup = Resolve-SalesforceOwnerIds -Emails $RosterEmails -OrgAlias $Org -ApiVersion $Version
                $Active = $Lookup.IdByEmail
            }

            $MissingButExpected = New-Object System.Collections.Generic.List[object]
            $Unstated           = New-Object System.Collections.Generic.List[object]
            $PresentCount       = 0
            $CorrectlyAbsent    = 0

            foreach ($R in $Roster) {
                $Key = ([string]$R.Email).Trim().ToLower()
                if (-not $Key) { continue }
                $Expected = ([string]$R.ExpectedInSalesforce).Trim().ToLower()
                $Has      = $Active.ContainsKey($Key)
                $Records  = 0
                if ($OwnerCounts.ContainsKey($Key)) { $Records = $OwnerCounts[$Key] }

                if ($Expected -eq "yes" -and -not $Has) {
                    $MissingButExpected.Add([pscustomobject]@{ Email = $Key; Name = $R.Name; Records = $Records })
                }
                elseif ($Expected -eq "yes") { $PresentCount++ }
                elseif ($Expected -eq "no")  { if (-not $Has) { $CorrectlyAbsent++ } }
                else { $Unstated.Add([pscustomobject]@{ Email = $Key; Name = $R.Name; Records = $Records }) }
            }

            <#
                ABSENT is not the same failure as PRESENT UNDER A DIFFERENT
                EMAIL, and until 2026-08-15 this check could not tell them
                apart - both simply fell back to the default owner.

                The distinction the project owner drew: someone with no account
                is a legitimate state, and falling back is correct. Someone who
                HAS an account that the join misses is a defect - their records
                should have reached them and silently did not, the org is
                already correct, and only the address is wrong. That is fixable
                and therefore blocking.

                The known case is Tony Parrilla: Airtable has
                tony.parrilla@gsa.gov, which the project owner confirmed on
                2026-08-15 is the CORRECT address, while Dev holds his identity
                as antonio.parrilla@gsa.gov. Salesforce is what must change.

                DEV AND QA ARE UNAFFECTED - this whole block is already inside
                the Full/Prod gate, so a mismatch in a developer sandbox stays
                what it has always been: expected, and fine.

                THE NAME JOIN IS WEAK ON PURPOSE. A display name is not an
                identifier (Resolve-SalesforceOwnerIdsByName documents two real
                collisions in this org), so a name matching 2+ active Users
                only WARNS. Exactly one match is what blocks.
            #>
            $WrongEmail    = New-Object System.Collections.Generic.List[object]
            $NameAmbiguous = New-Object System.Collections.Generic.List[object]

            $ProbeNames = @($MissingButExpected | ForEach-Object { ([string]$_.Name).Trim() } |
                            Where-Object { $_ } | Sort-Object -Unique)

            if ($ProbeNames.Count -gt 0) {
                # Escape apostrophes - "O'Brien" would otherwise break the SOQL.
                $NameList = "'" + (@($ProbeNames | ForEach-Object { $_ -replace "'", "\'" }) -join "','") + "'"

                # DELIBERATELY NOT FILTERED TO UserType = 'Standard', unlike
                # Resolve-SalesforceOwnerIds. That filter is right for deciding
                # who may OWN a record and wrong for deciding whether a person
                # EXISTS. Filtering here would have reported Tony Parrilla -
                # active, Chatter Free, different address - as simply absent,
                # which is the exact confusion this block exists to remove.
                $ByName = @(Invoke-SalesforceQuery `
                    -Soql ("SELECT Name, Email, UserType FROM User WHERE IsActive = true " +
                           "AND Name IN ($NameList)") `
                    -OrgAlias $Org -ApiVersion $Version)

                $UsersByName = @{}
                foreach ($U in $ByName) {
                    $N = ([string]$U.Name).Trim()
                    if (-not $UsersByName.ContainsKey($N)) {
                        $UsersByName[$N] = New-Object System.Collections.Generic.List[object]
                    }
                    $UsersByName[$N].Add($U)
                }

                $StillMissing = New-Object System.Collections.Generic.List[object]

                foreach ($M in $MissingButExpected) {
                    $N = ([string]$M.Name).Trim()
                    if (-not $N -or -not $UsersByName.ContainsKey($N)) { $StillMissing.Add($M); continue }

                    $Candidates = @($UsersByName[$N])

                    if ($Candidates.Count -ne 1) {
                        $NameAmbiguous.Add([pscustomobject]@{
                            Email = $M.Email; Name = $M.Name; Records = $M.Records; Count = $Candidates.Count })
                        continue
                    }

                    # STRIP THE SANDBOX SUFFIX BEFORE COMPARING. A Full sandbox
                    # appends ".invalid" to every User.Email, so a raw compare
                    # would report EVERY roster owner as a mismatch there - the
                    # check would fire on all of them and mean nothing.
                    $Actual = ([string]$Candidates[0].Email).Trim().ToLower() -replace '\.invalid$', ''

                    # Same address means the address is not the problem, so the
                    # resolver rejected them for the only other reason it can:
                    # a licence that cannot own a record. Treated exactly like
                    # an absence - the load falls back either way - but the
                    # licence is named, because "no active user" sent someone
                    # hunting for an account that was there all along.
                    if ($Actual -eq $M.Email) {
                        $M | Add-Member -NotePropertyName LicenceType -NotePropertyValue ([string]$Candidates[0].UserType) -Force
                        $StillMissing.Add($M)
                        continue
                    }

                    $WrongEmail.Add([pscustomobject]@{
                        Email = $M.Email; Name = $M.Name; Records = $M.Records; ActualEmail = $Actual })
                }

                $MissingButExpected = $StillMissing
            }

            # Airtable owners nobody has put in the roster yet. Without this the
            # file silently goes stale as the Partnerships team changes.
            $NotInRoster = @($OwnerCounts.Keys | Where-Object { $RosterEmails -notcontains $_ })

            Write-Host ("  Owner roster           {0} named, {1} confirmed present" -f $Roster.Count, $PresentCount)

            foreach ($W in ($WrongEmail | Sort-Object Records -Descending)) {
                $Findings.Blocking += ("Owner '$($W.Email)' has an ACTIVE Salesforce User in $Env - '$($W.Name)' - but " +
                                       "under a DIFFERENT address: '$($W.ActualEmail)'. The ownership join is on email, " +
                                       "so their $($W.Records) record(s) would load onto the fallback owner as though " +
                                       "they had no account at all. The roster address is the correct one; correct the " +
                                       "Salesforce User's Email to '$($W.Email)' and re-run. Do NOT add an alias map to " +
                                       "the pipeline - see docs/engineering/BACKLOG.md section 8.")
                Write-Host ("                         WRONG EMAIL: {0} is '{1}' in {2} ({3} records)" -f `
                            $W.Email, $W.ActualEmail, $Env, $W.Records) -ForegroundColor Red
            }

            foreach ($A in ($NameAmbiguous | Sort-Object Records -Descending)) {
                $Findings.Warning += ("Owner '$($A.Email)' has no ACTIVE Salesforce User at that address in $Env, and " +
                                      "$($A.Count) active Users share the name '$($A.Name)' - so this cannot be called " +
                                      "a wrong address rather than an absence without a human looking. Their " +
                                      "$($A.Records) record(s) will load onto the fallback owner.")
                Write-Host ("                         NAME AMBIGUOUS: {0} ({1} users named '{2}')" -f `
                            $A.Email, $A.Count, $A.Name) -ForegroundColor Yellow
            }

            foreach ($M in ($MissingButExpected | Sort-Object Records -Descending)) {
                if ($M.PSObject.Properties.Name -contains "LicenceType") {
                    $Findings.Blocking += ("Owner '$($M.Email)' HAS an active Salesforce User in $Env at that exact " +
                                           "address, but on a '$($M.LicenceType)' licence, which cannot own standard " +
                                           "or custom records. Their $($M.Records) record(s) would load onto the " +
                                           "fallback owner as though the person did not exist. The account is not " +
                                           "missing and does not need creating - give it a Standard licence and " +
                                           "re-run.")
                    Write-Host ("                         LICENCE CANNOT OWN: {0} ('{1}', {2} records)" -f `
                                $M.Email, $M.LicenceType, $M.Records) -ForegroundColor Red
                }
                else {
                    $Findings.Warning += ("Owner '$($M.Email)' is marked ExpectedInSalesforce=yes in the roster but has " +
                                          "no ACTIVE Salesforce User in $Env, under that address or under their name. " +
                                          "Their $($M.Records) record(s) will load onto the fallback owner. Nothing " +
                                          "breaks - but if they are current staff this is a provisioning gap, and it " +
                                          "is invisible once the load has run.")
                    Write-Host ("                         EXPECTED BUT ABSENT: {0} ({1} records)" -f $M.Email, $M.Records) -ForegroundColor Yellow
                }
            }

            if ($CorrectlyAbsent -gt 0) {
                Write-Host ("                         {0} absent as expected (marked 'no') - fallback owner is correct" -f $CorrectlyAbsent) -ForegroundColor DarkGray
            }

            if ($Unstated.Count -gt 0) {
                $Findings.Warning += ("$($Unstated.Count) owner(s) in the roster have ExpectedInSalesforce=unknown, so a " +
                                      "record landing on the fallback owner cannot be read as either correct or a gap. " +
                                      "Ask the business to complete reference/salesforce-user-roster.csv.")
                Write-Host ("                         {0} still marked 'unknown'" -f $Unstated.Count) -ForegroundColor DarkGray
            }

            foreach ($N in ($NotInRoster | Sort-Object)) {
                $Findings.Warning += ("Airtable owner '$N' is not listed in reference/salesforce-user-roster.csv. Add the " +
                                      "row and ask the business whether they get a Salesforce account, or their records " +
                                      "will land on the fallback owner with nobody having said whether that is right.")
                Write-Host ("                         NOT IN ROSTER: {0}" -f $N) -ForegroundColor Yellow
            }
        }
    }

    <#
        8. THE CONTACT DUPLICATE RULE IS OFF (added 2026-08-15).

        OTCRM_Contact_Duplicate matches on FirstName + LastName ONLY, both
        Exact. It belongs to TTS OTCRM, not to this app, and it is what rejected
        167 Contacts with DUPLICATES_DETECTED on the 2026-08-15 Dev load -
        "there are 1,000 people named Robert Smith in the world; email should be
        unique, first and last name doesn't have to be" (project owner).

        THE LOAD SWITCHES THEM OFF ITSELF, in every environment including Prod
        (project owner, 2026-08-15: "these things should absolutely be performed
        on full sandbox and prod as part of the load"). It does not ask an
        operator to do it in Setup first. See
        Disable-LdgcrmContactDuplicateRules for the mechanism and for why a
        Metadata API round-trip is a setting flip rather than a promotion.

        WHY NOT A CHANGE SET. The original plan was to fix the rule (add Email)
        and promote it. That is impossible: Salesforce refuses to modify a
        matching rule that is Active in the target, and separately refuses any
        deployment that changes a rule's definition and its status together.
        Deactivating in the target to satisfy the first produces the second. No
        target state passes, because a change set always carries the SOURCE
        org's status and gives you no way to edit it. Both errors were seen, in
        that order, promoting into QA on 2026-08-15.

        BLOCKING IF IT DOES NOT WORK. With the rule on, the Contact step does
        not fail - it SUCCEEDS having quietly dropped rows, and every junction
        keyed on those Contacts is short by the same people. That is the same
        shape of failure as the inactive-Flows run, so the decision to proceed
        rests on a VERIFYING RE-QUERY below, never on the deploy's own success
        report.

        NOTHING IS RESTORED afterwards. The rules stay off permanently.
    #>
    $DuplicateRules = @(Invoke-SalesforceQuery `
        -Soql "SELECT DeveloperName, IsActive FROM DuplicateRule WHERE SobjectType = 'Contact'" `
        -OrgAlias $Org -ApiVersion $Version)

    # STRING COMPARE, NOT `Where-Object { $_.IsActive }`. Defensive, not a fix
    # for an observed bug: today the CLI's JSON gives a real boolean and the
    # naive test agrees. But EVERY non-empty string is truthy in PowerShell, so
    # the day this value arrives as "False" the naive test reports an inactive
    # rule as ACTIVE and blocks every load - and it fails in the safe-looking
    # direction, which is how it would survive review. -eq is case-insensitive,
    # so this reads a real boolean and its string form identically.
    $ActiveDuplicates = @($DuplicateRules | Where-Object { "$($_.IsActive)" -eq "true" })

    if ($ActiveDuplicates.Count -eq 0) {
        Write-Host ("  Contact dup rules      {0} present, none active" -f $DuplicateRules.Count)
    }
    else {
        Write-Host ("  Contact dup rules      {0} ACTIVE - switching off" -f $ActiveDuplicates.Count) -ForegroundColor Yellow

        $RuleOutcome = Disable-LdgcrmContactDuplicateRules `
            -Org $Org -Version $Version -WorkDirectory (Get-LogDirectory -Category "data-migration")

        foreach ($W in $RuleOutcome.Warning)  { $Findings.Warning += $W }
        foreach ($B in $RuleOutcome.Blocking) { $Findings.Blocking += $B }

        # VERIFYING RE-QUERY. Same principle as the flow activation and the
        # TriggerControls__c restore: a deploy reporting success is not proof the
        # org agrees. Re-read rather than trust the write - and this is the check
        # that actually decides whether the load may proceed, so a rule still
        # active here BLOCKS regardless of what the deploy said.
        Write-Host "  re-reading duplicate rule state to verify..." -ForegroundColor DarkGray

        $StillActive = @(Invoke-SalesforceQuery `
            -Soql "SELECT DeveloperName, IsActive FROM DuplicateRule WHERE SobjectType = 'Contact'" `
            -OrgAlias $Org -ApiVersion $Version |
            Where-Object { "$($_.IsActive)" -eq "true" })

        if ($StillActive.Count -eq 0) {
            Write-Host ("  Contact dup rules      {0} switched off and verified" -f $ActiveDuplicates.Count) -ForegroundColor Green
        }
        else {
            foreach ($Rule in $StillActive) {
                $Findings.Blocking += ("Contact duplicate rule '$($Rule.DeveloperName)' is STILL ACTIVE after the " +
                                       "pipeline tried to switch it off. Loading Contact now would report success " +
                                       "having silently dropped rows to DUPLICATES_DETECTED, and every junction keyed " +
                                       "on those Contacts would be short by the same people. Deactivate it in " +
                                       "Setup > Duplicate Rules and re-run. See docs/SETUP.md, 'Contact duplicate rule'.")
                Write-Host ("                         STILL ACTIVE: {0}" -f $Rule.DeveloperName) -ForegroundColor Red
            }
        }
    }

    # Reported for completeness only. A matching rule enforces nothing once no
    # active duplicate rule consumes it, so this never blocks - the pass above
    # already tried to switch these off and its failure is a warning by design.
    $ActiveMatching = @(Invoke-LdgcrmToolingQuery `
        -Soql "SELECT DeveloperName, RuleStatus FROM MatchingRule WHERE SobjectType = 'Contact'" `
        -Org $Org -Version $Version |
        Where-Object { $_.RuleStatus -eq "Active" })

    if ($ActiveMatching.Count -gt 0) {
        Write-Host ("                         {0} matching rule(s) still Active - inert, not blocking" -f $ActiveMatching.Count) -ForegroundColor DarkGray
    }

    return $Findings
}

function Save-RestorePoint {
    <#
        Captures what the org looks like BEFORE the load, for verification
        afterwards and as the basis of any rollback.

        WHY A PRE-IMAGE AND NOT JUST COUNTS: undoing an INSERT is easy - delete
        by external ID. Undoing an UPDATE is not, and this pipeline does update
        records it does not own. Build-AccountReconciliation.ps1 writes
        LDGCRM_External_ID__c, Market Segment and Type onto Accounts that existed
        long before the migration; the ownership pass overwrites OwnerId. Once
        those are overwritten the previous values are gone unless something
        wrote them down first. Nothing did, until this.

        Deleting a migrated record does NOT restore an updated one. That
        asymmetry is the single most important thing to understand about rolling
        this back.
    #>
    param([string]$Org, [string]$Version, [string]$Directory)

    Write-Host ""
    Write-Host "Capturing restore point..." -ForegroundColor Cyan

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null

    # Pre-image of the one object the migration UPDATES rather than creates.
    # Everything else it creates outright, and creations are undone by deleting.
    $Accounts = @(Invoke-SalesforceQuery `
        -Soql ("SELECT Id, Name, LDGCRM_External_ID__c, Type, OwnerId, " +
               "LDGCRM_Market_Segment__c FROM Account") `
        -OrgAlias $Org -ApiVersion $Version)

    $AccountFile = Join-Path $Directory "restore-point-Account.csv"
    $Accounts | Select-Object Id, Name, LDGCRM_External_ID__c, Type, OwnerId, LDGCRM_Market_Segment__c |
        Export-Csv -LiteralPath $AccountFile -NoTypeInformation -Encoding UTF8
    Write-Host ("  Account pre-image      {0} record(s) -> {1}" -f $Accounts.Count, (Split-Path -Leaf $AccountFile))

    # Baseline counts for every object the sequence touches, so the post-load
    # check compares against measured reality rather than a number in a doc.
    $Objects = @(
        "Account", "LDGCRM_Partner_Account__c", "Contact", "Opportunity",
        "LDGCRM_application__c", "LDGCRM_Impediment__c",
        "LDGCRM_Opportunity_Impediment__c", "LDGCRM_Application_Contact__c",
        "OpportunityContactRole", "LDGCRM_Market_Segment__c"
    )

    # WHICH external IDs were already here, not just how many.
    #
    # A count cannot answer the only question a rollback has to get right:
    # did THIS run create this record, or was it already in the org? Deleting
    # by external ID alone is safe in a sandbox, where the tagged set and the
    # migration's own output are the same thing - and wrong in production,
    # where a second run would delete the first run's records. The difference
    # between "created by this run" and "already present" is exactly the set
    # captured here, and it can only be captured BEFORE the load.
    #
    # This costs no extra queries: the tagged count below was already reading
    # these rows and discarding everything but the row count.
    $Baseline = [System.Collections.Generic.List[object]]::new()
    foreach ($Object in $Objects) {
        $Total = @(Invoke-SalesforceQuery -Soql "SELECT Id FROM $Object" -OrgAlias $Org -ApiVersion $Version).Count
        $Tagged = 0
        try {
            $Existing = @(Invoke-SalesforceQuery `
                -Soql "SELECT Id, LDGCRM_External_ID__c FROM $Object WHERE LDGCRM_External_ID__c != null" `
                -OrgAlias $Org -ApiVersion $Version)
            $Tagged = $Existing.Count

            # Written even when empty: an empty file is the positive statement
            # "nothing was tagged here before the run", which is what lets a
            # rollback delete the whole tagged set with confidence. A MISSING
            # file has to be read as "unknown", and unknown must not authorise
            # a delete.
            $Existing | Select-Object Id, LDGCRM_External_ID__c |
                Export-Csv -LiteralPath (Join-Path $Directory "external-ids-$Object.csv") -NoTypeInformation -Encoding UTF8
        }
        catch { $Tagged = -1 }   # object has no external ID field

        $Baseline.Add([PSCustomObject]@{ Object = $Object; Total = $Total; ExternalIdTagged = $Tagged })
    }

    $Captured = @($Baseline | Where-Object { $_.ExternalIdTagged -ge 0 })
    Write-Host ("  Pre-run external IDs   {0} object(s), {1:N0} tagged record(s) -> external-ids-*.csv" -f `
        $Captured.Count, (($Captured | Measure-Object -Property ExternalIdTagged -Sum).Sum))

    $BaselineFile = Join-Path $Directory "baseline-counts.csv"
    $Baseline | Export-Csv -LiteralPath $BaselineFile -NoTypeInformation -Encoding UTF8
    Write-Host ("  Baseline counts        {0} object(s) -> {1}" -f $Baseline.Count, (Split-Path -Leaf $BaselineFile))

    # HOW MANY FCIC JUNK ACCOUNTS ALREADY EXIST.
    #
    # The post-load check asks whether the Contact trigger bypass held, and it
    # used to answer that by testing for ZERO FCIC_Individual Accounts. That is
    # wrong in any org where the trigger has ever fired before: Dev carries 4
    # from an 18-row Contact test batch on 2026-08-13, and they carry no
    # external ID, so the factory reset deliberately leaves them alone. The
    # check would therefore have reported a bypass failure on every single run,
    # for ever - and a check that cries wolf every run is one nobody reads,
    # which is worse than not having it.
    #
    # What actually indicates a bypass failure is the DELTA, so record the
    # starting figure here. Kept as a file rather than added to $Baseline
    # because the post-load loop treats every row there as a queryable object.
    $JunkBefore = @(Invoke-SalesforceQuery `
        -Soql "SELECT Id FROM Account WHERE RecordType.DeveloperName = 'FCIC_Individual'" `
        -OrgAlias $Org -ApiVersion $Version).Count

    Set-Content -LiteralPath (Join-Path $Directory "fcic-junk-baseline.txt") -Value $JunkBefore -Encoding ASCII
    Write-Host ("  FCIC junk Accounts     {0} already present (pre-existing, not deleted by a reset)" -f $JunkBefore)

    return $Baseline
}

function Invoke-PostLoadValidation {
    <#
        Checks the things that go wrong QUIETLY. Success counts are not
        evidence: every serious defect in this migration passed its load and was
        found afterwards by looking at something else.
    #>
    param([string]$Org, [string]$Version, $Baseline, [string]$Directory)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " POST-LOAD VALIDATION" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # Problems FAIL the run (exit 1). Notices are known, currently-expected
    # incompletenesses - reported just as loudly, but they must not turn every
    # run red, because a run that is always red stops being read.
    $Problems = [System.Collections.Generic.List[string]]::new()
    $Notices = [System.Collections.Generic.List[string]]::new()

    # 1. Counts, before vs after.
    Write-Host ""
    Write-Host ("  {0,-34} {1,8} {2,8} {3,8}" -f "OBJECT", "BEFORE", "AFTER", "DELTA")
    $After = [System.Collections.Generic.List[object]]::new()

    foreach ($Row in $Baseline) {
        $Total = @(Invoke-SalesforceQuery -Soql "SELECT Id FROM $($Row.Object)" -OrgAlias $Org -ApiVersion $Version).Count
        $Delta = $Total - $Row.Total
        Write-Host ("  {0,-34} {1,8:N0} {2,8:N0} {3,8}" -f $Row.Object, $Row.Total, $Total, ("{0:+#;-#;0}" -f $Delta))
        $After.Add([PSCustomObject]@{ Object = $Row.Object; Before = $Row.Total; After = $Total; Delta = $Delta })
    }

    $After | Export-Csv -LiteralPath (Join-Path $Directory "post-load-counts.csv") -NoTypeInformation -Encoding UTF8

    # 2. Junk FCIC Accounts. The Contact trigger creates one Account per Contact
    #    inserted with a blank AccountId; the bypass is supposed to stop that.
    #    An Account delta far above what the reconciliation explains is the tell.
    #    Measured as a DELTA against the pre-run figure, not against zero - an
    #    org where the trigger has fired before keeps those Accounts for ever
    #    (they carry no external ID, so no reset removes them). See the note in
    #    Save-RestorePoint.
    $Junk = @(Invoke-SalesforceQuery `
        -Soql "SELECT Id FROM Account WHERE RecordType.DeveloperName = 'FCIC_Individual'" `
        -OrgAlias $Org -ApiVersion $Version).Count

    $JunkBaselineFile = Join-Path $Directory "fcic-junk-baseline.txt"
    $JunkBefore = if (Test-Path -LiteralPath $JunkBaselineFile) {
        [int](Get-Content -LiteralPath $JunkBaselineFile -Raw).Trim()
    } else { 0 }

    $JunkNew = $Junk - $JunkBefore
    Write-Host ""
    Write-Host ("  FCIC_Individual Accounts (junk)        {0} now, {1} before, {2} new" -f $Junk, $JunkBefore, ("{0:+#;-#;0}" -f $JunkNew))
    if ($JunkNew -gt 0) {
        $Problems.Add("$JunkNew NEW FCIC_Individual Account(s) were created during this run - the Contact trigger bypass did not hold.")
    }

    # 3. The trigger switch must be back ON. Leaving it off silently breaks
    #    another team's app in a shared org.
    $Controls = @(Invoke-SalesforceQuery -Soql "SELECT On__c FROM TriggerControls__c WHERE Name = 'Contact'" -OrgAlias $Org -ApiVersion $Version)
    if ($Controls.Count -eq 1) {
        Write-Host ("  TriggerControls__c Contact.On__c       {0}" -f $Controls[0].On__c)
        if (-not $Controls[0].On__c) { $Problems.Add("TriggerControls__c 'Contact' is still OFF. Restore it - another app depends on that trigger.") }
    }

    # 4. Nothing may be owned by an inactive user: Salesforce refuses to ASSIGN
    #    one, so any hit means an owner was deactivated mid-run or the resolver
    #    regressed.
    foreach ($Object in @("Opportunity", "Contact", "LDGCRM_application__c")) {
        $Inactive = @(Invoke-SalesforceQuery `
            -Soql "SELECT Id FROM $Object WHERE Owner.IsActive = false AND LDGCRM_External_ID__c != null" `
            -OrgAlias $Org -ApiVersion $Version).Count
        Write-Host ("  {0,-38} {1} record(s) owned by an inactive user" -f $Object, $Inactive)
        if ($Inactive -gt 0) { $Problems.Add("$Object has $Inactive migrated record(s) owned by an inactive user.") }
    }

    # 5. Market Segment comes from before-save Flows. Blank across the board
    #    means the Flows did not fire, which no load error would have reported.
    foreach ($Object in @("Opportunity", "LDGCRM_application__c")) {
        $Blank = @(Invoke-SalesforceQuery `
            -Soql "SELECT Id FROM $Object WHERE LDGCRM_Market_Segment__c = null AND LDGCRM_External_ID__c != null" `
            -OrgAlias $Org -ApiVersion $Version).Count
        Write-Host ("  {0,-38} {1} migrated record(s) with no Market Segment" -f $Object, $Blank)
    }

    # 6. WROTE-WHAT-WE-INTENDED, for the two fields that can go empty in silence.
    #
    #    Both are sourced from the Issuer Strings table, which is newer than the
    #    rest of the pipeline and has two failure modes that produce a load the
    #    Bulk API calls a complete success:
    #      - the export is missing/stale, so the source is simply absent;
    #      - the email match that finds Partner Portal Admins stops resolving.
    #    In both cases the CSV is written, every row loads, and a field is just
    #    blank. Nothing in a success count would show it.
    #
    #    Checked against the LOAD FILE rather than a hard-coded expectation, so
    #    the check re-baselines itself every time Airtable changes instead of
    #    going stale and being ignored - which is how a check like this dies.
    #
    #    THE COMPARISON IS DELIBERATELY ONE-SIDED: only actual < intended is a
    #    problem. actual > intended is normal and must not fail the run - an
    #    upsert never deletes, so the org keeps rows from earlier runs whose
    #    Airtable source has since been withheld (e.g. its Application became
    #    unloadable). Measured 2026-08-13: 664 admin flags in the org against 573
    #    in the current file, purely from a larger earlier load.
    $LoadDirectory = Get-SalesforceLoadDirectory

    $ApplicationCsv = Join-Path $LoadDirectory "LDGCRM_application__c-upsert.csv"
    if (Test-Path -LiteralPath $ApplicationCsv) {
        $AppRows = @(Import-Csv -LiteralPath $ApplicationCsv)
        $HasTeamColumn = $AppRows.Count -gt 0 -and
            ($AppRows[0].PSObject.Properties.Name -contains "LDGCRM_P3_Team_UUID__c")

        if ($HasTeamColumn) {
            $IntendedTeam = @($AppRows | Where-Object { $_.LDGCRM_P3_Team_UUID__c }).Count
            $ActualTeam = @(Invoke-SalesforceQuery `
                -Soql ("SELECT Id FROM LDGCRM_application__c " +
                       "WHERE LDGCRM_P3_Team_UUID__c != null AND LDGCRM_External_ID__c != null") `
                -OrgAlias $Org -ApiVersion $Version).Count
            Write-Host ("  Partner Portal Team UUID               {0} intended, {1} in the org" -f $IntendedTeam, $ActualTeam)
            if ($ActualTeam -lt $IntendedTeam) {
                $Problems.Add("Partner Portal Team UUID is set on only $ActualTeam Application(s) but $IntendedTeam were submitted - $($IntendedTeam - $ActualTeam) did not land.")
            }
        }
        else {
            # Not a regression - the transform withholds these columns while the
            # fields are still unique=true. Reported so a run cannot look
            # complete while two fields are empty org-wide.
            Write-Host "  Partner Portal Team                    WITHHELD from the load (see notice below)" -ForegroundColor Yellow
            $Notices.Add("Partner Portal Team Name/UUID were NOT loaded: Build-ApplicationLoad.ps1 withholds both columns while they are unique=true in this org. Every Application will have them empty. Needs a CHANGE SET setting Unique = false on both, then a plain re-run. Not a regression.")
        }
    }

    $JunctionCsv = Join-Path $LoadDirectory "LDGCRM_Application_Contact__c-upsert.csv"
    if (Test-Path -LiteralPath $JunctionCsv) {
        $JunctionRows = @(Import-Csv -LiteralPath $JunctionCsv)
        $IntendedAdmin = @($JunctionRows | Where-Object { $_.LGDCRM_P3_Partner_Portal_Admin__c -eq "true" }).Count
        $ActualAdmin = @(Invoke-SalesforceQuery `
            -Soql ("SELECT Id FROM LDGCRM_Application_Contact__c " +
                   "WHERE LGDCRM_P3_Partner_Portal_Admin__c = true AND LDGCRM_External_ID__c != null") `
            -OrgAlias $Org -ApiVersion $Version).Count
        Write-Host ("  Partner Portal Admin flag              {0} intended, {1} in the org" -f $IntendedAdmin, $ActualAdmin)

        if ($ActualAdmin -lt $IntendedAdmin) {
            $Problems.Add("Partner Portal Admin is set on only $ActualAdmin junction row(s) but $IntendedAdmin were submitted - $($IntendedAdmin - $ActualAdmin) did not land.")
        }
        if ($IntendedAdmin -eq 0 -and $JunctionRows.Count -gt 0) {
            # Both sources silent at once means the source broke, not that
            # nobody administers anything.
            $Problems.Add("No Application-Contact row was flagged Partner Portal Admin. Both sources (Contacts.Roles and Issuer Strings' Partner Portal Admin Email) came back empty - check the Airtable export is current and includes Issuer Strings.")
        }
    }

    return [PSCustomObject]@{ Problems = $Problems; Notices = $Notices }
}

function New-StepRecord {
    <#
        One step's line in the run report: what it loaded, plus everything its
        transform wrote to logs/ while it was running.

        BUILT HERE RATHER THAN AT EACH `$Results.Add` SITE because the loop has
        six different exits (transform failed, plan-only, no rows, expected
        partial, load failed, loaded) and the report must be identical from all
        of them. A step that failed is the one whose findings matter most, and
        it is also the easiest to forget.

        -Since is the moment before the transform started. Everything the step
        wrote falls between that and now, which is how review CSVs are
        attributed to a step without touching a single transform - see
        Get-LoadRunFindings.
    #>
    param(
        [Parameter(Mandatory = $true)]$Step,
        [int]$Rows = 0,
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][datetime]$Since,
        [string]$StepResultFile = ""
    )

    $Findings = @()
    try { $Findings = @(Get-LoadRunFindings -Since $Since -Until (Get-Date) -StepName $Step.Name) }
    catch {
        # A reporting failure must never change the outcome of a load.
        Write-Host ("  (could not collect review output for {0}: {1})" -f $Step.Name, $_.Exception.Message) -ForegroundColor DarkGray
    }

    $StepResult = $null
    if ($StepResultFile -and (Test-Path -LiteralPath $StepResultFile)) {
        try { $StepResult = (Get-Content -LiteralPath $StepResultFile -Raw | ConvertFrom-Json) }
        catch { $StepResult = $null }
    }

    return [PSCustomObject]@{
        Step       = $Step.Name
        Object     = $Step.Object
        Rows       = $Rows
        Result     = $Result
        StepResult = $StepResult
        Findings   = $Findings
    }
}

function Invoke-ChildScript {
    <#
        Runs a pipeline script in its own process and returns the exit code.

        CHILD PROCESS, NOT DOT-SOURCED, for the same reasons the factory reset
        uses one: a failure must not take down this orchestrator's transcript or
        summary, and each script keeps its own log file rather than smearing
        eighteen runs into one.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    Write-Host ""
    Write-Host ("  > {0} {1}" -f (Split-Path -Leaf $ScriptPath), ($Arguments -join " ")) -ForegroundColor DarkGray

    # Out-Host, not a bare call: a child process writes its stdout to the
    # PIPELINE, so without this the function returns every line the child
    # printed AND the exit code, and the caller's "-ne 0" test compares an
    # array. That made a successful step report "TRANSFORM FAILED (exit <the
    # entire transcript>)" - caught on the first smoke test.
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments | Out-Host

    return $LASTEXITCODE
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " FULL MIGRATION LOAD" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$OrgInfo = Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias

# --- select the steps to run ------------------------------------------------
$Selected = @($Steps)

if ($OnlySteps) {
    $Wanted = @($OnlySteps -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $Selected = @($Steps | Where-Object { $Wanted -contains $_.Name })

    $Unknown = @($Wanted | Where-Object { $Steps.Name -notcontains $_ })
    if ($Unknown.Count -gt 0) {
        throw "Unknown step name(s): $($Unknown -join ', '). Valid: $($Steps.Name -join ', ')"
    }
}
elseif ($StartAtStep) {
    $Index = [array]::IndexOf(@($Steps.Name), $StartAtStep)
    if ($Index -lt 0) {
        throw "Unknown step '$StartAtStep'. Valid: $($Steps.Name -join ', ')"
    }
    $Selected = @($Steps[$Index..($Steps.Count - 1)])
}

Write-Host ""
Write-Host "Plan ($($Selected.Count) of $($Steps.Count) steps):" -ForegroundColor Cyan
Write-Host ""
$Position = 0
foreach ($Step in $Selected) {
    $Position++
    $Operation = Get-StepProperty -Step $Step -Key "Operation" -Default "Upsert"
    Write-Host ("  {0,2}. {1,-24} {2,-8} {3}" -f $Position, $Step.Name, $Operation, $Step.Object)
    Write-Host ("      {0}" -f $Step.Why) -ForegroundColor DarkGray
}

if ($PlanOnly) {
    Write-Host ""
    Write-Host "-PlanOnly: transforms will run (read-only); NOTHING will be loaded." -ForegroundColor Yellow
}
elseif ($Environment -eq "Prod") {
    Write-Host ""
    Write-Host "*** TARGET IS PRODUCTION. REAL PARTNER DATA. ***" -ForegroundColor Red
    Write-Host "Every step requires -ProductionConfirmation in addition to -Confirmation." -ForegroundColor Red
}

# --- PRE-FLIGHT -------------------------------------------------------------
# The run directory Start-ScriptLog created. Every step - transform, loader,
# notes loader - inherits it through $env:LDGCRM_RUN_DIRECTORY, so this one
# folder ends up holding the whole load: transcripts, review CSVs, bulk failure
# rows, the restore point and the report. See Common.ps1's "one directory per
# run" block.
$RunDirectory = Get-LogDirectory -Category "data-migration"

# Flow activation used to be blocked here for -Environment Prod, on the grounds
# that switching a Flow on is change-controlled and belongs to a person in
# Setup. That was inconsistent with what this script already does to production
# in the Contact step, where it deactivates another team's duplicate and
# matching rules permanently, through a heavier mechanism - a metadata retrieve
# and redeploy, rather than the one-field setting PATCH a flow needs. Removed
# 2026-08-18 at the project owner's direction: pre-flight now activates in every
# environment, so production cannot be the one org that loads with its
# automation off because somebody forgot a manual step.

# --- optional readiness check ----------------------------------------------
# Runs before pre-flight: it checks org shape, pre-flight checks run-time state.
# Child process so there is one implementation and it stays runnable standalone.
if ($Readiness) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " READINESS CHECK (-Readiness)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    $ReadinessCode = Invoke-ChildScript `
        -ScriptPath (Join-Path $PSScriptRoot "Test-LdgcrmReadiness.ps1") `
        -Arguments @("-Environment", $Environment)

    if ($ReadinessCode -ne 0) {
        Write-Host ""
        Write-Host "READINESS CHECK FAILED - nothing was run." -ForegroundColor Red
        Write-Host "Fix the failures above, or re-run without -Readiness." -ForegroundColor Yellow
        # -ContinueOnError does not apply: that covers a step failing mid-load.
        exit 1
    }

    Write-Host ""
    Write-Host "Readiness check passed." -ForegroundColor Green
}

$Findings = Invoke-PreflightChecks -Org $OrgAlias -Version "67.0" -Env $Environment `
    -SelectedSteps @($Selected.Name)

if ($Findings.Warning.Count -gt 0) {
    Write-Host ""
    foreach ($Warning in $Findings.Warning) { Write-Host "  WARNING: $Warning" -ForegroundColor Yellow }
}

if ($Findings.Blocking.Count -gt 0) {
    Write-Host ""
    Write-Host "PRE-FLIGHT FAILED - nothing was run:" -ForegroundColor Red
    foreach ($Problem in $Findings.Blocking) { Write-Host "  - $Problem" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "Pre-flight passed." -ForegroundColor Green

# The restore point is captured even on -PlanOnly: it is read-only, and having
# one from a dry run costs nothing and is occasionally exactly what you want.
$Baseline = Save-RestorePoint -Org $OrgAlias -Version "67.0" -Directory $RunDirectory

# --- optional Account bootstrap --------------------------------------------
# Deliberately not a step in the table: it rebuilds a baseline the migration
# does not own, it is sandbox-only, and it has its own confirmation token.
if ($BootstrapAccounts) {
    # Dev and QA only. Was an "-eq Prod" check until 2026-08-14, which let it
    # through in a Full sandbox - where the Accounts are the real production
    # records, so the bootstrap would have inserted a duplicate universe
    # alongside them from a stale export. The rule now comes from the registry
    # so this cannot disagree with the factory reset or the bootstrap itself.
    if (-not (Test-LdgcrmAccountRebuildAllowed -Environment $Environment)) {
        throw ("SAFETY STOP: -BootstrapAccounts inserts Accounts from a production export, and " +
               "environment '$Environment' already holds the real ones - running it there would " +
               "duplicate them from a stale export. It is supported in Dev and QA only. " +
               "Nothing was run.")
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " STEP 0: Account bootstrap" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    if ($PlanOnly) {
        $Code = Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "Invoke-AccountBootstrap.ps1") `
            -Arguments @("-Environment", $Environment, "-PlanOnly")
    }
    else {
        $BootstrapArgs = @("-Environment", $Environment)
        if ($Confirmation) { $BootstrapArgs += @("-Confirmation", "BOOTSTRAP") }
        $Code = Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "Invoke-AccountBootstrap.ps1") `
            -Arguments $BootstrapArgs
    }

    if ($Code -ne 0 -and -not $ContinueOnError) {
        throw "Account bootstrap failed (exit $Code). Nothing further was run."
    }
}

# --- run the sequence -------------------------------------------------------
$Results = [System.Collections.Generic.List[object]]::new()
$LoadDir = Get-SalesforceLoadDirectory
$Position = 0
$Failed = $false
# Set when a step loaded with expected partial failures. Reported prominently,
# but deliberately does NOT make the run exit non-zero - see the summary.
$Partial = $false

foreach ($Step in $Selected) {
    $Position++

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host (" STEP {0}/{1}: {2}" -f $Position, $Selected.Count, $Step.Name) -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    $BuildScript = Get-StepProperty -Step $Step -Key "Build"
    $TransformCode = 0

    # Marks the boundary a freshly-written CSV must fall on the far side of.
    # Taken BEFORE the transform runs - see the staleness check below.
    $TransformStart = Get-Date

    # PopulateBrokerParent has no transform of its own - Build-ApplicationLoad.ps1
    # produces its file as a side effect, which is the whole point of
    # generating it automatically rather than as a separate script.
    if ($BuildScript) {
        $TransformCode = Invoke-ChildScript `
            -ScriptPath (Join-Path $PSScriptRoot $BuildScript) `
            -Arguments @("-Environment", $Environment)
    }
    else {
        Write-Host "  (no transform - its file is produced by an earlier step)" -ForegroundColor DarkGray
    }

    $CsvPath = Join-Path $LoadDir $Step.Csv
    $RowCount = 0
    $Stale = $false

    if (Test-Path -LiteralPath $CsvPath) {
        # A TRANSFORM THAT WRITES NOTHING LEAVES THE LAST RUN'S FILE BEHIND.
        #
        # Every Build-*.ps1 skips writing its CSV when it has no rows to emit
        # ("No Account records need updating - nothing written to ...") rather
        # than truncating it. So the file at the expected path may belong to a
        # previous run, and counting it reports rows this run did not produce -
        # or, worse, LOADS them. Caught 2026-08-13 on a -PlanOnly run that
        # reported 587 Account rows and 503 OpportunityContactRole rows from
        # files dated the previous day, while both transforms had just printed
        # a count of zero.
        #
        # Stale data in an Account update file is stale Salesforce Ids, which
        # after a factory reset point at deleted records. That fails loudly.
        # The quiet case is -StartAtStep / -OnlySteps, where an operator
        # resuming a failed run re-loads an older file believing it is current
        # - which is the resume path the Operations team will actually use.
        #
        # Only applies where the transform that OWNS the file ran in this
        # invocation. PopulateBrokerParent's file is written by the Application
        # step, so on a -StartAtStep PopulateBrokerParent resume it is
        # legitimately older than this run; that is reported, not suppressed.
        $Written = (Get-Item -LiteralPath $CsvPath).LastWriteTime

        if ($BuildScript -and $Written -lt $TransformStart) {
            $Stale = $true
            Write-Host ""
            Write-Host ("  {0} was NOT written by this run (last written {1:yyyy-MM-dd HH:mm})." -f $Step.Csv, $Written) -ForegroundColor Yellow
            Write-Host "  Transform produced no rows. Step counted as 0; file not loaded." -ForegroundColor Yellow
        }
        else {
            $RowCount = @(Import-Csv -LiteralPath $CsvPath).Count
            if (-not $BuildScript -and $Written -lt $RunStart) {
                Write-Host ("  {0} predates this run (last written {1:yyyy-MM-dd HH:mm})." -f $Step.Csv, $Written) -ForegroundColor Yellow
                Write-Host "  Its transform did not run in this invocation." -ForegroundColor Yellow
            }
        }
    }

    if ($TransformCode -ne 0) {
        $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart `
            -Result "TRANSFORM FAILED (exit $TransformCode)"))
        $Failed = $true
        if (-not $ContinueOnError) { break }
        continue
    }

    if ($PlanOnly) {
        $Outcome = if ($Stale) { "no rows (stale file ignored)" } else { "planned (not loaded)" }
        $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart -Result $Outcome))
        continue
    }

    if ($RowCount -eq 0) {
        $Outcome = if ($Stale) { "skipped (no rows; stale file ignored)" } else { "skipped (no rows)" }
        Write-Host "  Nothing to load - transform produced no rows." -ForegroundColor Yellow
        $Results.Add((New-StepRecord -Step $Step -Rows 0 -Since $TransformStart -Result $Outcome))
        continue
    }

    # --- load --------------------------------------------------------------
    # Where the load step reports what it did, in machine-readable form. The
    # child's exit code carries three states; this carries the counts, the
    # per-error classification and the job id. See -StepResultPath in
    # Invoke-SalesforceLoad.ps1.
    $StepResultFile = Join-Path $RunDirectory "step-result-$($Step.Name).json"

    if ((Get-StepProperty -Step $Step -Key "Loader" -Default "Standard") -eq "Notes") {
        $LoadArgs = @("-Environment", $Environment, "-StepResultPath", $StepResultFile)
        if ($Confirmation) { $LoadArgs += @("-Confirmation", $Confirmation) }
        if ($ProductionConfirmation) { $LoadArgs += @("-ProductionConfirmation", $ProductionConfirmation) }

        $LoadCode = Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "Invoke-NotesLoad.ps1") -Arguments $LoadArgs
    }
    else {
        $LoadArgs = @(
            "-Environment", $Environment,
            "-ObjectApiName", $Step.Object,
            "-CsvFile", $CsvPath,
            "-Operation", (Get-StepProperty -Step $Step -Key "Operation" -Default "Upsert"),
            "-StepResultPath", $StepResultFile
        )
        $TriggerOff = Get-StepProperty -Step $Step -Key "TriggerOff"
        if ($TriggerOff) { $LoadArgs += @("-DisableTriggerControl", $TriggerOff) }
        if ($Confirmation) { $LoadArgs += @("-Confirmation", $Confirmation) }
        if ($ProductionConfirmation) { $LoadArgs += @("-ProductionConfirmation", $ProductionConfirmation) }

        $ExpectedFailures = @(Get-StepProperty -Step $Step -Key "ExpectedFailures" -Default @())
        foreach ($Pattern in $ExpectedFailures) {
            $LoadArgs += @("-ExpectedFailurePatterns", $Pattern)
        }

        $LoadCode = Invoke-ChildScript -ScriptPath (Join-Path $PSScriptRoot "Invoke-SalesforceLoad.ps1") -Arguments $LoadArgs
    }

    # Exit 2 = loaded, with failures that all match this object's known causes
    # and sit within the allowance. A correct outcome, so the sequence CONTINUES -
    # this is the whole point of the expected-partial work. Before it, the run
    # halted here and an operator had to diagnose and resume by hand; that
    # happened twice in the 2026-08-13 reload, both times on a correct load.
    if ($LoadCode -eq 2) {
        $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart `
            -Result "PARTIAL (expected failures)" -StepResultFile $StepResultFile))
        $Partial = $true
        continue
    }

    if ($LoadCode -ne 0) {
        $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart `
            -Result "LOAD FAILED (exit $LoadCode)" -StepResultFile $StepResultFile))
        $Failed = $true
        if (-not $ContinueOnError) { break }
        continue
    }

    $Results.Add((New-StepRecord -Step $Step -Rows $RowCount -Since $TransformStart `
        -Result "loaded" -StepResultFile $StepResultFile))
}

# --- summary ----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " FULL MIGRATION LOAD - SUMMARY" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host ("  {0,-24} {1,8} {2}" -f "STEP", "ROWS", "RESULT")
foreach ($Result in $Results) {
    $Colour = if ($Result.Result -like "*FAILED*") { "Red" }
              elseif ($Result.Result -like "PARTIAL*") { "Yellow" }
              elseif ($Result.Result -eq "loaded") { "Green" }
              else { "Gray" }
    Write-Host ("  {0,-24} {1,8:N0} {2}" -f $Result.Step, $Result.Rows, $Result.Result) -ForegroundColor $Colour
}
Write-Host ""

if ($Partial) {
    Write-Host "PARTIAL: rows were rejected, all matching a configured cause. Sequence continued." -ForegroundColor Yellow
    Write-Host "Per-row detail: <object>-<jobid>-failed-records.csv" -ForegroundColor DarkGray
    Write-Host ""
}

# --- post-load validation ---------------------------------------------------
# Runs before the report so its findings can go INTO the report. Skipped on
# -PlanOnly (nothing was written to validate) and after a failure (the org is
# half-loaded by definition, so every check would fire and none would mean
# anything).
$Validation = $null
$Problems = @()

if (-not $PlanOnly -and -not $Failed) {
    $Validation = Invoke-PostLoadValidation -Org $OrgAlias -Version "67.0" -Baseline $Baseline -Directory $RunDirectory
    $Problems = @($Validation.Problems)
    $Notices = @($Validation.Notices)

    Write-Host ""
    if ($Problems.Count -gt 0) {
        Write-Host "POST-LOAD VALIDATION PROBLEMS:" -ForegroundColor Red
        foreach ($Problem in $Problems) { Write-Host "  - $Problem" -ForegroundColor Red }
    }
    else {
        Write-Host "Post-load validation passed." -ForegroundColor Green
    }

    if ($Notices.Count -gt 0) {
        Write-Host ""
        Write-Host "INCOMPLETE - loaded, with known data still missing:" -ForegroundColor Yellow
        foreach ($Notice in $Notices) { Write-Host "  - $Notice" -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "These do not fail the run. They are waiting on something outside this repo." -ForegroundColor DarkGray
    }
}

# --- the run report ---------------------------------------------------------
# WRITTEN ON EVERY PATH, INCLUDING A FAILED ONE. A run that stopped at step
# four is precisely the run whose report is worth reading: it shows what the
# first three steps withheld, which is usually why the fourth failed. Writing
# it only on success would remove it exactly when it is needed.
#
# Wrapped, because a defect in reporting must not be able to change the outcome
# of a load. If this throws, the run keeps its own verdict and the operator
# still has every underlying file.
try {
    $ReportText = Write-LoadRunReport `
        -RunDirectory $RunDirectory `
        -Steps $Results `
        -Validation $Validation `
        -Header @{
            Environment = $Environment
            Org         = $OrgAlias
            Started     = $RunStart
            Mode        = if ($PlanOnly) { "PLAN ONLY - nothing was loaded" } else { "LOAD" }
        }

    Write-Host ""
    Write-Host $ReportText
}
catch {
    Write-Host ""
    Write-Host "Could not write the run report: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "The run's own result stands; every underlying file is still in $RunDirectory" -ForegroundColor DarkGray
}

if ($Failed) {
    $LastStep = $Results[$Results.Count - 1].Step
    Write-Host ""
    Write-Host "STOPPED at '$LastStep'. Remaining steps did not run." -ForegroundColor Red
    Write-Host "Resume with:" -ForegroundColor Yellow
    Write-Host ("  Invoke-FullMigrationLoad.ps1 -Environment {0} -StartAtStep {1}" -f $Environment, $LastStep) -ForegroundColor DarkGray
    exit 1
}

if ($PlanOnly) {
    Write-Host "-PlanOnly: nothing was loaded. Re-run without it (and with -Confirmation `"LOAD`") to apply." -ForegroundColor Yellow
    Write-Host "Restore point and baseline counts: $RunDirectory" -ForegroundColor DarkGray
}
else {
    Write-Host "Verification steps: docs/RELOAD-QA-CHECKLIST.md" -ForegroundColor Cyan

    if ($Problems.Count -gt 0) { exit 1 }
}

}
finally {
    Stop-ScriptLog
}
