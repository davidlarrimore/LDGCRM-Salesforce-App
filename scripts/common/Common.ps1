# Shared helpers for Login.gov CRM migration automation scripts.
# Dot-source from a script in scripts/<category>/:
#   . (Join-Path $PSScriptRoot "..\common\Common.ps1")
#
# Targets Windows PowerShell 5.1 (no PowerShell 7-only syntax: no ??, ?., ternary
# ?:, -AsHashtable, -Parallel, or multi-argument Join-Path). Uses Join-Path/Split-Path
# with the classic two-argument form only, so path handling stays portable if this
# ever does run under pwsh 7+ on another machine.

# The Salesforce environment registry (Dev/QA/Full/Prod -> org alias) lives in
# its own file but is dot-sourced from here so that every script already
# dot-sourcing Common.ps1 gets Resolve-LdgcrmOrgAlias/Assert-LdgcrmOrgTarget
# without a second line. Scripts must never hard-code an org alias again - see
# the header of Common.Orgs.ps1 for why ("gsa-peo" used to mean the Dev
# sandbox, and now means production).
. (Join-Path $PSScriptRoot "Common.Orgs.ps1")

function Get-RepoRoot {
    # This file lives at scripts/common/, so the repo root is two levels up.
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Get-LogDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("metadata", "cleanup", "data-migration")]
        [string]$Category
    )

    $LogDir = Join-Path (Join-Path (Get-RepoRoot) "logs") $Category

    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    return $LogDir
}

function Start-ScriptLog {
    <#
        Starts a PowerShell transcript for the calling script under
        logs/<Category>/<ScriptName>-<timestamp>.log and returns the
        timestamp so callers can reuse it for any output files
        (CSV exports, summaries, etc.) written during the same run.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("metadata", "cleanup", "data-migration")]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $LogDir = Get-LogDirectory -Category $Category
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $TranscriptPath = Join-Path $LogDir "$ScriptName-$Timestamp.log"

    Start-Transcript -Path $TranscriptPath | Out-Null

    return $Timestamp
}

function Stop-ScriptLog {
    Stop-Transcript | Out-Null
}

function Import-DotEnv {
    <#
        Loads KEY=VALUE pairs from the repo-root .env file into the current
        process's environment variables. Skips blank lines and #-comments.
        Never overwrites a variable that's already set in the environment,
        so an explicit $env:X set before running a script still wins.
    #>
    param(
        [string]$Path = (Join-Path (Get-RepoRoot) ".env")
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($Line in Get-Content -LiteralPath $Path) {
        $Trimmed = $Line.Trim()

        if ([string]::IsNullOrWhiteSpace($Trimmed) -or $Trimmed.StartsWith("#")) {
            continue
        }

        $Separator = $Trimmed.IndexOf("=")

        if ($Separator -lt 1) {
            continue
        }

        $Key = $Trimmed.Substring(0, $Separator).Trim()
        $Value = $Trimmed.Substring($Separator + 1).Trim().Trim('"').Trim("'")

        if (-not (Test-Path "Env:$Key")) {
            Set-Item -Path "Env:$Key" -Value $Value
        }
    }
}
