# Salesforce environment registry for the LDGCRM dev/QA data-loading tools.
#
# Dot-sourced automatically by data-loading/Common.ps1, so every script here gets
# these helpers without adding a line of its own.
#
# Targets Windows PowerShell 5.1 (no ??, ?., ternary ?:, -AsHashtable,
# -Parallel, or multi-argument Join-Path).
#
# =============================================================================
# DEV AND QA ONLY - AND THAT IS ENFORCED, NOT DOCUMENTED
# =============================================================================
# Sprint 1 migrated Login.gov's Airtable base into production. These scripts are
# what rebuilds a DEVELOPER SANDBOX so the app can be worked on afterwards: pull
# Airtable, reset the sandbox, load it, throw it away, repeat.
#
# They are no longer a migration pipeline and they no longer target production.
# Every -Environment parameter is [ValidateSet("Dev","QA")], so UAT, Full and
# Prod are rejected AT PARAMETER BINDING, before a script body runs and before
# anything touches an org. That is a structural block, not a convention: it
# cannot be argued past, and it fails identically whether the operator typed the
# wrong thing or a saved command was retargeted.
#
# The production-shaped helpers below still exist because eight scripts call
# them. They are now no-ops that can never fire, kept so the call sites stay
# honest rather than being deleted one by one and getting out of step.
#
# THE ALIAS SCHEME IS UNCHANGED: an alias IS the org's own sandbox name, so it
# can be checked against the instance URL and cannot silently drift.
# =============================================================================

function Get-LdgcrmEnvironmentTable {
    <#
        The single source of truth for which org each environment is.

        Alias        - the `sf` alias, which is the sandbox name lower-cased.
        SandboxName  - proven against the instance URL by Assert-LdgcrmOrgTarget,
                       so a repointed alias stops the run.
        InstanceUrl  - the org's my.salesforce.com URL.
        LightningUrl - the URL a human would open. Printed in the pre-run banner
                       so an operator can confirm by eye which org they are about
                       to rebuild.
        IsProduction / AllowsAccountRebuild
                     - retained so Assert-LdgcrmOrgTarget and the banner keep
                       working unchanged. Constant across this table: neither
                       environment is production, and both may be rebuilt.
    #>

    return [ordered]@{
        Dev = [PSCustomObject]@{
            Key                  = "Dev"
            Alias                = "peodv8dvn"
            SandboxName          = "PEOdV8DVn"
            InstanceUrl          = "https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com"
            LightningUrl         = "https://gsa-peo--peodv8dvn.sandbox.lightning.force.com"
            Label                = "Dev sandbox"
            Purpose              = "Day-to-day development. Default for every script."
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
            Purpose              = "Shared testing against a freshly loaded sandbox."
            IsProduction         = $false
            AllowsAccountRebuild = $true
        }
    }
}

function Test-LdgcrmAccountRebuildAllowed {
    <#
        May the Account tree be deleted and rebuilt from the production export?

        ALWAYS TRUE HERE. Both registered environments are developer sandboxes
        that hold no real Account data of their own, so the load has nothing to
        attach to until Invoke-AccountBootstrap.ps1 builds an Account universe
        from the production export. Rebuilding is the only way a sandbox load
        means anything.

        This used to be the rule that protected UAT, Full and production - all
        copies of production, whose Accounts ARE the real records. Those
        environments are no longer reachable from these scripts at all, so the
        rule has nothing left to exclude. Kept as a function, returning a
        constant, because three scripts consume it and a missing function would
        be a harder failure than a true one.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA")]
        [string]$Environment
    )

    return [bool](Get-LdgcrmEnvironmentTable)[$Environment].AllowsAccountRebuild
}

function Select-LdgcrmResettableObjects {
    <#
        Filters a factory-reset object list down to what may be deleted here.

        Everything, in both environments - see Test-LdgcrmAccountRebuildAllowed.
        Throws when handed nothing, rather than running a reset that deletes
        nothing and reports success.

        CALLER CONTRACT: wrap the result in @(). Returned bare (no leading comma)
        precisely so that works - PowerShell unrolls the array on output and @()
        re-collects it, which also normalises the 0- and 1-element cases the
        caller would otherwise get as $null and a bare string. Do NOT "fix" this
        by adding a comma: `return ,$Kept` plus a caller's @() yields a
        one-element array CONTAINING the array, and the count silently becomes 1.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA")]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Objects
    )

    if ($Objects.Count -eq 0) {
        throw "Nothing to reset: no objects were requested. Nothing was run."
    }

    return $Objects
}

function Get-LdgcrmEnvironment {
    <#
        Resolves an environment key to its registry entry, throwing a usable
        error (not $null) when the entry exists but has no alias yet.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA")]
        [string]$Environment
    )

    $Table = Get-LdgcrmEnvironmentTable
    $Entry = $Table[$Environment]

    if (-not $Entry.Alias) {
        throw ("Environment '$Environment' ($($Entry.Label)) has no org alias configured. " +
               "Authorize the org, then fill in Alias, SandboxName, InstanceUrl and " +
               "LightningUrl for '$Environment' in data-loading/Common.Orgs.ps1.")
    }

    return $Entry
}

function Resolve-LdgcrmOrgAlias {
    <#
        The one line every script uses to turn its -Environment parameter into an
        alias, while still honouring an explicit -OrgAlias override for the rare
        one-off (a scratch org, or a colleague's differently-aliased connection).

            $OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA")]
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
        Re-running `sf org login web --alias peodv8dvn` against the wrong org, or
        a colleague's copied config, silently repoints it - and every safety gate
        downstream ("type HARD DELETE to continue") would then be confirming the
        wrong org in perfect good faith. The sandbox-name alias scheme exists so
        a mismatch is *detectable*; this function is what detects it.

        Checks, in order:
          1. The alias resolves and the org is reachable.
          2. The org is actually a SANDBOX. Read from the org itself, because
             these scripts delete records and a production org must never answer
             to a sandbox alias.
          3. The instance URL contains the expected sandbox name - e.g.
             "peodv8dvn" must appear in
             https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com.

        -Quiet suppresses the banner for read-only callers that print their own.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA")]
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
               "Authorize it first: sf org login web --alias $Alias --instance-url $($Entry.InstanceUrl)")
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
    # authoritative and immune to a stale or repointed local alias entry.
    $OrgRecordRaw = & sf data query --target-org $Alias --query "SELECT IsSandbox, Name, OrganizationType FROM Organization" --json

    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the Organization record from '$Alias' to verify it is a sandbox. Nothing was run."
    }

    $OrgRecordJson = $OrgRecordRaw | ConvertFrom-Json

    if ($OrgRecordJson.status -ne 0 -or $OrgRecordJson.result.totalSize -ne 1) {
        throw "Unexpected Organization query result from '$Alias' while verifying the target org. Nothing was run."
    }

    $OrgRecord = @($OrgRecordJson.result.records)[0]

    Add-Member -InputObject $Org -NotePropertyName "isSandbox"        -NotePropertyValue ([bool]$OrgRecord.IsSandbox) -Force
    Add-Member -InputObject $Org -NotePropertyName "orgName"          -NotePropertyValue $OrgRecord.Name -Force
    Add-Member -InputObject $Org -NotePropertyName "organizationType" -NotePropertyValue $OrgRecord.OrganizationType -Force

    # An explicit -OrgAlias override means the caller deliberately stepped
    # outside the registry, so the registry's identity checks don't apply - but
    # say so loudly rather than validating against the wrong expectations. The
    # sandbox check below still runs: an override is not permission to delete
    # records out of a production org.
    if ($IsOverride) {
        Write-Host ""
        Write-Host "NOTE: -OrgAlias '$Alias' overrides environment '$Environment' ($($Entry.Alias))." -ForegroundColor Yellow
        Write-Host "      Registry identity checks are skipped for an explicit override." -ForegroundColor Yellow
    }

    if (-not [bool]$Org.isSandbox) {
        throw ("SAFETY STOP: alias '$Alias' resolves to a PRODUCTION org ($($Org.instanceUrl)). " +
               "These are dev/QA tools and they delete records. Nothing was run.")
    }

    if (-not $IsOverride -and $Entry.SandboxName) {
        $Expected = $Entry.SandboxName.ToLowerInvariant()
        $InstanceUrl = "$($Org.instanceUrl)".ToLowerInvariant()

        if ($InstanceUrl -notlike "*$Expected*") {
            throw ("SAFETY STOP: alias '$Alias' should point at sandbox '$($Entry.SandboxName)' but its " +
                   "instance URL is $($Org.instanceUrl). The alias has been repointed at a different org. " +
                   "Nothing was run.")
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
        confirmation prompt.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA")]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$OrgAlias,

        $OrgInfo = $null
    )

    $Entry = (Get-LdgcrmEnvironmentTable)[$Environment]

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host (" TARGET: {0}  [{1}]" -f $Entry.Label, $Environment) -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
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

    Write-Host ""
}

function Assert-LdgcrmProductionConsent {
    <#
        NO-OP, AND IT CAN NEVER FIRE.

        This was the extra gate in front of a write or delete against production:
        it made the operator type the org alias in full, on top of whatever typed
        confirmation the calling script already had.

        There is no production environment in this registry any more, and every
        -Environment is [ValidateSet("Dev","QA")], so a production run is
        rejected at parameter binding long before this could be reached.

        Kept, returning $true, because five scripts call it. Deleting it would
        mean editing all five to remove a gate that is already unreachable - more
        churn, and five chances to remove the wrong line. If a production path is
        ever wanted again, it belongs in a separate tool, not behind a flag here.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Dev", "QA")]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [string]$ProductionConfirmation = ""
    )

    return $true
}
