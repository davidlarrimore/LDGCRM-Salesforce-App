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

# ============================================================
# ONE DIRECTORY PER RUN
# ============================================================
# Everything a run produces goes in ONE folder: transcripts, review CSVs, bulk
# failure rows, restore points, the summary report.
#
# WHY IT CHANGED (2026-08-13). It used to be the opposite. Each script wrote its
# transcript and review CSVs loose into logs/<category>/, and separately created
# its own typed folder - full-load-<ts>/, notes-load-<ts>/, bulk-results/<obj>-<ts>/,
# rollback-<ts>/, account-bootstrap-<ts>/. So ONE logical load scattered output
# across four folder shapes plus ~30 loose files, all correlated only by a
# timestamp - and each child script stamps its OWN timestamp, so they didn't even
# match. logs/data-migration/ reached 330 loose CSVs across ~40 runs, and
# answering "what did the last load produce?" meant knowing which timestamps
# belonged together.
#
# HOW IT WORKS. The first script to call Start-ScriptLog creates the run
# directory and publishes it in $env:LDGCRM_RUN_DIRECTORY. Get-LogDirectory
# returns that whenever it is set, so every existing caller redirects into it
# with no change at the call site. Child processes inherit the variable, which is
# what makes an orchestrated run land in one folder while a child still keeps its
# own transcript - the orchestrator runs its steps as child processes precisely
# so a failure cannot take down its own log.
#
# The variable is process-scoped, so it cannot leak into an unrelated shell:
# setting $env:X in PowerShell affects this process and the ones it starts, and
# nothing else. Running any script standalone still gets its own run directory.
function Get-LdgcrmRunDirectory {
    <#
        The current run's directory, or "" when no run is in progress.
    #>
    if ($env:LDGCRM_RUN_DIRECTORY) { return $env:LDGCRM_RUN_DIRECTORY }
    return ""
}

function Get-LogDirectory {
    <#
        Where this run's output goes.

        Returns the RUN DIRECTORY when a run is in progress, so every caller
        that already writes to "the log directory" lands in the run's own folder
        without changing. Falls back to logs/<Category>/ otherwise - which is
        what a call before Start-ScriptLog, or from an interactive session, gets.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("metadata", "cleanup", "data-migration")]
        [string]$Category
    )

    $RunDirectory = Get-LdgcrmRunDirectory
    if ($RunDirectory) {
        if (-not (Test-Path -LiteralPath $RunDirectory)) {
            New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
        }
        return $RunDirectory
    }

    $LogDir = Join-Path (Join-Path (Get-RepoRoot) "logs") $Category

    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    return $LogDir
}

function Get-LogCategoryDirectory {
    <#
        logs/<Category>/ itself, ignoring any run in progress.

        For the few things that are genuinely ABOUT the set of runs rather than
        part of one: finding the previous run to compare against, listing run
        directories. Everything else wants Get-LogDirectory.
    #>
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
        Opens this script's transcript inside the run directory, creating that
        directory (and joining an orchestrated run) as described above.

        Returns the run's timestamp, which callers use to name their own output.
        WITHIN A RUN EVERY SCRIPT GETS THE SAME TIMESTAMP - it comes from the
        run directory's name, not from the clock at the moment each child
        started. That is what makes the files in one folder obviously belong
        together; previously each child stamped its own and a single load
        produced a dozen different timestamps.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("metadata", "cleanup", "data-migration")]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $RunDirectory = Get-LdgcrmRunDirectory
    $Script:LdgcrmRunOwned = $false

    if ($RunDirectory) {
        # Joining a run someone else started. Recover its timestamp from the
        # folder name so this script's output sorts with the rest of the run's.
        $Timestamp = ""
        if ((Split-Path -Leaf $RunDirectory) -match '(\d{8}-\d{6})$') { $Timestamp = $Matches[1] }
        if (-not $Timestamp) { $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss" }
    }
    else {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $RunDirectory = Join-Path (Get-LogCategoryDirectory -Category $Category) "$ScriptName-$Timestamp"
        $env:LDGCRM_RUN_DIRECTORY = $RunDirectory
        $Script:LdgcrmRunOwned = $true
    }

    if (-not (Test-Path -LiteralPath $RunDirectory)) {
        New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    }

    # No timestamp in the file name: the folder already carries it, and a run
    # that ran two scripts of the same name would be a resume, which should
    # overwrite rather than accumulate near-identical transcripts.
    Start-Transcript -Path (Join-Path $RunDirectory "$ScriptName.log") | Out-Null

    return $Timestamp
}

function Stop-ScriptLog {
    <#
        Closes the transcript, and releases the run directory if THIS script
        created it.

        Ownership is tracked by Start-ScriptLog rather than passed in, so no
        caller changes: a script that JOINED a run must not release someone
        else's directory, and it is Start-ScriptLog that knows which happened.

        The release matters when scripts are dot-sourced or run twice in one
        PowerShell session - a second run would otherwise inherit the first
        run's folder and quietly merge two loads into one. Each step of an
        orchestrated load runs as its own process, where the variable dies with
        the process anyway; this covers the cases where it does not.
    #>

    Stop-Transcript | Out-Null

    if ($Script:LdgcrmRunOwned) {
        $env:LDGCRM_RUN_DIRECTORY = $null
        $Script:LdgcrmRunOwned = $false
    }
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
