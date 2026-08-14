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
# There is also a policy reason, which is the stronger one: metadata moves
# between orgs by CHANGE SET ONLY (see CLAUDE.md). Operations never runs a
# metadata retrieve or deploy, so shipping them the tooling for it would invite
# exactly the thing the policy forbids.
#
# THE PRACTICAL RULE. If a script needs sfdx/ or docs/, it belongs here. If it
# reads Airtable or writes to Salesforce, it belongs in the bundle and must use
# Get-LdgcrmRoot instead of the function below.
#
# WHERE tools/ OUTPUT LANDS. These scripts still dot-source the bundle's
# Common.ps1 for Start-ScriptLog / Get-LogDirectory / the confirmation gate, so
# their transcripts go to scripts/logs/<category>/ alongside the pipeline's.
# That is deliberate: one logging convention beats two, the folder is gitignored,
# and Export-OpsBundle.ps1 ships logs/ empty, so nothing engineering-only ever
# reaches Operations. Do not add a second log root for tools/.

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
