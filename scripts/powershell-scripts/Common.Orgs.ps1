# Salesforce environment registry for the Login.gov CRM migration.
#
# Dot-sourced automatically by powershell-scripts/Common.ps1, so every script in
# this repo gets these helpers without adding a line of its own.
#
# Targets Windows PowerShell 5.1 (no ??, ?., ternary ?:, -AsHashtable,
# -Parallel, or multi-argument Join-Path).
#
# =============================================================================
# WHY THIS FILE EXISTS
# =============================================================================
# There are four environments, and a hard-coded org alias cannot survive that.
# The scheme: AN ALIAS IS THE ORG'S OWN SANDBOX NAME, so an alias cannot drift
# from the org it names. Scripts never take a bare alias from a human; they
# take -Environment Dev|QA|Full|Prod and resolve it here.
#
# When production genuinely needs authorizing, see the auth runbook in
# docs/SETUP.md ("Authorizing an org").
# =============================================================================

function Get-LdgcrmEnvironmentTable {
    <#
        The single source of truth for which org each environment is.

        Alias           - the `sf` alias. Empty means "not authorized/known
                          yet"; Get-LdgcrmEnvironment throws a runbook pointer
                          rather than letting a script fall through to a
                          default org.
        SandboxName     - the Salesforce sandbox name. Used by
                          Assert-LdgcrmOrgTarget to prove the alias still
                          points where this table says it does, by matching the
                          org's instance URL. Empty for production, which has
                          no sandbox name (it is identified by IsSandbox=false).
        InstanceUrl     - the org's my.salesforce.com URL.
        LightningUrl    - the URL a human would open in a browser. Neither is
                          used to CONNECT (the alias does that); both exist so
                          an operator can confirm by eye that the org the
                          banner names is the org they think it is, and so
                          Assert-LdgcrmOrgTarget can verify production the same
                          way it verifies a sandbox (see below).
        IsProduction    - gates the extra typed confirmation in write/delete
                          scripts. Only ever true for Prod.
        AllowsAccountRebuild
                        - whether the Account tree may be DELETED AND REBUILT
                          from the production export in this org. See
                          Test-LdgcrmAccountRebuildAllowed for the rule.
    #>

    return [ordered]@{
        Dev = [PSCustomObject]@{
            Key                  = "Dev"
            Alias                = "peodv8dvn"
            SandboxName          = "PEOdV8DVn"
            InstanceUrl          = "https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com"
            LightningUrl         = "https://gsa-peo--peodv8dvn.sandbox.lightning.force.com"
            Label                = "Dev sandbox"
            Purpose              = "Day-to-day development and pipeline testing. Default for every script."
            IsProduction         = $false
            AllowsAccountRebuild = $true
        }
        QA = [PSCustomObject]@{
            Key                  = "QA"
            Alias                = "peodv15dvn"
            SandboxName          = "PEOdV15DVn"
            InstanceUrl          = "https://gsa-peo--peodv15dvn.sandbox.my.salesforce.com"
            LightningUrl         = "https://gsa-peo--peodv15dvn.sandbox.lightning.force.com"
            Label                = "QA sandbox"
            Purpose              = "Full end-to-end migration rehearsal before the Operations hand-off."
            IsProduction         = $false
            AllowsAccountRebuild = $true
        }
        Full = [PSCustomObject]@{
            # NAMED 2026-08-14: PEOfL2STGp. The Full sandbox the Operations team
            # use to run these scripts and the change sets themselves, as the
            # final dress rehearsal before production.
            #
            # The alias is the sandbox name lower-cased, per the scheme at the
            # top of this file. It may not be AUTHORIZED on your machine yet -
            # if not, Assert-LdgcrmOrgTarget fails with "could not reach org
            # alias", which is the correct outcome: the registry says which org
            # Full IS, not whether you can currently reach it. Authorize with
            #   sf org login web --alias peofl2stgp \
            #     --instance-url https://gsa-peo--peofl2stgp.sandbox.my.salesforce.com
            Key                  = "Full"
            Alias                = "peofl2stgp"
            SandboxName          = "PEOfL2STGp"
            InstanceUrl          = "https://gsa-peo--peofl2stgp.sandbox.my.salesforce.com"
            LightningUrl         = "https://gsa-peo--peofl2stgp.sandbox.lightning.force.com"
            Label                = "Full sandbox (Operations integration testing)"
            Purpose              = "Operations team dress rehearsal: scripts + change sets, immediately before production."
            IsProduction         = $false
            # FALSE, and this is the whole point of a Full sandbox: it is a COPY
            # OF PRODUCTION, so its Accounts are the real ones. See
            # Test-LdgcrmAccountRebuildAllowed.
            AllowsAccountRebuild = $false
        }
        Prod = [PSCustomObject]@{
            # Deliberately not authorized on this machine. See the auth runbook
            # in docs/SETUP.md before creating this alias.
            Key                  = "Prod"
            Alias                = "gsa-peo"
            SandboxName          = ""
            InstanceUrl          = "https://gsa-peo.my.salesforce.com"
            LightningUrl         = "https://gsa-peo.lightning.force.com"
            Label                = "PRODUCTION"
            Purpose              = "The live GSA PEO org. Real Login.gov partner data."
            IsProduction         = $true
            AllowsAccountRebuild = $false
        }
    }
}

function Test-LdgcrmAccountRebuildAllowed {
    <#
        May the Account tree be deleted and rebuilt from the production export
        in this environment?

        DEV AND QA: YES. Both are developer sandboxes that contain no real
        Account data of their own, so the migration has nothing to attach to
        until Invoke-AccountBootstrap.ps1 builds an Account universe from the
        production export. Rebuilding is the only way a rehearsal there is
        meaningful.

        FULL AND PROD: NO, AND THE REASON IS THE SAME FOR BOTH. A Full sandbox
        is a copy of production, so its Accounts ARE the production Accounts -
        the exact records the migration is supposed to reconcile ONTO. Deleting
        them would destroy the thing being tested and then replace it with a
        stale export, which is worse than useless: the rehearsal would pass
        against data that no longer resembles what production holds. In
        production it is straightforwardly destructive.

        This is the rule, in one place, for all three scripts that need it:
        Invoke-SandboxFactoryReset.ps1 (drops Account from its delete list),
        Invoke-AccountBootstrap.ps1 (refuses to run at all), and
        Invoke-FullMigrationLoad.ps1 (refuses -BootstrapAccounts). Duplicating
        it as three separate "if ($Environment -eq ...)" checks is how one of
        them ends up disagreeing with the others.

        Note the migration's OTHER objects are still reset in a Full sandbox -
        only Account is protected. Everything else carries
        LDGCRM_External_ID__c and was created by this migration, so deleting it
        removes only what a previous rehearsal put there.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA", "Full", "Prod")]
        [string]$Environment
    )

    return [bool](Get-LdgcrmEnvironmentTable)[$Environment].AllowsAccountRebuild
}

function Select-LdgcrmResettableObjects {
    <#
        Filters a factory-reset object list down to what may actually be deleted
        in this environment: everything, minus Account where Accounts are real.

        A FUNCTION RATHER THAN THREE LINES INLINE, for one reason: the Full
        sandbox does not exist yet, so the code path that protects it cannot be
        exercised end to end - Resolve-LdgcrmOrgAlias throws on the missing alias
        long before the filter would matter. Pulling it out means the rule can be
        tested directly today (see tools/Test-BundleStructure.ps1) instead of
        being first exercised, unobserved, against a copy of production.

        Returns the filtered list. The CALLER announces the exclusion - and must
        do so after its transcript is open, because a message this consequential
        belongs in the audit trail rather than on a console nobody rereads.

        Throws when the filter would leave nothing to do, rather than running a
        reset that deletes nothing and reports success.

        CALLER CONTRACT: wrap the result in @(). Returned bare (no leading
        comma) precisely so that works - PowerShell unrolls the array on output
        and @() re-collects it, which also normalises the 0- and 1-element cases
        the caller would otherwise get as $null and a bare string. Do NOT "fix"
        this by adding a comma: `return ,$Kept` plus a caller's @() yields a
        one-element array CONTAINING the array, and the count silently becomes 1.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA", "Full", "Prod")]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Objects
    )

    if (Test-LdgcrmAccountRebuildAllowed -Environment $Environment) {
        return $Objects
    }

    $Kept = @($Objects | Where-Object { $_ -ne "Account" })

    if ($Kept.Count -eq 0) {
        throw ("Nothing left to reset: Account is the only object requested, and it is protected in " +
               "environment '$Environment'. Nothing was run.")
    }

    return $Kept
}

function Get-LdgcrmEnvironment {
    <#
        Resolves an environment key to its registry entry, throwing a usable
        error (not $null) when the environment exists but hasn't been wired up
        yet - which is the state the Full sandbox is in today.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA", "Full", "Prod")]
        [string]$Environment
    )

    $Table = Get-LdgcrmEnvironmentTable
    $Entry = $Table[$Environment]

    if (-not $Entry.Alias) {
        throw ("Environment '$Environment' ($($Entry.Label)) has no org alias configured yet. " +
               "Authorize the org (docs/SETUP.md, 'Authorizing an org'), then fill in Alias, " +
               "SandboxName, InstanceUrl and LightningUrl for '$Environment' in powershell-scripts/Common.Orgs.ps1.")
    }

    return $Entry
}

function Resolve-LdgcrmOrgAlias {
    <#
        The one line every script uses to turn its -Environment parameter into
        an alias, while still honouring an explicit -OrgAlias override for the
        rare one-off (e.g. a scratch org, or a colleague's differently-aliased
        connection).

            $OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA", "Full", "Prod")]
        [string]$Environment,

        [string]$OrgAlias = ""
    )

    if ($OrgAlias) {
        return $OrgAlias
    }

    return (Get-LdgcrmEnvironment -Environment $Environment).Alias
}

function Assert-LdgcrmOrgTarget {
    <#
        Proves the alias still points at the org the registry claims, BEFORE
        anything is read or written, and returns the `sf org display` result.

        WHY THIS IS NOT PARANOIA: an `sf` alias is a local, mutable pointer.
        Re-running `sf org login web --alias peodv15dvn` against the wrong org,
        or a colleague's copied config, silently repoints it - and every safety
        gate downstream ("type HARD DELETE to continue") would then be
        confirming the wrong org in perfect good faith. The whole reason this
        repo switched to sandbox-name aliases is so that a mismatch is
        *detectable*; this function is what actually detects it.

        Checks, in order:
          1. The alias resolves and the org is reachable.
          2. Sandbox vs production matches the registry (a sandbox alias must
             not resolve to a production org, and vice versa).
          3. For sandboxes, the instance URL contains the expected sandbox
             name - e.g. "peodv8dvn" must appear in
             https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com.

        -Quiet suppresses the banner for read-only callers that print their own.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA", "Full", "Prod")]
        [string]$Environment,

        [string]$OrgAlias = "",

        [switch]$Quiet
    )

    $Entry = Get-LdgcrmEnvironment -Environment $Environment
    $Alias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias
    $IsOverride = [bool]$OrgAlias -and ($OrgAlias -ne $Entry.Alias)

    $RawResult = & sf org display --target-org $Alias --json

    if ($LASTEXITCODE -ne 0) {
        throw ("Could not reach org alias '$Alias' for environment '$Environment' ($($Entry.Label)). " +
               "Authorize it first - see docs/SETUP.md, 'Authorizing an org'.")
    }

    $Json = $RawResult | ConvertFrom-Json

    if ($Json.status -ne 0) {
        $Message = $Json.message
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "Unknown Salesforce CLI error." }
        throw "sf org display failed for '$Alias': $Message"
    }

    $Org = $Json.result

    # `sf org display` does NOT return isSandbox - only `sf org list` does, and
    # that reads a local cache rather than the org itself, which is exactly the
    # thing being verified here. So ask the org: Organization.IsSandbox is
    # authoritative and immune to a stale/repointed local alias entry.
    $OrgRecordRaw = & sf data query --target-org $Alias --query "SELECT IsSandbox, Name, OrganizationType FROM Organization" --json

    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the Organization record from '$Alias' to verify sandbox vs production. Nothing was run."
    }

    $OrgRecordJson = $OrgRecordRaw | ConvertFrom-Json

    if ($OrgRecordJson.status -ne 0 -or $OrgRecordJson.result.totalSize -ne 1) {
        throw "Unexpected Organization query result from '$Alias' while verifying the target org. Nothing was run."
    }

    $OrgRecord = @($OrgRecordJson.result.records)[0]

    # Attached for the banner and for callers that want to report on the org.
    Add-Member -InputObject $Org -NotePropertyName "isSandbox"        -NotePropertyValue ([bool]$OrgRecord.IsSandbox) -Force
    Add-Member -InputObject $Org -NotePropertyName "orgName"          -NotePropertyValue $OrgRecord.Name -Force
    Add-Member -InputObject $Org -NotePropertyName "organizationType" -NotePropertyValue $OrgRecord.OrganizationType -Force

    # An explicit -OrgAlias override means the caller deliberately stepped
    # outside the registry, so the registry's identity checks don't apply -
    # but say so loudly rather than validating against the wrong expectations.
    if ($IsOverride) {
        Write-Host ""
        Write-Host "NOTE: -OrgAlias '$Alias' overrides environment '$Environment' ($($Entry.Alias))." -ForegroundColor Yellow
        Write-Host "      Registry identity checks are skipped for an explicit override." -ForegroundColor Yellow
    }
    else {
        $IsSandbox = [bool]$Org.isSandbox

        if ($Entry.IsProduction -and $IsSandbox) {
            throw ("SAFETY STOP: environment '$Environment' is registered as PRODUCTION but alias '$Alias' " +
                   "resolves to a SANDBOX ($($Org.instanceUrl)). Fix the alias or the registry before continuing.")
        }

        if (-not $Entry.IsProduction -and -not $IsSandbox) {
            throw ("SAFETY STOP: environment '$Environment' ($($Entry.Label)) is registered as a sandbox but alias " +
                   "'$Alias' resolves to a PRODUCTION org ($($Org.instanceUrl)). Nothing was run. " +
                   "This is exactly the mix-up the sandbox-name alias scheme exists to catch.")
        }

        if ($Entry.SandboxName) {
            $Expected = $Entry.SandboxName.ToLowerInvariant()
            $InstanceUrl = "$($Org.instanceUrl)".ToLowerInvariant()

            if ($InstanceUrl -notlike "*$Expected*") {
                throw ("SAFETY STOP: alias '$Alias' should point at sandbox '$($Entry.SandboxName)' but its " +
                       "instance URL is $($Org.instanceUrl). The alias has been repointed at a different org. " +
                       "Nothing was run.")
            }
        }
        elseif ($Entry.InstanceUrl) {
            # PRODUCTION HAS NO SANDBOX NAME, so the check above cannot apply to
            # it - which until 2026-08-14 left production as the ONE environment
            # whose identity was never verified beyond "is not a sandbox". Now
            # that the registry records its URL, hold it to the same standard:
            # compare hosts, so an org on a different pod (or a My Domain that
            # is not gsa-peo at all) stops the run.
            $ExpectedHost = ([Uri]$Entry.InstanceUrl).Host.ToLowerInvariant()
            $ActualHost   = ([Uri]"$($Org.instanceUrl)").Host.ToLowerInvariant()

            # Salesforce serves the same org from several host forms
            # (gsa-peo.my.salesforce.com, gsa-peo.lightning.force.com,
            # gsa-peo.file.force.com). The stable part is the My Domain label -
            # the first segment - so match on that rather than the whole host.
            $ExpectedDomain = ($ExpectedHost -split '\.')[0]
            $ActualDomain   = ($ActualHost -split '\.')[0]

            if ($ExpectedDomain -ne $ActualDomain) {
                throw ("SAFETY STOP: environment '$Environment' ($($Entry.Label)) expects the My Domain " +
                       "'$ExpectedDomain' ($($Entry.InstanceUrl)) but alias '$Alias' resolves to " +
                       "$($Org.instanceUrl). Nothing was run.")
            }
        }
    }

    if (-not $Quiet) {
        Write-LdgcrmOrgBanner -Environment $Environment -OrgAlias $Alias -OrgInfo $Org
    }

    return $Org
}

function Write-LdgcrmOrgBanner {
    <#
        Prints who we're about to talk to, in the operator's face, before any
        confirmation prompt. Production gets red.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA", "Full", "Prod")]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$OrgAlias,

        $OrgInfo = $null
    )

    $Entry = (Get-LdgcrmEnvironmentTable)[$Environment]
    $Color = if ($Entry.IsProduction) { "Red" } else { "Cyan" }

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor $Color
    Write-Host (" TARGET: {0}  [{1}]" -f $Entry.Label, $Environment) -ForegroundColor $Color
    Write-Host "------------------------------------------------------------" -ForegroundColor $Color
    Write-Host ("  Alias        {0}" -f $OrgAlias)

    if ($Entry.LightningUrl) {
        Write-Host ("  Browser      {0}" -f $Entry.LightningUrl)
    }

    if ($OrgInfo) {
        Write-Host ("  Username     {0}" -f $OrgInfo.username)
        Write-Host ("  Instance     {0}" -f $OrgInfo.instanceUrl)
        Write-Host ("  Org Id       {0}" -f $OrgInfo.id)
        Write-Host ("  Org name     {0}" -f $OrgInfo.orgName)
        Write-Host ("  Sandbox      {0}" -f [bool]$OrgInfo.isSandbox)
    }

    if (-not $Entry.AllowsAccountRebuild) {
        Write-Host ""
        Write-Host "  Accounts in this org are REAL and are never deleted or rebuilt." -ForegroundColor Yellow
    }

    if ($Entry.IsProduction) {
        Write-Host ""
        Write-Host "  *** THIS IS PRODUCTION. REAL PARTNER DATA. ***" -ForegroundColor Red
    }

    Write-Host ""
}

function Assert-LdgcrmProductionConsent {
    <#
        The extra gate in front of any write or delete against production, on
        top of whatever typed confirmation the calling script already has.

        Requires the operator to type the environment's alias exactly - not
        "yes", not a single keystroke - so it cannot be cleared by a stray
        Enter on a prompt they didn't read. No-op for sandboxes.

        Returns $true to proceed, $false if the operator declined.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA", "Full", "Prod")]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        # Non-interactive approval for an automated production run. The operator
        # must pass the org alias in full, exactly as the prompt would ask them
        # to type it.
        #
        # THIS IS A SEPARATE TOKEN FROM THE SCRIPT'S OWN -Confirmation, ON
        # PURPOSE. Production writes therefore need TWO distinct approvals on the
        # command line, neither of which can be supplied by habit:
        #   -Confirmation "LOAD" -ProductionConfirmation "gsa-peo"
        # Collapsing them into one flag would mean an operator who had automated
        # a sandbox load could retarget it at production by changing only
        # -Environment.
        [string]$ProductionConfirmation = ""
    )

    $Entry = (Get-LdgcrmEnvironmentTable)[$Environment]

    if (-not $Entry.IsProduction) {
        return $true
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " PRODUCTION WRITE GUARD" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "About to: $Action" -ForegroundColor Red
    Write-Host "Against:  $($Entry.Label) ($($Entry.Alias))" -ForegroundColor Red
    Write-Host ""
    Write-Host "This affects real Login.gov partner data. Coordinate with the" -ForegroundColor Yellow
    Write-Host "Operations team and confirm the change window before continuing." -ForegroundColor Yellow
    Write-Host ""

    if (-not (Assert-LdgcrmTypedConfirmation `
            -Token $Entry.Alias `
            -Provided $ProductionConfirmation `
            -Action "PRODUCTION: $Action" `
            -Prompt "Type the org alias ($($Entry.Alias)) to proceed" `
            -ParameterName "-ProductionConfirmation")) {
        Write-Host ""
        Write-Host "Production guard not cleared. Nothing was run." -ForegroundColor Yellow
        return $false
    }

    return $true
}
