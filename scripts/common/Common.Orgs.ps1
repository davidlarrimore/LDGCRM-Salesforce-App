# Salesforce environment registry for the Login.gov CRM migration.
#
# Dot-sourced automatically by scripts/common/Common.ps1, so every script in
# this repo gets these helpers without adding a line of its own.
#
# Targets Windows PowerShell 5.1 (no ??, ?., ternary ?:, -AsHashtable,
# -Parallel, or multi-argument Join-Path).
#
# =============================================================================
# WHY THIS FILE EXISTS
# =============================================================================
# Until 2026-08-13 every script in this repo hard-coded the alias "gsa-peo",
# and that alias pointed at the DEV SANDBOX (PEOdV8DVn). "gsa-peo" is the name
# of the PRODUCTION org, so 146 references across 26 files read as though they
# targeted production while actually targeting Dev. Nothing was ever mis-loaded
# because of it, but the naming could not survive a second environment - and
# there are now four.
#
# The scheme (chosen 2026-08-13): AN ALIAS IS THE ORG'S OWN SANDBOX NAME, so an
# alias cannot drift from the org it names. Scripts never take a bare alias
# from a human; they take -Environment Dev|QA|Full|Prod and resolve it here.
#
# =============================================================================
# THE gsa-peo HAZARD - READ THIS BEFORE RE-CREATING THAT ALIAS
# =============================================================================
# Under this scheme "gsa-peo" now means PRODUCTION. It previously meant Dev.
# Any stale script, doc, or muscle-memory command line still saying
# "--target-org gsa-peo" therefore points at production instead of the sandbox
# it was written for - a silent retarget, in the dangerous direction.
#
# Two things keep that from biting:
#   1. Every reference in this repo was updated in the same change.
#   2. The local "gsa-peo" alias was DELETED (2026-08-13) and production has
#      not been authorized. A stale reference fails loudly with "No
#      authorization information found" instead of quietly writing to prod.
#
# Do not re-create a "gsa-peo" alias pointing anywhere other than production.
# When production genuinely needs authorizing, see the auth runbook in
# docs/README.md ("Environments and org aliases").
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
        IsProduction    - gates the extra typed confirmation in write/delete
                          scripts. Only ever true for Prod.
    #>

    return [ordered]@{
        Dev = [PSCustomObject]@{
            Key          = "Dev"
            Alias        = "peodv8dvn"
            SandboxName  = "PEOdV8DVn"
            Label        = "Dev sandbox"
            Purpose      = "Day-to-day development and pipeline testing. Default for every script."
            IsProduction = $false
        }
        QA = [PSCustomObject]@{
            Key          = "QA"
            Alias        = "peodv15dvn"
            SandboxName  = "PEOdV15DVn"
            Label        = "QA sandbox"
            Purpose      = "Full end-to-end migration rehearsal before the Operations hand-off."
            IsProduction = $false
        }
        Full = [PSCustomObject]@{
            # NOT YET PROVISIONED/NAMED as of 2026-08-13. A Full sandbox the
            # Operations team will use to run these scripts and the change sets
            # themselves, as the final dress rehearsal before production.
            # Fill in Alias + SandboxName below once the sandbox exists; nothing
            # else in this repo needs to change.
            Key          = "Full"
            Alias        = ""
            SandboxName  = ""
            Label        = "Full sandbox (Operations integration testing)"
            Purpose      = "Operations team dress rehearsal: scripts + change sets, immediately before production."
            IsProduction = $false
        }
        Prod = [PSCustomObject]@{
            # Deliberately not authorized on this machine. See the hazard note
            # at the top of this file before creating this alias.
            Key          = "Prod"
            Alias        = "gsa-peo"
            SandboxName  = ""
            Label        = "PRODUCTION"
            Purpose      = "The live GSA PEO org. Real Login.gov partner data."
            IsProduction = $true
        }
    }
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
               "Authorize the org (see docs/README.md, 'Environments and org aliases'), then fill in " +
               "Alias and SandboxName for '$Environment' in scripts/common/Common.Orgs.ps1.")
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
               "Authorize it first - see docs/README.md, 'Environments and org aliases'.")
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

    if ($OrgInfo) {
        Write-Host ("  Username     {0}" -f $OrgInfo.username)
        Write-Host ("  Instance     {0}" -f $OrgInfo.instanceUrl)
        Write-Host ("  Org Id       {0}" -f $OrgInfo.id)
        Write-Host ("  Org name     {0}" -f $OrgInfo.orgName)
        Write-Host ("  Sandbox      {0}" -f [bool]$OrgInfo.isSandbox)
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
        [string]$Action
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

    $Typed = Read-Host "Type the org alias ($($Entry.Alias)) to proceed"

    if ($Typed -cne $Entry.Alias) {
        Write-Host ""
        Write-Host "Production guard not cleared. Nothing was run." -ForegroundColor Yellow
        return $false
    }

    return $true
}
