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

function Assert-LdgcrmTypedConfirmation {
    <#
        The single confirmation gate for every destructive or write operation in
        this repo. Interactive by default; passable non-interactively by
        supplying the SAME token the prompt would ask a human to type.

        WHY THIS IS NOT A -Force SWITCH
        ===============================
        A boolean -Force is one keystroke, reads the same on every command, and
        gets copy-pasted between contexts without thought - which is precisely
        the failure mode a confirmation gate exists to prevent. Requiring the
        literal token instead keeps the "state your intent" property that made
        the interactive prompt worth having:

            -Confirmation "HARD DELETE"

        cannot be mistaken for anything else in a shell history, a CI log, or a
        code review, and it cannot be carried across from a LOAD script to a
        delete script by habit, because the tokens differ.

        A typed prompt never proved anyone had READ anything anyway - it proved
        someone could type. This keeps that same (modest) guarantee while making
        the pipeline automatable by an agent, by CI, or by the Operations team,
        which the interactive-only version simply was not.

        WHAT IT STILL WILL NOT DO
        =========================
        It does not weaken any other gate. The Sandbox Factory Reset still
        cannot target production at all (that block is structural, not a
        prompt), and Assert-LdgcrmProductionConsent still applies on top of this
        wherever it applies today.

        EVERY NON-INTERACTIVE USE IS ANNOUNCED AND RECORDED. The banner below
        goes through Write-Host into the script's transcript, so the audit trail
        shows the operation was approved by flag rather than by a human at a
        keyboard, and by whom.

        Returns $true to proceed, $false if a human declined at the prompt.
        THROWS on a wrong token, and on a missing token in a host that cannot
        prompt - a clear instruction beats PowerShell's default
        "Windows PowerShell is in NonInteractive mode", which tells an operator
        nothing about how to fix it.
    #>
    param(
        # What the operator must type/pass, e.g. "HARD DELETE". Compared
        # case-sensitively: "hard delete" is not an approval.
        [Parameter(Mandatory = $true)]
        [string]$Token,

        # Human-readable description of what is being approved, for the banner
        # and for the error text.
        [Parameter(Mandatory = $true)]
        [string]$Action,

        # The value of the calling script's -Confirmation parameter. Empty means
        # "prompt me".
        [string]$Provided = "",

        # Overrides the prompt wording; the default suits most callers.
        [string]$Prompt = "",

        # The calling script's -Confirmation parameter name, quoted in the
        # error when a host cannot prompt. Only differs if a script renames it.
        [string]$ParameterName = "-Confirmation"
    )

    if (-not $Prompt) { $Prompt = "Type $Token to continue" }

    if ($Provided) {
        if ($Provided -cne $Token) {
            throw ("Confirmation token mismatch. Expected exactly '$Token' but got '$Provided'. " +
                   "Nothing was run. (The comparison is case-sensitive on purpose.)")
        }

        Write-Host ""
        Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host " NON-INTERACTIVE CONFIRMATION" -ForegroundColor Yellow
        Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host ("  Approved : {0}" -f $Action)
        Write-Host ("  Token    : {0}  (supplied via {1})" -f $Token, $ParameterName)
        Write-Host ("  User     : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
        Write-Host ("  Host     : {0}" -f $env:COMPUTERNAME)
        Write-Host ("  When     : {0}" -f (Get-Date).ToString("u"))
        Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host ""

        return $true
    }

    # No token supplied - fall back to prompting, and give a usable error when
    # the host has no console to prompt with (agent harnesses, CI, scheduled
    # tasks). Read-Host is attempted rather than guessed at via
    # [Environment]::UserInteractive, which is unreliable across hosts.
    try {
        $Typed = Read-Host $Prompt
    }
    catch {
        throw ("This host cannot prompt for confirmation, and no token was supplied. " +
               "Re-run with $ParameterName `"$Token`" to approve non-interactively: $Action")
    }

    if ($Typed -cne $Token) {
        return $false
    }

    return $true
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
