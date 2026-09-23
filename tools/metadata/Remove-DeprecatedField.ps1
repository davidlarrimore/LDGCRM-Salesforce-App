#Requires -Version 5.1
<#
    Deletes a Sprint 2 deprecated field from a target org, following the runbook
    in scripts/docs/deployment.md sections 5 and 6, and removes the field's file
    from force-app/ so a later retrieve stops resurrecting it.

    WHY A CLI DEPLOY IS ALLOWED HERE. CLAUDE.md's rule is that metadata promotion
    happens by CHANGE SET only, with two exceptions - ApiNamedQuery, and DELETING
    metadata. This is the second one, and it is not a preference: a change set
    only adds and changes, so it *cannot* carry a deletion. There is no change-set
    path to compare against.

    WHY IT TAKES A BARE -OrgAlias AND NOT AN -Environment. Every script in
    tools/data-loading/ is [ValidateSet("Dev","QA")], because its job is loading
    and hard-deleting RECORDS and it must never reach production. This script has
    the opposite requirement: the whole point of a deprecated field is that it has
    to be removed from every org it reached, production included, as each one
    takes the Sprint 2 change set. CLAUDE.md says that a production-side operation
    "belongs in a separate, purpose-built tool - not behind a widened ValidateSet
    on a script whose job is hard-deleting records". This is that separate tool.
    It touches no records, and it makes the operator name the org explicitly and
    type a confirmation that differs in production.

    WHAT IT WILL NOT DO. It cannot purge a field that is ALREADY soft-deleted.
    Salesforce keeps a deleted field in Setup -> Object Manager -> <Object> ->
    Fields & Relationships -> Deleted Fields for 15 days, and only the UI's
    "Erase" - or the timer - removes it for good. A destructive deploy against a
    field in that state has nothing to delete. The script detects the state and
    says so rather than reporting a hollow success.

    Usage:
        # See what would happen, change nothing:
        powershell tools/metadata/Remove-DeprecatedField.ps1 -OrgAlias peodv8dvn -WhatIf

        # Delete both deprecated fields from a sandbox:
        powershell tools/metadata/Remove-DeprecatedField.ps1 -OrgAlias peodv15dvn `
            -Confirmation "DELETE FIELD"

        # One field only:
        powershell tools/metadata/Remove-DeprecatedField.ps1 -OrgAlias peodv8dvn `
            -Field PP_Issuer_Strings -Confirmation "DELETE FIELD"
#>
param(
    # The org to delete from. Deliberately free-form: this tool is expected to
    # run against UAT, Full and production as the change set reaches them, and
    # those are absent from tools/data-loading/Common.Orgs.ps1 by design.
    [Parameter(Mandatory = $true)]
    [string]$OrgAlias,

    [ValidateSet("PP_Issuer_Strings", "Est_Monthly_Active_Users", "All")]
    [string[]]$Field = @("All"),

    # "DELETE FIELD" for a sandbox; "DELETE FIELD IN PRODUCTION" when the org
    # reports IsSandbox = false. Empty prompts interactively.
    [string]$Confirmation = "",

    # Report and export, but neither deploy nor touch force-app/.
    [switch]$WhatIf,

    # Leave the field file in force-app/ even after a successful delete. Only for
    # the case where the same working tree still has to deploy to another org.
    [switch]$KeepLocalFile,

    # Matches the runbook and sfdx-project.json's sourceApiVersion. CustomField
    # long predates both, so there is no ApiNamedQuery-style version floor here.
    [string]$ApiVersion = "64.0"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\Common.Tools.ps1")
. (Join-Path $PSScriptRoot "..\data-loading\Common.ps1")

# ---------------------------------------------------------------------------
# The registry. One entry per field the Sprint 2 deployment has to remove.
# Adding a field here is the whole cost of covering it.
# ---------------------------------------------------------------------------
$DeprecatedFields = @(
    [PSCustomObject]@{
        Key         = "PP_Issuer_Strings"
        SObject     = "LDGCRM_application__c"   # lower-case "a" is a real API-name typo
        FieldName   = "LDGCRM_PP_Issuer_Strings__c"
        Label       = "Issuer Strings (Deprecated)"
        DocSection  = "scripts/docs/deployment.md section 5"
        # Hand-maintained by OEs in production from ZenDesk move-to-production
        # requests, so its values are real data and the delete destroys them.
        BackupQuery = "SELECT Id, Name, LDGCRM_External_ID__c, LDGCRM_PP_Issuer_Strings__c FROM LDGCRM_application__c WHERE LDGCRM_PP_Issuer_Strings__c != null"
    },
    [PSCustomObject]@{
        Key         = "Est_Monthly_Active_Users"
        SObject     = "LDGCRM_application__c"
        FieldName   = "LDGCRM_Est_Monthly_Active_Users__c"
        Label       = "Estimated Monthly Active Users (Dep)"
        DocSection  = "scripts/docs/deployment.md section 6"
        BackupQuery = "SELECT Id, Name, LDGCRM_External_ID__c, LDGCRM_Est_Monthly_Active_Users__c FROM LDGCRM_application__c WHERE LDGCRM_Est_Monthly_Active_Users__c != null"
    }
)

function Invoke-SfJson {
    <#
        Runs `sf` with --json already in the argument list and returns the parsed
        result plus the exit code.

        NO STDERR REDIRECTION. PS 5.1 wraps every stderr line from a native
        command in an ErrorRecord, so the CLI's "update available" banner becomes
        a NativeCommandError that $ErrorActionPreference = "Stop" turns fatal -
        blaming whichever line ran sf. sf writes its JSON, including its ERROR
        JSON, to stdout, so nothing is lost by leaving stderr alone.

        Contract: returns a single PSCustomObject, never a collection.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SfArgs
    )

    $Raw = & sf @SfArgs
    $Exit = $LASTEXITCODE
    $Text = ($Raw -join "`n")

    $Parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        try { $Parsed = $Text | ConvertFrom-Json } catch { $Parsed = $null }
    }

    return [PSCustomObject]@{
        ExitCode = $Exit
        Json     = $Parsed
        Raw      = $Text
    }
}

function Write-XmlNoBom {
    <#
        [System.IO.File]::WriteAllText with an explicit BOM-less encoder.
        Set-Content -Encoding UTF8 writes a BOM in PS 5.1, and XmlDocument.Save()
        adds one too - and a BOM breaks metadata XML. See CLAUDE.md.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Content
    )

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Get-FieldState {
    <#
        Asks the ORG whether a field exists, and how many records populate it.

        SOQL IS THE RIGHT WITNESS, AND FieldDefinition IS NOT. A deleted field
        stays in FieldDefinition (and in a metadata retrieve) for ~15 days while
        it sits in Deleted Fields, but SOQL rejects the column immediately. So
        SOQL leads the deletion and the Tooling API lags it. Confirmed again on
        2026-09-23 in Dev, where SOQL said "No such column" while both
        FieldDefinition and that morning's retrieve still reported the field.

        force-app/ cannot answer this either: a retrieve never deletes a local
        file, so the file being present is equally consistent with "the org has
        it" and "it was deleted months ago and the file was left behind".

        Returns: Present (bool), PopulatedRows (int), SoftDeleted (bool).
    #>
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Definition,
        [Parameter(Mandatory = $true)] [string]$OrgAlias
    )

    $Soql = "SELECT COUNT() FROM $($Definition.SObject) WHERE $($Definition.FieldName) != null"
    $Result = Invoke-SfJson -SfArgs @("data", "query", "-q", $Soql, "--target-org", $OrgAlias, "--json")

    if ($Result.ExitCode -eq 0 -and $Result.Json -and $Result.Json.status -eq 0) {
        return [PSCustomObject]@{
            Present       = $true
            PopulatedRows = [int]$Result.Json.result.totalSize
            SoftDeleted   = $false
        }
    }

    $ErrorCode = ""
    if ($Result.Json -and $Result.Json.data) { $ErrorCode = [string]$Result.Json.data.errorCode }
    if (-not $ErrorCode -and $Result.Json) { $ErrorCode = [string]$Result.Json.name }

    if ($ErrorCode -eq "INVALID_FIELD") {
        # The column is gone from the data layer. Whether it is still in Deleted
        # Fields is answered by the Tooling API, which lags - so if it still
        # lists the field, the field is soft-deleted rather than fully erased.
        $ToolingSoql = "SELECT QualifiedApiName FROM FieldDefinition WHERE EntityDefinition.QualifiedApiName = '$($Definition.SObject)' AND QualifiedApiName = '$($Definition.FieldName)'"
        $Tooling = Invoke-SfJson -SfArgs @("data", "query", "--use-tooling-api", "-q", $ToolingSoql, "--target-org", $OrgAlias, "--json")

        $StillListed = $false
        if ($Tooling.ExitCode -eq 0 -and $Tooling.Json -and $Tooling.Json.status -eq 0) {
            $StillListed = ([int]$Tooling.Json.result.totalSize -gt 0)
        }

        return [PSCustomObject]@{
            Present       = $false
            PopulatedRows = 0
            SoftDeleted   = $StillListed
        }
    }

    throw "Could not determine the state of $($Definition.FieldName) in '$OrgAlias'. sf exited $($Result.ExitCode): $($Result.Raw)"
}

function Remove-LocalFieldFile {
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Definition,
        [Parameter(Mandatory = $true)] [string]$RepoRoot,
        [switch]$WhatIf
    )

    $Relative = "sfdx\force-app\main\default\objects\$($Definition.SObject)\fields\$($Definition.FieldName).field-meta.xml"
    $Path = Join-Path $RepoRoot $Relative

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  force-app/: already absent ($Relative)" -ForegroundColor DarkGray
        return
    }

    if ($WhatIf) {
        Write-Host "  force-app/: WOULD DELETE $Relative" -ForegroundColor Yellow
        return
    }

    Remove-Item -LiteralPath $Path -Force
    Write-Host "  force-app/: deleted $Relative" -ForegroundColor Green
}

# ---------------------------------------------------------------------------

Start-ToolLog -ScriptName "Remove-DeprecatedField" | Out-Null

try {
    $RepoRoot = Get-RepoRoot
    $RunDirectory = Get-LdgcrmRunDirectory
    $ProjectDir = Join-Path $RepoRoot "sfdx"

    if (-not (Get-Command sf -ErrorAction SilentlyContinue)) {
        throw "Salesforce CLI (sf) is not installed or not in your PATH."
    }

    $Selected = $DeprecatedFields
    if ($Field -notcontains "All") {
        $Selected = @($DeprecatedFields | Where-Object { $Field -contains $_.Key })
    }
    if ($Selected.Count -eq 0) {
        throw "No registered deprecated field matched -Field '$($Field -join ", ")'."
    }

    # --- Identify the org from the ORG, not from the local alias cache --------
    # An sf alias is a local, mutable pointer; `sf org list` reads a cache. The
    # only trustworthy answer to "is this production?" comes from the org itself.
    $OrgInfo = Invoke-SfJson -SfArgs @("org", "display", "--target-org", $OrgAlias, "--json")
    if ($OrgInfo.ExitCode -ne 0 -or -not $OrgInfo.Json -or $OrgInfo.Json.status -ne 0) {
        throw "Could not reach org '$OrgAlias'. Check the alias and the CLI auth (a sandbox refresh invalidates it). sf said: $($OrgInfo.Raw)"
    }

    $InstanceUrl = [string]$OrgInfo.Json.result.instanceUrl
    $Username = [string]$OrgInfo.Json.result.username

    $OrgQuery = Invoke-SfJson -SfArgs @("data", "query", "-q", "SELECT IsSandbox, Name FROM Organization LIMIT 1", "--target-org", $OrgAlias, "--json")
    if ($OrgQuery.ExitCode -ne 0 -or -not $OrgQuery.Json -or $OrgQuery.Json.status -ne 0) {
        throw "Could not read Organization.IsSandbox from '$OrgAlias'. Refusing to continue without knowing whether this is production."
    }
    $IsSandbox = [bool]$OrgQuery.Json.result.records[0].IsSandbox
    $OrgName = [string]$OrgQuery.Json.result.records[0].Name

    Write-Host ""
    Write-Host "Target org : $OrgAlias" -ForegroundColor Cyan
    Write-Host "  Name     : $OrgName"
    Write-Host "  Instance : $InstanceUrl"
    Write-Host "  Username : $Username"
    if ($IsSandbox) {
        Write-Host "  Type     : SANDBOX" -ForegroundColor Green
    }
    else {
        Write-Host "  Type     : *** PRODUCTION ***" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Fields selected:" -ForegroundColor Cyan
    foreach ($D in $Selected) {
        Write-Host "  $($D.SObject).$($D.FieldName)  -  $($D.Label)  ($($D.DocSection))"
    }
    Write-Host ""

    if (-not $WhatIf) {
        # A different token in production, so a command copied out of a sandbox
        # shell history cannot be replayed against the real org by habit.
        $Token = "DELETE FIELD"
        if (-not $IsSandbox) { $Token = "DELETE FIELD IN PRODUCTION" }

        Assert-LdgcrmTypedConfirmation `
            -Token $Token `
            -Action "permanently delete $($Selected.Count) field(s), and their data, from '$OrgAlias' ($OrgName)" `
            -Provided $Confirmation | Out-Null
    }

    $BackupDir = Join-Path (Join-Path $RepoRoot "data") "salesforce-backups"
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }

    $Summary = [System.Collections.Generic.List[object]]::new()

    foreach ($Definition in $Selected) {
        Write-Host ""
        Write-Host "=== $($Definition.SObject).$($Definition.FieldName) ===" -ForegroundColor Cyan

        $State = Get-FieldState -Definition $Definition -OrgAlias $OrgAlias

        if (-not $State.Present) {
            if ($State.SoftDeleted) {
                Write-Host "  Org: NOT in the data layer, but still listed by the Tooling API." -ForegroundColor Yellow
                Write-Host "       It is soft-deleted and sitting in Deleted Fields. A destructive" -ForegroundColor Yellow
                Write-Host "       deploy has nothing to remove. Erase it from Setup -> Object Manager" -ForegroundColor Yellow
                Write-Host "       -> $($Definition.SObject) -> Fields & Relationships -> Deleted Fields," -ForegroundColor Yellow
                Write-Host "       or leave it to expire (15 days from the deletion)." -ForegroundColor Yellow
                $Outcome = "Already soft-deleted"
            }
            else {
                Write-Host "  Org: already gone. Nothing to delete." -ForegroundColor Green
                $Outcome = "Already absent"
            }

            Remove-LocalFieldFile -Definition $Definition -RepoRoot $RepoRoot -WhatIf:$WhatIf
            $Summary.Add([PSCustomObject]@{ Field = $Definition.FieldName; Outcome = $Outcome; Backed = "n/a" })
            continue
        }

        Write-Host "  Org: PRESENT. Records with a value: $($State.PopulatedRows)" -ForegroundColor Yellow

        # --- Export before destroying, whenever there is anything to lose -----
        $BackupNote = "no data"
        if ($State.PopulatedRows -gt 0) {
            $BackupFile = Join-Path $BackupDir "$($Definition.FieldName)-$OrgAlias-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
            Write-Host "  Exporting $($State.PopulatedRows) row(s) to $BackupFile" -ForegroundColor Cyan

            $Export = Invoke-SfJson -SfArgs @(
                "data", "export", "bulk",
                "--target-org", $OrgAlias,
                "--result-format", "csv",
                "--wait", "10",
                "--output-file", $BackupFile,
                "--query", $Definition.BackupQuery,
                "--json"
            )

            if ($Export.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $BackupFile)) {
                throw "Backup export FAILED for $($Definition.FieldName). Refusing to delete a populated field without one. sf said: $($Export.Raw)"
            }

            # Never count CSV rows with Get-Content: a rich-text value legally
            # spans physical lines. Import-Csv parses instead.
            $BackedUp = @(Import-Csv -LiteralPath $BackupFile).Count
            Write-Host "  Backup written: $BackedUp row(s)" -ForegroundColor Green
            $BackupNote = "$BackedUp rows -> $(Split-Path -Leaf $BackupFile)"

            if ($BackedUp -lt $State.PopulatedRows) {
                throw "Backup holds $BackedUp row(s) but the org reports $($State.PopulatedRows) populated. Refusing to delete."
            }
        }

        # --- Build the destructive manifest pair -----------------------------
        $ManifestDir = Join-Path $RunDirectory "destructive-$($Definition.Key)"
        if (-not (Test-Path -LiteralPath $ManifestDir)) {
            New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null
        }

        $EmptyPackage = @"
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <version>$ApiVersion</version>
</Package>
"@

        $Destructive = @"
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>$($Definition.SObject).$($Definition.FieldName)</members>
        <name>CustomField</name>
    </types>
    <version>$ApiVersion</version>
</Package>
"@

        $PackagePath = Join-Path $ManifestDir "package.xml"
        $DestructivePath = Join-Path $ManifestDir "destructiveChanges.xml"
        Write-XmlNoBom -Path $PackagePath -Content $EmptyPackage
        Write-XmlNoBom -Path $DestructivePath -Content $Destructive
        Write-Host "  Manifests: $ManifestDir" -ForegroundColor DarkGray

        # --- Dry run: the only thing that reports a blocking reference --------
        # A field delete hard-blocks only on a FORMULA reference. Layouts,
        # permission-set FLS and report-type columns are cascaded away silently,
        # so the dry run is what turns "nothing blocks it" from an assumption
        # into a check - against THIS org, which may hold FCIC or TTS OTCRM
        # references that force-app/ cannot see.
        #
        # --test-level NoTestRun is mandatory, not an optimisation: a
        # pre-existing Apex compile error in GSA_FCIC_AC_Manual_InitialBatch
        # fails any org-wide test run regardless of what is being deployed.
        Push-Location $ProjectDir
        try {
            Write-Host "  Dry run..." -ForegroundColor Cyan
            $DryRun = Invoke-SfJson -SfArgs @(
                "project", "deploy", "start",
                "--manifest", $PackagePath,
                "--post-destructive-changes", $DestructivePath,
                "--target-org", $OrgAlias,
                "--test-level", "NoTestRun",
                "--dry-run",
                "--json"
            )

            if ($DryRun.ExitCode -ne 0) {
                throw "Dry run FAILED for $($Definition.FieldName) - something in '$OrgAlias' references it. Nothing was deleted. sf said: $($DryRun.Raw)"
            }
            Write-Host "  Dry run clean - nothing blocks the delete." -ForegroundColor Green

            if ($WhatIf) {
                Write-Host "  -WhatIf: stopping before the real deploy." -ForegroundColor Yellow
                $Summary.Add([PSCustomObject]@{ Field = $Definition.FieldName; Outcome = "WhatIf - dry run clean"; Backed = $BackupNote })
                Remove-LocalFieldFile -Definition $Definition -RepoRoot $RepoRoot -WhatIf
                continue
            }

            # --- The real delete ---------------------------------------------
            Write-Host "  Deleting..." -ForegroundColor Yellow
            $Deploy = Invoke-SfJson -SfArgs @(
                "project", "deploy", "start",
                "--manifest", $PackagePath,
                "--post-destructive-changes", $DestructivePath,
                "--target-org", $OrgAlias,
                "--test-level", "NoTestRun",
                "--json"
            )

            if ($Deploy.ExitCode -ne 0) {
                throw "Delete FAILED for $($Definition.FieldName). sf said: $($Deploy.Raw)"
            }

            # NEVER trust the status alone. `--metadata-dir` silently ignores a
            # destructive manifest and reports Succeeded having deleted nothing;
            # checking the component count is what catches that class of lie.
            $Deployed = 0
            if ($Deploy.Json -and $Deploy.Json.result) { $Deployed = [int]$Deploy.Json.result.numberComponentsDeployed }
            Write-Host "  numberComponentsDeployed = $Deployed" -ForegroundColor DarkGray
            if ($Deployed -lt 1) {
                throw "Deploy reported success but deployed $Deployed components. The field was NOT deleted."
            }
        }
        finally {
            Pop-Location
        }

        # --- Verify against the org, not against the deploy's own report -----
        $After = Get-FieldState -Definition $Definition -OrgAlias $OrgAlias
        if ($After.Present) {
            throw "Deploy reported success but $($Definition.FieldName) is still queryable in '$OrgAlias'."
        }
        Write-Host "  Verified: SOQL no longer accepts the column." -ForegroundColor Green

        if (-not $KeepLocalFile) {
            Remove-LocalFieldFile -Definition $Definition -RepoRoot $RepoRoot
        }

        $Summary.Add([PSCustomObject]@{ Field = $Definition.FieldName; Outcome = "Deleted"; Backed = $BackupNote })
    }

    Write-Host ""
    Write-Host "--- Summary ($OrgAlias) ---" -ForegroundColor Cyan
    foreach ($Row in $Summary) {
        Write-Host ("  {0,-40} {1,-24} {2}" -f $Row.Field, $Row.Outcome, $Row.Backed)
    }
    Write-Host ""
    Write-Host "A deletion in a SANDBOX is undone by that sandbox's next refresh." -ForegroundColor Yellow
    Write-Host "Only the production delete is permanent. Re-run this after any refresh." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Run directory: $RunDirectory" -ForegroundColor DarkGray
}
finally {
    Stop-ToolLog
}
