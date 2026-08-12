# Shared helpers for Login.gov CRM migration automation scripts.
# Dot-source from a script in scripts/<category>/:
#   . (Join-Path $PSScriptRoot "..\common\Common.ps1")
#
# Cross-platform: uses Join-Path/Split-Path only, no hardcoded
# path separators, so scripts run under pwsh on Windows, macOS, or Linux.

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
