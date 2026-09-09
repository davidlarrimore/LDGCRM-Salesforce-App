#Requires -Version 5.1

<#
    Stands up the P3 Partner Portal API integration user in one org: creates the
    User, assigns the Salesforce API Integration permission set LICENSE, then
    assigns the LDGCRM_Partnership_Portal_API_R permission set - in that order,
    because the order is not a preference.

        scripts\Set-LdgcrmIntegrationUser.ps1 -Environment Dev
        scripts\Set-LdgcrmIntegrationUser.ps1 -Environment QA -Apply

    scripts/docs/integration-user.md is the runbook this automates. Read it for
    WHY each step exists; this header covers only what the script does about it.

    =========================================================================
    IT REPORTS BY DEFAULT AND WRITES ONLY WITH -Apply
    =========================================================================
    Without -Apply nothing is created. The script reads the org, prints exactly
    what it WOULD do, and stops - so the plan can be checked against the target
    before anything exists. Every step is idempotent: a step already done is
    reported as already done and skipped, so a re-run after a partial failure
    finishes the job rather than duplicating it.

    =========================================================================
    THIS ONE MAY TARGET PRODUCTION, AND THAT IS THE WHOLE POINT
    =========================================================================
    tools/data-loading/ is [ValidateSet("Dev","QA")] and must stay that way: its
    job is hard-deleting records, and production has no business being reachable
    from it. CLAUDE.md says a production-side operation belongs in a SEPARATE,
    PURPOSE-BUILT TOOL rather than behind a widened ValidateSet on that one.
    This is that separate tool, authorised for Sprint 2 (user, 2026-09-09), and
    it carries its OWN registry below rather than widening anyone else's.

    What it is allowed to do is correspondingly narrow. It creates ONE user with
    ONE known shape and assigns TWO things to it. It does not delete, it does not
    modify records, and it does not touch metadata.

    Production additionally requires a typed confirmation token. A sandbox does
    not: -Apply is the gate there, because a developer sandbox costs a refresh to
    put right and production does not.

    =========================================================================
    THE TARGET IS PROVEN AGAINST THE ORG, NOT AGAINST A LOCAL CACHE
    =========================================================================
    Organization.IsSandbox is read FROM the org, because `sf org list` reads a
    local cache and the cache is the very thing being verified. An alias IS the
    org's own sandbox name here, so it is checked against the instance URL and
    cannot silently drift. Targeting Prod against something that reports itself a
    sandbox stops the run, and so does the reverse.

    =========================================================================
    USERNAMES ARE LISTED, NOT DERIVED, BECAUSE DEV BREAKS THE PATTERN
    =========================================================================
    QA, UAT and Prod follow "<user>@gsa.gov.peo" plus the sandbox name. DEV DOES
    NOT: it is @gsa.gov.peo1.peodv8dvn, with a "peo1" that no rule predicts.
    These users are created by hand, one org at a time, so the username is a
    CHOICE someone made and not something a pattern can be trusted to reproduce.
    Deriving them would have silently created a second user in Dev under the
    name the pattern predicts. Every username is therefore spelled out in the
    registry, and Dev's value was read back from the org on 2026-09-09.

    Targets Windows PowerShell 5.1: no ??, ?., ternary ?:, -AsHashtable,
    -Parallel or multi-argument Join-Path.
#>

param(
    # Which org. No default: a tool that can reach production should never act
    # on one because an argument was left off.
    [Parameter(Mandatory = $true)]
    [ValidateSet("Dev", "QA", "UAT", "Prod")]
    [string]$Environment,

    # Actually create things. Without it this reports the plan and stops.
    [switch]$Apply,

    # Proceed when LDGCRM_Partnership_Portal_API_R is not in the org yet, doing
    # the user and the licence and leaving the permission set for later.
    #
    # WHY THIS IS OPT-IN. The permission set arrives by change set, and until it
    # does an org can only be half set up. Half is still worth having - the
    # licence is scarce and the username may collide, so both are better found
    # out now than on change-set day - but a run that quietly stopped short would
    # report success over an integration that cannot authenticate. Asking for it
    # explicitly keeps "it worked" meaning the same thing every other run.
    [switch]$AllowMissingPermissionSet,

    # The typed approval token, for production only. Empty prompts for it.
    # See Assert-LdgcrmTypedConfirmation for why this is not a -Force switch.
    [string]$Confirmation = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\tools\data-loading\Common.ps1")
# For Invoke-SalesforceQuery, which already handles the --json envelope, the
# CLI's exit code, and the silent-truncation guard.
. (Join-Path $PSScriptRoot "..\tools\data-loading\Common.DataMigration.ps1")

# ============================================================================
# What the integration user looks like, everywhere
# ============================================================================
# Read back from the Dev user (005co000009KgbQAAS) on 2026-09-09, so a new org
# gets the same shape as the one that is known to work rather than a fresh guess.
$IntegrationUserAlias   = "ldgc_p3"
$IntegrationUserLast    = "ldgcrm_p3_integration"
$IntegrationUserEmail   = "dave.larrimore@gsa.gov"
$IntegrationProfileName = "Minimum Access - API Only Integrations"
$IntegrationTimeZone    = "America/New_York"
$IntegrationLocale      = "en_US"
$IntegrationEmailEnc    = "ISO-8859-1"
$IntegrationLanguage    = "en_US"

# The two things assigned to it, in this order.
$ApiLicenseDeveloperName = "SalesforceAPIIntegrationPsl"
$PermissionSetName       = "LDGCRM_Partnership_Portal_API_R"

$ProductionToken = "SET UP PRODUCTION INTEGRATION USER"

function Get-LdgcrmIntegrationUserTarget {
    <#
        This tool's OWN org registry. Deliberately separate from
        Get-LdgcrmEnvironmentTable in tools/data-loading/Common.Orgs.ps1, which
        is Dev/QA only and must stay that way - see the header.

        Alias        - the `sf` alias, which is the sandbox name lower-cased.
                       Production's alias is gsa-peo and it has no sandbox name.
        InstanceUrl  - proven against the org at run time, so a repointed alias
                       stops the run rather than acting on the wrong org.
        Username     - LISTED, not derived. See the header for why.
        IsProduction - drives the typed confirmation and the IsSandbox check.

        The Full sandbox (peofl2stgp) is absent because Sprint 2's approval named
        Dev, QA, UAT and Prod. Add it here if that changes; do not reach for an
        -OrgAlias override, which would bypass the URL check that makes this safe.
    #>

    return [ordered]@{
        Dev = [PSCustomObject]@{
            Key          = "Dev"
            Alias        = "peodv8dvn"
            SandboxName  = "PEOdV8DVn"
            InstanceUrl  = "https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com"
            Username     = "ldgcrm_p3_integration@gsa.gov.peo1.peodv8dvn"
            Label        = "Dev sandbox"
            IsProduction = $false
        }
        QA = [PSCustomObject]@{
            Key          = "QA"
            Alias        = "peodv15dvn"
            SandboxName  = "PEOdV15DVn"
            InstanceUrl  = "https://gsa-peo--peodv15dvn.sandbox.my.salesforce.com"
            Username     = "ldgcrm_p3_integration@gsa.gov.peo.peodv15dvn"
            Label        = "QA sandbox"
            IsProduction = $false
        }
        UAT = [PSCustomObject]@{
            Key          = "UAT"
            Alias        = "peofl1uatp"
            SandboxName  = "PEOfL1UATp"
            InstanceUrl  = "https://gsa-peo--peofl1uatp.sandbox.my.salesforce.com"
            Username     = "ldgcrm_p3_integration@gsa.gov.peo.peofl1uatp"
            Label        = "UAT sandbox"
            IsProduction = $false
        }
        Prod = [PSCustomObject]@{
            Key          = "Prod"
            Alias        = "gsa-peo"
            SandboxName  = ""
            InstanceUrl  = "https://gsa-peo.my.salesforce.com"
            Username     = "ldgcrm_p3_integration@gsa.gov.peo"
            Label        = "PRODUCTION"
            IsProduction = $true
        }
    }
}

function Assert-LdgcrmUserSetupTarget {
    <#
        Proves the alias points at the org the registry says it does, BEFORE
        anything is written.

        Reads Organization.IsSandbox FROM THE ORG. `sf org list` would answer
        from a local cache, which is the very thing being verified - a stale
        cache entry is exactly how a command aimed at a sandbox reaches
        production.

        Throws on any mismatch. Returns the org's own description of itself.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    $RawResult = & sf org display --target-org $Target.Alias --json

    if ($LASTEXITCODE -ne 0) {
        throw ("Cannot reach org alias '" + $Target.Alias + "' for " + $Target.Key + ". " +
               "Authorize it first:" + [Environment]::NewLine +
               "  sf org login web --alias " + $Target.Alias + " --instance-url " + $Target.InstanceUrl)
    }

    $Display = $RawResult | ConvertFrom-Json

    if ($Display.status -ne 0) {
        throw ("sf org display failed for '" + $Target.Alias + "': " + $Display.message)
    }

    $ActualUrl = "$($Display.result.instanceUrl)".TrimEnd("/").ToLowerInvariant()
    $ExpectedUrl = $Target.InstanceUrl.TrimEnd("/").ToLowerInvariant()

    if ($ActualUrl -ne $ExpectedUrl) {
        throw ("Alias '" + $Target.Alias + "' points at " + $ActualUrl + ", but " + $Target.Key +
               " is " + $ExpectedUrl + ". Refusing to continue against an org this script cannot identify.")
    }

    $OrgRows = @(Invoke-SalesforceQuery -OrgAlias $Target.Alias `
        -Soql "SELECT Id, Name, IsSandbox, OrganizationType FROM Organization")

    if ($OrgRows.Count -ne 1) {
        throw ("Expected exactly one Organization row from " + $Target.Alias + ", got " + $OrgRows.Count + ".")
    }

    $Org = $OrgRows[0]
    $IsSandbox = [bool]$Org.IsSandbox

    if ($Target.IsProduction -and $IsSandbox) {
        throw ("Environment is Prod but org " + $Target.Alias + " reports IsSandbox = true. " +
               "Refusing to continue: either the alias is wrong or the registry is.")
    }

    if (-not $Target.IsProduction -and -not $IsSandbox) {
        throw ("Environment is " + $Target.Key + " but org " + $Target.Alias + " reports IsSandbox = false. " +
               "That is a PRODUCTION org. Refusing to continue.")
    }

    return $Org
}

function Get-SingleRecord {
    <#
        One row, or $null. Throws when a lookup that must be unique is not,
        because "which of these two is it?" has no safe default here.

        CONTRACT: returns a single object or $null; do NOT wrap the call in @().
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Soql,

        [Parameter(Mandatory = $true)]
        [string]$OrgAlias,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $Rows = @(Invoke-SalesforceQuery -Soql $Soql -OrgAlias $OrgAlias)

    if ($Rows.Count -eq 0) { return $null }

    if ($Rows.Count -gt 1) {
        throw ("Expected at most one " + $Description + " but found " + $Rows.Count + ". SOQL: " + $Soql)
    }

    return $Rows[0]
}

function New-SalesforceRecord {
    <#
        Creates one record through `sf data create record` and returns its Id.

        NEVER redirects the CLI's stderr. PS 5.1 wraps each stderr line in an
        ErrorRecord, so the CLI's harmless "update available" banner would kill
        the script and blame the line that ran the command.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SObject,

        [Parameter(Mandatory = $true)]
        [hashtable]$Values,

        [Parameter(Mandatory = $true)]
        [string]$OrgAlias
    )

    $Pairs = @()

    foreach ($Key in $Values.Keys) {
        $Pairs += ($Key + "=" + [string]$Values[$Key])
    }

    $ValueString = $Pairs -join " "

    $RawResult = & sf data create record `
        --sobject $SObject `
        --values $ValueString `
        --target-org $OrgAlias `
        --json

    $Parsed = $null

    try {
        $Parsed = $RawResult | ConvertFrom-Json
    }
    catch {
        $Parsed = $null
    }

    if ($LASTEXITCODE -ne 0 -or $null -eq $Parsed -or $Parsed.status -ne 0) {
        $Message = "Unknown Salesforce CLI error."

        if ($null -ne $Parsed -and -not [string]::IsNullOrWhiteSpace($Parsed.message)) {
            $Message = $Parsed.message
        }

        throw ("Creating the " + $SObject + " record failed: " + $Message)
    }

    return $Parsed.result.id
}

$null = Start-ScriptLog -Category "sprint2" -ScriptName "Set-LdgcrmIntegrationUser"

try {
    $Registry = Get-LdgcrmIntegrationUserTarget
    $Target = $Registry[$Environment]

    Write-Host "============================================================"
    Write-Host (" P3 INTEGRATION USER SETUP - " + $Target.Label)
    Write-Host "============================================================"
    Write-Host ("  Environment : " + $Target.Key)
    Write-Host ("  Org alias   : " + $Target.Alias)
    Write-Host ("  Instance    : " + $Target.InstanceUrl)
    Write-Host ("  Username    : " + $Target.Username)

    if ($Apply) {
        Write-Host "  Mode        : APPLY - this run will create records."
    }
    else {
        Write-Host "  Mode        : REPORT ONLY - nothing will be created. Add -Apply to act."
    }

    Write-Host ""

    # ---------------------------------------------------------------------
    # 1. Prove the target
    # ---------------------------------------------------------------------
    Write-Host "Verifying the target org..."
    $Org = Assert-LdgcrmUserSetupTarget -Target $Target
    Write-Host ("  " + $Org.Name + "  (IsSandbox = " + $Org.IsSandbox + ", " + $Org.OrganizationType + ")")
    Write-Host ""

    # ---------------------------------------------------------------------
    # 2. Preflight - everything this needs must already exist
    # ---------------------------------------------------------------------
    Write-Host "Preflight..."

    $ProfileRecord = Get-SingleRecord -OrgAlias $Target.Alias -Description "profile named '$IntegrationProfileName'" `
        -Soql ("SELECT Id, Name FROM Profile WHERE Name = '" + $IntegrationProfileName + "'")

    if ($null -eq $ProfileRecord) {
        throw ("The profile '" + $IntegrationProfileName + "' does not exist in " + $Target.Key + ". " +
               "It is a stock profile that ships with the Salesforce API Integration licence, so its " +
               "absence usually means the org has no such licence rather than that someone deleted it.")
    }

    Write-Host ("  Profile              : " + $ProfileRecord.Name)

    $License = Get-SingleRecord -OrgAlias $Target.Alias -Description "permission set licence '$ApiLicenseDeveloperName'" `
        -Soql ("SELECT Id, MasterLabel, TotalLicenses, UsedLicenses, Status FROM PermissionSetLicense " +
               "WHERE DeveloperName = '" + $ApiLicenseDeveloperName + "'")

    if ($null -eq $License) {
        throw ("The 'Salesforce API Integration' permission set licence is not present in " + $Target.Key + ". " +
               "Nothing here can create it - it is a purchased licence. Raise it with whoever owns the org's " +
               "licensing before continuing.")
    }

    $SeatsFree = [int]$License.TotalLicenses - [int]$License.UsedLicenses
    Write-Host ("  Licence              : " + $License.MasterLabel + "  (" + $License.UsedLicenses +
                " of " + $License.TotalLicenses + " used, " + $SeatsFree + " free)")

    $PermissionSet = Get-SingleRecord -OrgAlias $Target.Alias -Description "permission set '$PermissionSetName'" `
        -Soql ("SELECT Id, Name, Label FROM PermissionSet WHERE Name = '" + $PermissionSetName + "'")

    if ($null -eq $PermissionSet) {
        # This is the expected state in an org the Sprint 2 change set has not
        # reached yet, and it is NOT something this script may fix: metadata
        # moves by change set only. Say so precisely.
        $Explanation = ("The permission set '" + $PermissionSetName + "' does not exist in " + $Target.Key + "." +
               [Environment]::NewLine +
               "It has to arrive by CHANGE SET - nothing here may deploy metadata. That change set must" + [Environment]::NewLine +
               "also carry LDGCRM_Issuer_String__c, because the permission set grants read on that object" + [Environment]::NewLine +
               "and production does not have it. See scripts/docs/integration-user.md section 6.")

        if (-not $AllowMissingPermissionSet) {
            throw ($Explanation + [Environment]::NewLine +
                   [Environment]::NewLine +
                   "To do the user and the licence now and the permission set after the change set lands," + [Environment]::NewLine +
                   "re-run with -AllowMissingPermissionSet.")
        }

        Write-Warning $Explanation
        Write-Host "  Permission set       : ABSENT - continuing without it (-AllowMissingPermissionSet)"
    }
    else {
        Write-Host ("  Permission set       : " + $PermissionSet.Label)
    }

    # ---------------------------------------------------------------------
    # 3. What already exists
    # ---------------------------------------------------------------------
    $User = Get-SingleRecord -OrgAlias $Target.Alias -Description "user '$($Target.Username)'" `
        -Soql ("SELECT Id, Username, IsActive, UserType, ProfileId, Profile.Name FROM User " +
               "WHERE Username = '" + $Target.Username + "'")

    $HasLicense = $false
    $HasPermissionSet = $false

    if ($null -ne $User) {
        $LicenseAssign = Get-SingleRecord -OrgAlias $Target.Alias -Description "licence assignment" `
            -Soql ("SELECT Id FROM PermissionSetLicenseAssign WHERE AssigneeId = '" + $User.Id +
                   "' AND PermissionSetLicenseId = '" + $License.Id + "'")

        $HasLicense = [bool]($null -ne $LicenseAssign)

        if ($null -ne $PermissionSet) {
            $PermissionSetAssign = Get-SingleRecord -OrgAlias $Target.Alias -Description "permission set assignment" `
                -Soql ("SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = '" + $User.Id +
                       "' AND PermissionSetId = '" + $PermissionSet.Id + "'")

            $HasPermissionSet = [bool]($null -ne $PermissionSetAssign)
        }
    }

    Write-Host ""
    Write-Host "Current state"
    Write-Host "-------------"

    if ($null -eq $User) {
        Write-Host "  User                 : ABSENT"
    }
    else {
        Write-Host ("  User                 : " + $User.Id + "  (active = " + $User.IsActive +
                    ", type = " + $User.UserType + ", profile = " + $User.Profile.Name + ")")

        if (-not $User.IsActive) {
            Write-Warning ("The user exists but is INACTIVE. This script will not reactivate it - " +
                           "an inactive integration user is usually inactive on purpose. Reactivate it " +
                           "by hand if that is wrong, then re-run.")
        }

        if ($User.Profile.Name -ne $IntegrationProfileName) {
            Write-Warning ("The user's profile is '" + $User.Profile.Name + "', not '" + $IntegrationProfileName +
                           "'. This script will not change it. A broader profile silently widens what the " +
                           "integration can reach, so the permission set stops being a complete statement of that.")
        }
    }

    if ($HasLicense) { Write-Host "  Licence assignment   : present" } else { Write-Host "  Licence assignment   : ABSENT" }

    if ($null -eq $PermissionSet) {
        Write-Host "  Perm set assignment  : n/a - the permission set is not in this org"
    }
    elseif ($HasPermissionSet) {
        Write-Host "  Perm set assignment  : present"
    }
    else {
        Write-Host "  Perm set assignment  : ABSENT"
    }

    # ---------------------------------------------------------------------
    # 4. The plan
    # ---------------------------------------------------------------------
    $Plan = [System.Collections.Generic.List[object]]::new()

    if ($null -eq $User) {
        $Plan.Add("Create User " + $Target.Username + " on profile '" + $IntegrationProfileName + "'")
    }

    if (-not $HasLicense) {
        $Plan.Add("Assign permission set LICENCE '" + $License.MasterLabel + "'")
    }

    if ($null -ne $PermissionSet -and -not $HasPermissionSet) {
        $Plan.Add("Assign permission set '" + $PermissionSet.Label + "'")
    }

    Write-Host ""
    Write-Host "Plan"
    Write-Host "----"

    if ($Plan.Count -eq 0) {
        if ($null -eq $PermissionSet) {
            # Everything this run CAN do is done, which is not the same as the
            # environment being finished. Saying "already set up" here would be
            # the exact false green -AllowMissingPermissionSet exists to avoid.
            Write-Host "  Nothing left that can be done without the permission set."
            Write-Host ""
            Write-Warning ("INCOMPLETE: " + $Target.Key + " has the user and the licence, but " +
                           $PermissionSetName + " is still not in the org, so the integration cannot " +
                           "read anything yet. Re-run without -AllowMissingPermissionSet once the " +
                           "change set has landed.")
        }
        else {
            Write-Host "  Nothing to do. This environment is already set up."
        }

        Write-Host ""
        return
    }

    $Step = 0

    foreach ($Item in $Plan) {
        $Step = $Step + 1
        Write-Host ("  " + $Step + ". " + $Item)
    }

    # A seat is only needed if the licence is not already assigned.
    if (-not $HasLicense -and $SeatsFree -lt 1) {
        throw ("No free 'Salesforce API Integration' seats in " + $Target.Key + " (" + $License.UsedLicenses +
               " of " + $License.TotalLicenses + " used). The assignment would fail on capacity, which reads " +
               "nothing like a licensing problem. Free a seat first.")
    }

    if (-not $Apply) {
        Write-Host ""
        Write-Host "REPORT ONLY - nothing was created. Re-run with -Apply to do the above."
        Write-Host ""
        return
    }

    # ---------------------------------------------------------------------
    # 5. Production gate
    # ---------------------------------------------------------------------
    if ($Target.IsProduction) {
        $Approved = Assert-LdgcrmTypedConfirmation `
            -Token $ProductionToken `
            -Provided $Confirmation `
            -Action ("Create and configure the P3 integration user in PRODUCTION (" + $Target.Alias + ")")

        if (-not $Approved) {
            Write-Host ""
            Write-Host "Declined. Nothing was created."
            Write-Host ""
            return
        }
    }

    # ---------------------------------------------------------------------
    # 6. Act, in order
    # ---------------------------------------------------------------------
    Write-Host ""
    Write-Host "Applying..."

    if ($null -eq $User) {
        # A username must be unique across ALL of Salesforce, not just this org,
        # so a collision here is entirely possible and says nothing about this
        # org's state. It is also why Dev's username carries a "peo1".
        $NewUserId = New-SalesforceRecord -SObject "User" -OrgAlias $Target.Alias -Values @{
            Username          = $Target.Username
            Alias             = $IntegrationUserAlias
            LastName          = $IntegrationUserLast
            Email             = $IntegrationUserEmail
            ProfileId         = $ProfileRecord.Id
            TimeZoneSidKey    = $IntegrationTimeZone
            LocaleSidKey      = $IntegrationLocale
            EmailEncodingKey  = $IntegrationEmailEnc
            LanguageLocaleKey = $IntegrationLanguage
        }

        Write-Host ("  Created User " + $NewUserId)

        $User = Get-SingleRecord -OrgAlias $Target.Alias -Description "the user just created" `
            -Soql ("SELECT Id, Username, IsActive, UserType FROM User WHERE Id = '" + $NewUserId + "'")

        if ($null -eq $User) {
            throw ("Created User " + $NewUserId + " but it could not be read back. Stopping before assigning " +
                   "anything to a record whose existence is not confirmed.")
        }
    }

    # THE LICENCE GOES ON FIRST. ApiUserOnly, which the permission set grants, is
    # only grantable to a user who already holds this licence. The other order
    # fails on the permission set and makes the permission set look broken.
    if (-not $HasLicense) {
        $null = New-SalesforceRecord -SObject "PermissionSetLicenseAssign" -OrgAlias $Target.Alias -Values @{
            AssigneeId             = $User.Id
            PermissionSetLicenseId = $License.Id
        }

        Write-Host ("  Assigned licence " + $License.MasterLabel)
    }

    if ($null -ne $PermissionSet -and -not $HasPermissionSet) {
        $null = New-SalesforceRecord -SObject "PermissionSetAssignment" -OrgAlias $Target.Alias -Values @{
            AssigneeId      = $User.Id
            PermissionSetId = $PermissionSet.Id
        }

        Write-Host ("  Assigned permission set " + $PermissionSet.Label)
    }

    # ---------------------------------------------------------------------
    # 7. Verify by RE-QUERY, never by the write's own success report
    # ---------------------------------------------------------------------
    Write-Host ""
    Write-Host "Verifying..."

    $FinalUser = Get-SingleRecord -OrgAlias $Target.Alias -Description "user '$($Target.Username)'" `
        -Soql ("SELECT Id, Username, IsActive, UserType, Profile.Name FROM User " +
               "WHERE Username = '" + $Target.Username + "'")

    $FinalLicense = Get-SingleRecord -OrgAlias $Target.Alias -Description "licence assignment" `
        -Soql ("SELECT Id FROM PermissionSetLicenseAssign WHERE AssigneeId = '" + $FinalUser.Id +
               "' AND PermissionSetLicenseId = '" + $License.Id + "'")

    # PermissionSet.IsOwnedByProfile = false filters out the profile-owned row
    # every user carries. Without it this query returns a row for a user that has
    # nothing assigned, and reads as success.
    $FinalPermissionSets = @(Invoke-SalesforceQuery -OrgAlias $Target.Alias `
        -Soql ("SELECT PermissionSet.Name, PermissionSet.Label FROM PermissionSetAssignment " +
               "WHERE AssigneeId = '" + $FinalUser.Id + "' AND PermissionSet.IsOwnedByProfile = false"))

    $Failures = @()

    if ($null -eq $FinalUser) { $Failures += "the user could not be read back" }
    elseif (-not $FinalUser.IsActive) { $Failures += "the user is not active" }

    if ($null -eq $FinalLicense) { $Failures += "the permission set licence is not assigned" }

    $PermissionSetNames = @($FinalPermissionSets | ForEach-Object { $_.PermissionSet.Name })

    # Only a FAILURE when the permission set exists to be assigned. When it does
    # not, its absence is the known, opted-into state, and the run is reported as
    # incomplete rather than as broken.
    if ($null -ne $PermissionSet -and $PermissionSetNames -notcontains $PermissionSetName) {
        $Failures += ("the permission set " + $PermissionSetName + " is not assigned")
    }

    Write-Host ("  User                 : " + $FinalUser.Id + "  (" + $FinalUser.Username + ")")
    Write-Host ("  Active / type        : " + $FinalUser.IsActive + " / " + $FinalUser.UserType)
    Write-Host ("  Profile              : " + $FinalUser.Profile.Name)
    Write-Host ("  Licence assigned     : " + [bool]($null -ne $FinalLicense))
    Write-Host ("  Permission sets      : " + (($PermissionSetNames | Sort-Object) -join ", "))

    if ($Failures.Count -gt 0) {
        throw ("Applied, but verification failed: " + ($Failures -join "; ") + ". " +
               "Do not treat this run as successful - the writes reported success and the re-query disagrees.")
    }

    $Summary = @()
    $Summary += ("P3 integration user setup - " + $Target.Label)
    $Summary += ("Run at        : " + (Get-Date).ToString("u"))
    $Summary += ("Org alias     : " + $Target.Alias)
    $Summary += ("Instance      : " + $Target.InstanceUrl)
    $Summary += ("Username      : " + $FinalUser.Username)
    $Summary += ("User Id       : " + $FinalUser.Id)
    $Summary += ("Profile       : " + $FinalUser.Profile.Name)
    $Summary += ("Licence       : " + $License.MasterLabel)
    $Summary += ("Permission set: " + ($PermissionSetNames -join ", "))
    $Summary += ""
    $Summary += "Steps taken this run:"

    foreach ($Item in $Plan) { $Summary += ("  - " + $Item) }

    if ($null -eq $PermissionSet) {
        Write-Host ""
        Write-Warning ("INCOMPLETE: the user and the licence are in place, but " + $PermissionSetName +
                       " is not in this org, so the integration cannot read anything yet. Re-run without " +
                       "-AllowMissingPermissionSet once the change set has landed.")

        $Summary += ""
        $Summary += ("INCOMPLETE - " + $PermissionSetName + " was not in the org, so it was not assigned.")
        $Summary += "The integration cannot read anything until a change set brings it and this is re-run."
    }

    $Summary += ""
    $Summary += "None of this survives a sandbox refresh. See scripts/docs/integration-user.md."

    $SummaryPath = Join-Path (Get-LogDirectory -Category "sprint2") "SUMMARY.txt"
    $Utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($SummaryPath, $Summary, $Utf8NoBom)

    Write-Host ""
    Write-Host ("Done. Summary: " + $SummaryPath)
    Write-Host ""
}
catch {
    # Write the diagnosis before the transcript closes, or the run's log ends on
    # whatever line threw and the explanation goes to a console nobody kept.
    Write-Host ""
    Write-Host $_.Exception.Message

    throw
}
finally {
    Stop-ScriptLog
}
