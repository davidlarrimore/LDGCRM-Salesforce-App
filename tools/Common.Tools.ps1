# Shared helpers for the ENGINEERING-ONLY scripts in tools/.
#
# Dot-source from a script in tools/ or tools/<category>/:
#   . (Join-Path $PSScriptRoot "Common.Tools.ps1")
#   . (Join-Path $PSScriptRoot "..\Common.Tools.ps1")
#
# Targets Windows PowerShell 5.1, same as everything else here.
#
# =============================================================================
# WHY tools/ EXISTS SEPARATELY FROM scripts/
# =============================================================================
# scripts/ is the OPERATIONS BUNDLE. It is zipped up and handed to the GSA
# Salesforce Operations team, who drop it into their own GitHub repo as a plain
# /scripts folder and run the migration out of it. Nothing in that bundle may
# resolve a path above its own root, because above its own root is a repository
# this project does not control and cannot make assumptions about.
#
# These three scripts cannot honour that rule, because their whole job is to
# read parts of the ENGINEERING repo that the bundle deliberately excludes:
#
#   metadata/Sync-Metadata.ps1              retrieves into sfdx/
#   metadata/Get-LDGCRMDataDictionary.ps1   writes a dictionary of sfdx/ objects
#   metadata/Find-UnexposedLDGCRMFields.ps1 reads sfdx/force-app/main/default
#   Export-ReportPdf.ps1                    renders docs/*.html
#   Build-ProdAccountSeed.ps1               superseded; kept for provenance
#
# =============================================================================
# METADATA IS NOT THE OPERATIONS TEAM'S JOB - AND NOR IS ITS OUTPUT
# =============================================================================
# This is the stronger reason, and it is a policy line rather than a technical
# one. Metadata moves between orgs by CHANGE SET ONLY (see CLAUDE.md). The
# metadata scripts exist to BUILD THE APP and diagnose problems - they are a
# development aid. Operations never retrieves or deploys metadata, and this
# project is not responsible for pushing or pulling it on their behalf.
#
# So none of it ships: not the scripts, not their logs, not their CSV output.
# Shipping the tooling would invite exactly the thing the policy forbids, and
# shipping the OUTPUT would suggest the pipeline owns a metadata state it does
# not.
#
# WHAT IS STILL FAIR GAME INSIDE THE BUNDLE - the distinction that matters:
#
#   YES  READING the org to check that what a load needs actually exists:
#        a field, a picklist value, a record-type assignment, an external ID
#        being non-unique. The pipeline already does this in several places
#        (Build-ApplicationLoad reads live field definitions before deciding
#        whether to send two columns) and a consolidated pre-flight check
#        belongs in the bundle, not here.
#   YES  TOGGLING a documented switch the load needs, and putting it back:
#        Invoke-SalesforceLoad's TriggerControls__c bypass is the model -
#        capture, flip, restore in a finally, verify the restore.
#   NO   DEPLOYING or RETRIEVING metadata, in either direction, for any reason.
#        If a load is blocked by missing metadata, the pipeline's job is to say
#        so precisely and stop. Someone else builds the change set.
#
# THE PRACTICAL RULE. If a script needs sfdx/ or docs/, it belongs here. If it
# reads Airtable, or reads/writes RECORDS in Salesforce, it belongs in the
# bundle and must use Get-LdgcrmRoot instead of the function below.
#
# WHERE tools/ OUTPUT LANDS: <repo>/logs/tools/, via Start-ToolLog below -
# OUTSIDE the bundle. It used to go to scripts/logs/metadata/ on the reasoning
# that one logging convention beats two and the folder was gitignored anyway.
# That was wrong on the point that matters: it put engineering-only run output,
# and a whole log category that only metadata tooling used, inside the folder
# handed to Operations. The bundle's own log categories are now cleanup and
# data-migration only.

function Get-RepoRoot {
    <#
        The ENGINEERING repository root - the folder holding sfdx/, docs/,
        scripts/ and tools/.

        This function used to live in scripts/powershell-scripts/Common.ps1 and was used by
        the whole pipeline. It was moved here on 2026-08-14 and deliberately
        DELETED from the bundle: left in place it would keep resolving happily
        after the bundle was dropped into the Operations repo, and quietly
        return THEIR repository root. Paths would still join, files would still
        be written - just in someone else's tree. A missing function fails
        loudly on the first call instead.
    #>

    # tools/Common.Tools.ps1 -> tools/ -> repo root. Note this is one level
    # from THIS file, unlike the bundle's two-deep common/ folder.
    Split-Path -Parent $PSScriptRoot
}

function Get-LdgcrmBundleRoot {
    <#
        The Operations bundle (scripts/) as seen from the engineering repo.

        Only for tooling that packages or inspects the bundle - notably
        Export-OpsBundle.ps1. Scripts INSIDE the bundle must never call this;
        they use Get-LdgcrmRoot, which derives the same folder from their own
        location and therefore keeps working once the bundle is moved.
    #>

    Join-Path (Get-RepoRoot) "scripts"
}

function Get-ToolLogDirectory {
    <#
        <repo>/logs/tools/ - where engineering-only run output goes, OUTSIDE
        the Operations bundle. Gitignored by the repo-root .gitignore.
    #>

    $Dir = Join-Path (Join-Path (Get-RepoRoot) "logs") "tools"

    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }

    return $Dir
}

function Start-ToolLog {
    <#
        The tools/ equivalent of the bundle's Start-ScriptLog: opens a
        transcript in <repo>/logs/tools/<ScriptName>-<timestamp>/ and returns
        the run's timestamp for naming any other output.

        HOW IT REDIRECTS THE BUNDLE'S HELPERS TOO. These scripts still
        dot-source the bundle's Common.ps1 for the confirmation gate and the
        Salesforce helpers, so a call to Get-LogDirectory would otherwise land
        back inside scripts/logs/. Setting $env:LDGCRM_RUN_DIRECTORY first means
        the bundle's own "one directory per run" mechanism adopts this folder -
        Get-LogDirectory returns it, and Start-ScriptLog would JOIN it rather
        than create its own. So every downstream write follows, with no change
        to the bundle and no second convention to remember.

        Pair with Stop-ToolLog in a finally block.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $RunDirectory = Join-Path (Get-ToolLogDirectory) "$ScriptName-$Timestamp"

    if (-not (Test-Path -LiteralPath $RunDirectory)) {
        New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    }

    $env:LDGCRM_RUN_DIRECTORY = $RunDirectory

    Start-Transcript -Path (Join-Path $RunDirectory "$ScriptName.log") | Out-Null

    return $Timestamp
}

function Stop-ToolLog {
    <#
        Closes the transcript and releases the run directory, so a second script
        run in the same session does not silently merge into the first.
    #>

    Stop-Transcript | Out-Null
    $env:LDGCRM_RUN_DIRECTORY = $null
}
