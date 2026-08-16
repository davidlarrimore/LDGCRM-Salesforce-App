#Requires -Version 5.1

<#
    SANDBOX FACTORY RESET
    =====================
    Returns a pre-production sandbox to a known starting state: hard-delete
    every record this migration created, then rebuild the Account universe from
    a production export so the org looks like production before a migration
    rehearsal begins.

    "Factory reset" is the deliberate name. This is not a tidy-up - it is the
    single operation that puts an org back to the baseline a rehearsal starts
    from, and it is meant to be run repeatedly. See sfdx-sandbox-ops for the
    safety checklist it follows (target-org verification, preflight counts,
    export-before-write, typed HARD DELETE confirmation).

    ------------------------------------------------------------------
    THIS CANNOT RUN AGAINST PRODUCTION. BY CONSTRUCTION, NOT BY POLICY.
    ------------------------------------------------------------------
    A factory reset has no legitimate production use, so production is not a
    guarded option here - it is not an option at all. Three independent layers,
    each of which alone would stop it:

      1. -Environment does not accept "Prod". The ValidateSet is Dev|QA|Full,
         so PowerShell rejects the argument before a single line of this script
         runs. There is no typed-confirmation path to production, unlike the
         load scripts, which legitimately need one.

      2. The registry entry is checked. If the resolved environment is ever
         marked IsProduction, the script aborts - this catches someone editing
         Common.Orgs.ps1 to point a sandbox key at a production org.

      3. The ORG ITSELF is asked. Organization.IsSandbox is queried from the
         target and the run aborts unless it is true. This is the layer that
         closes the -OrgAlias escape hatch, which deliberately bypasses the
         registry's identity checks and would otherwise be a way to aim this at
         anything at all.

    Layer 3 is the one that matters most: an `sf` alias is a local, mutable
    pointer, so the only trustworthy statement about what an alias points at
    comes from the org on the other end of it.

    ------------------------------------------------------------------
    SCOPE
    ------------------------------------------------------------------
    -ObjectsCsv overrides the default full object list, for scoped resets
    that don't need to touch every migrated object (e.g. re-testing just
    the Account/Partner Account chain without disturbing already-loaded/
    verified Impediment records). Comma-separated (not a real PowerShell
    array parameter) specifically so it survives being passed through a
    nested `powershell -File` invocation intact - that's the only way to get
    a working Read-Host confirmation prompt out of this tool's non-interactive
    host, and array literals/space-separated values don't reliably cross that
    process boundary the way a single comma-joined string does. Order
    matters - list children/junctions before their parents, same as the
    default list, or deletes will fail against Restrict-type
    deleteConstraints (e.g. LDGCRM_application__c.LDGCRM_Partner_Account__c
    blocks deleting a Partner Account any Application still references).

    NOTES ARE HANDLED SEPARATELY, BEFORE THE OBJECT LIST. Every other object is
    scoped by "has LDGCRM_External_ID__c", but ContentNote cannot be - it is a
    Files object that permits no custom fields at all. Worse, deleting a record
    removes its ContentDocumentLinks but leaves the note itself behind as an
    orphan in Files, so ignoring notes would quietly accumulate junk across
    every reset. They are therefore found by walking the links from records that
    DO carry an external ID, and deleted first, while those parents still exist
    to be walked. See Remove-MigratedNotes.

    ------------------------------------------------------------------
    THE ACCOUNT BOOTSTRAP OPTION
    ------------------------------------------------------------------
    Deleting is only half of a rebuild. This script removes every record the
    migration created - which includes the Accounts it tagged with
    LDGCRM_External_ID__c - and the rest of the pipeline then has nothing to
    reconcile against, because Build-AccountReconciliation.ps1 deliberately
    MATCHES existing Accounts rather than creating them (Accounts pre-date the
    migration in production). A cleaned org therefore needs its Account
    universe rebuilt before any other load will do anything useful.

    That rebuild was done by hand on 2026-08-13 (cleanup -> seed -> reconcile),
    and it is the exact sequence a QA rehearsal needs to repeat. So: when an
    export is present in data/prod-accounts/ (.xls, .xlsx or .csv - the format
    is sniffed, the filename is free, the newest wins), this script OFFERS to
    run Invoke-AccountBootstrap.ps1 against the same environment once the
    deletes finish. The bootstrap is hierarchy-aware and takes several passes
    (Account.ParentId is a self-lookup that can only be filled in once the
    parent row exists) - see that script's header.

    ⚠️ DEV AND QA ONLY. In a FULL sandbox, Account is filtered out of the delete
    list above and the bootstrap is never offered: a Full sandbox is a copy of
    production, so its Accounts are the real records the migration reconciles
    onto. See Test-LdgcrmAccountRebuildAllowed in Common.Orgs.ps1.

    The offer is a prompt, not a default. -BootstrapAccounts answers yes up
    front, -SkipBootstrap answers no and suppresses the prompt entirely. The
    bootstrap runs in its own process with its own typed confirmation, so
    approving the cleanup never silently approves a load.

    Note the two halves have deliberately different scopes: this script only
    ever deletes records carrying LDGCRM_External_ID__c, and bootstrapped
    Accounts carry none. Bootstrapped Accounts are therefore NOT removed by a
    later cleanup run - which is what makes the bootstrap safely repeatable
    (it inserts only what's missing, by name).
#>

param(
    # LAYER 1 OF THE PRODUCTION BLOCK: "Prod" is absent on purpose. PowerShell
    # rejects it at bind time, so there is no code path to production at all.
    # Do not add it back - a factory reset has no production use.
    [ValidateSet("Dev", "QA", "Full")]
    [string]$Environment = "Dev",

    # Escape hatch for a sandbox that isn't in the registry. Skips the
    # registry's identity checks (see Assert-LdgcrmOrgTarget) - which is exactly
    # why the Organization.IsSandbox check below is not optional.
    [string]$OrgAlias = "",

    [string]$ObjectsCsv = "",

    # Approve the delete without a prompt, by passing the same token the prompt
    # asks for: -Confirmation "HARD DELETE". Deliberately a token rather than a
    # -Force switch - see Assert-LdgcrmTypedConfirmation for why. Every
    # non-interactive approval is announced and written to the transcript.
    [string]$Confirmation = "",

    # Run the Account bootstrap after the deletes without prompting.
    [switch]$BootstrapAccounts,

    # Never prompt for, and never run, the Account bootstrap.
    [switch]$SkipBootstrap
)

# Children and junctions first, parents last. Getting this order wrong doesn't
# silently skip records - it fails the delete outright against Restrict-type
# deleteConstraints.
$DefaultObjects = @(
    "LDGCRM_Application_Contact__c",
    "LDGCRM_Opportunity_Impediment__c",
    # Added 2026-08-13. It was missing, and its absence was easy to miss because
    # OpportunityContactRole cascades away when its Opportunity is deleted - so
    # a full reset LOOKED complete. A scoped run that doesn't include Opportunity
    # would have left all 515 rows behind, and the next
    # Build-OpportunityContactRoleLoad.ps1 run diffs against what exists, so
    # those survivors would have suppressed the re-insert instead of erroring.
    "OpportunityContactRole",
    "LDGCRM_Application__c",
    "Opportunity",
    "Contact",
    "LDGCRM_Impediment__c",
    "LDGCRM_Partner_account__c",
    "Account",
    # LAST, and it has to be last. Account, Opportunity, LDGCRM_application__c and
    # LDGCRM_Partner_Account__c all carry a lookup TO Market Segment, so it is the
    # parent - children go first.
    #
    # Included as of 2026-08-14. It used to be excluded on the grounds that
    # "nothing in the migration recreates them", which was true and was itself the
    # bug: Market Segment was the one object the pipeline required but refused to
    # load. Build-MarketSegmentLoad.ps1 is now step 1 of the load, so a reset that
    # left the segments behind would no longer be returning the org to a baseline.
    #
    # ⚠️ ALL FOUR REFERENCING LOOKUPS ARE SetNull, NOT Restrict. Deleting a
    # segment does not fail - it silently blanks the lookup on anything still
    # pointing at it. Tagged records are being deleted anyway, so the only
    # lasting casualties are UNTAGGED records pointing at a TAGGED segment.
    # Measured end-to-end in Dev on 2026-08-14 (delete, then reload both steps):
    # Accounts holding a segment went 586 -> 585. One untagged Account lost its
    # segment permanently, because reconciliation only re-touches Accounts that
    # match an Airtable row. Small, but it does not come back - so a reset is not
    # perfectly reversible for untagged records, which is true of the Account
    # pre-image too.
    "LDGCRM_Market_Segment__c"
)

$Objects = if ($ObjectsCsv) { $ObjectsCsv -split "," | ForEach-Object { $_.Trim() } } else { $DefaultObjects }

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

if ($BootstrapAccounts -and $SkipBootstrap) {
    throw "-BootstrapAccounts and -SkipBootstrap are mutually exclusive."
}

# ============================================================
# ACCOUNT IS PROTECTED IN A FULL SANDBOX
# ============================================================
# A Full sandbox is a COPY OF PRODUCTION, so its Accounts are the real records
# the migration reconciles onto - not something a previous rehearsal created.
# Everything else in the object list carries LDGCRM_External_ID__c because THIS
# MIGRATION made it, so resetting those is exactly right; Account is the one
# object where "has an external ID" means "a real Account that a previous run
# tagged", and hard-deleting it would destroy production data in the org that
# exists to prove the migration works against production data.
#
# Filtered rather than branching $DefaultObjects, so it applies to an explicit
# -ObjectsCsv too. Removing it silently would be worse than not removing it: an
# operator who asked for Account and got a clean run would reasonably conclude
# the Accounts were reset.
#
# The DECISION is taken here, but it is ANNOUNCED after the transcript opens
# (below). A message this consequential belongs in the audit trail, and anything
# written before Start-ScriptLog goes to the console only - which is the one
# place nobody looks when reconstructing what a reset did three weeks later.
$Requested = @($Objects)
$Objects = @(Select-LdgcrmResettableObjects -Environment $Environment -Objects $Requested)
$AccountProtected = ($Requested.Count -ne $Objects.Count)

# ============================================================
# CONFIGURATION
# ============================================================

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias
$ApiVersion = "67.0"
$ExternalIdField = "LDGCRM_External_ID__c"
$WaitMinutes = 30

$Timestamp = Start-ScriptLog -Category "cleanup" -ScriptName "Invoke-SandboxFactoryReset"
# The run directory itself - see Common.ps1's "one directory per run". This
# is the ONLY record of what a hard delete removed, so it must sit beside this
# run's transcript rather than in a folder of its own.
$OutputDirectory = Get-LogDirectory -Category "cleanup"

if ($AccountProtected) {
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " ACCOUNT EXCLUDED - '$Environment' holds real Account data" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  Accounts here are production records the migration reconciles"
    Write-Host "  ONTO, not records it created. They are never deleted or rebuilt,"
    Write-Host "  and the Account bootstrap will not be offered."
    Write-Host "  Every other object still resets normally."
    Write-Host "  (See Test-LdgcrmAccountRebuildAllowed in powershell-scripts/Common.Orgs.ps1.)"
    Write-Host ""
}

# ============================================================
# FUNCTIONS
# ============================================================

function Invoke-SalesforceCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "sf $($Arguments -join ' ')" -ForegroundColor DarkGray

    & sf @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Salesforce CLI command failed with exit code $LASTEXITCODE."
    }
}

function Get-MatchingRecordCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectApiName
    )

    $Soql = "SELECT COUNT() FROM $ObjectApiName WHERE $ExternalIdField != null"

    $RawResult = & sf data query `
        --target-org $OrgAlias `
        --api-version $ApiVersion `
        --query $Soql `
        --json

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query $ObjectApiName."
    }

    $JsonResult = $RawResult | ConvertFrom-Json

    if ($JsonResult.status -ne 0) {
        $ErrorMessage = $JsonResult.message

        if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $ErrorMessage = "Unknown Salesforce CLI error."
        }

        throw $ErrorMessage
    }

    return [int]$JsonResult.result.totalSize
}

function Export-RecordIds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectApiName,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile
    )

    $Soql = "SELECT Id FROM $ObjectApiName WHERE $ExternalIdField != null"

    Invoke-SalesforceCli -Arguments @(
        "data", "export", "bulk",
        "--target-org", $OrgAlias,
        "--api-version", $ApiVersion,
        "--query", $Soql,
        "--output-file", $OutputFile,
        "--result-format", "csv",
        "--wait", $WaitMinutes.ToString()
    )
}

function Test-DeleteFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CsvFile
    )

    if (-not (Test-Path -LiteralPath $CsvFile)) {
        throw "The expected CSV file was not created: $CsvFile"
    }

    $Rows = @(Import-Csv -LiteralPath $CsvFile)

    if ($Rows.Count -eq 0) {
        return 0
    }

    $Columns = @($Rows[0].PSObject.Properties.Name)

    if ($Columns.Count -ne 1 -or $Columns[0] -ne "Id") {
        throw "The CSV must contain exactly one column named Id."
    }

    foreach ($Row in $Rows) {
        if ([string]::IsNullOrWhiteSpace($Row.Id)) {
            throw "The CSV contains an empty record ID."
        }
    }

    return $Rows.Count
}

function Get-MigratedNoteDocumentIds {
    <#
        Finds the ContentNotes this migration created, by walking
        ContentDocumentLink from the records that carry an external ID.

        WHY IT CANNOT USE THE EXTERNAL-ID FILTER LIKE EVERYTHING ELSE:
        ContentNote is a Files object and permits NO custom fields at all, so
        there is nothing on the note itself to identify it by. The only durable
        statement about a migrated note is "it is attached to a record the
        migration tagged".

        WHY IT MUST RUN BEFORE THE PARENTS ARE DELETED: deleting a record
        removes its ContentDocumentLinks but leaves the ContentDocument behind,
        orphaned in Files and now unreachable by this query. Skip this and every
        reset silently accumulates junk notes that nothing can find again.

        Scoped to FileType 'SNOTE' so genuine uploaded files attached to the
        same records are never touched.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ParentObjects
    )

    $DocumentIds = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($ObjectApiName in $ParentObjects) {
        $ParentIds = @()

        try {
            $ParentIds = @(Invoke-SalesforceQuery `
                -Soql "SELECT Id FROM $ObjectApiName WHERE $ExternalIdField != null" `
                -OrgAlias $OrgAlias -ApiVersion $ApiVersion | ForEach-Object { $_.Id })
        }
        catch {
            # An object with no external ID field (or no access) simply can't
            # hold migrated notes - not an error worth stopping a reset for.
            continue
        }

        for ($Offset = 0; $Offset -lt $ParentIds.Count; $Offset += 200) {
            $Last = [Math]::Min($Offset + 200, $ParentIds.Count) - 1
            $Literals = (@($ParentIds[$Offset..$Last]) | ForEach-Object { "'$_'" }) -join ","

            foreach ($Link in @(Invoke-SalesforceQuery `
                    -Soql ("SELECT ContentDocumentId FROM ContentDocumentLink " +
                           "WHERE LinkedEntityId IN ($Literals) " +
                           "AND ContentDocument.FileType = 'SNOTE'") `
                    -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
                if ($Link.ContentDocumentId) { $DocumentIds.Add($Link.ContentDocumentId) | Out-Null }
            }
        }
    }

    return $DocumentIds
}

function Remove-Records {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectApiName,

        [Parameter(Mandatory = $true)]
        [string]$CsvFile
    )

    Invoke-SalesforceCli -Arguments @(
        "data", "delete", "bulk",
        "--target-org", $OrgAlias,
        "--api-version", $ApiVersion,
        "--sobject", $ObjectApiName,
        "--file", $CsvFile,
        "--hard-delete",
        "--wait", $WaitMinutes.ToString()
    )
}

function Invoke-AccountBootstrapStep {
    <#
        Offers, then runs, the Account bootstrap.

        Run as a CHILD PROCESS rather than dot-sourced, for two reasons: the
        bootstrap has its own typed confirmation (which needs a real console,
        the same reason this script is itself run via `powershell -File`), and
        a failure there must not take down this script's own transcript and
        summary. Its exit code is reported, not swallowed.
    #>
    param(
        [string]$Env,
        [string]$Alias,
        [bool]$AlreadyAnswered,
        [bool]$Suppressed,

        # When this reset was itself approved non-interactively, the child gets
        # its own token too - otherwise an automated reset deletes everything
        # and then stalls on the bootstrap's prompt, which is the worst possible
        # place to stop.
        [bool]$NonInteractive
    )

    if ($Suppressed) {
        return "Skipped (-SkipBootstrap)"
    }

    # Not offered at all where Accounts are real - see the ACCOUNT IS PROTECTED
    # block above. Checked here as well as there because the two halves are
    # independent: the delete list and the rebuild offer could otherwise
    # disagree, and "deleted nothing but rebuilt anyway" is the worse half.
    if (-not (Test-LdgcrmAccountRebuildAllowed -Environment $Env)) {
        Write-Host ""
        Write-Host "Account bootstrap not offered - '$Env' holds real Account data." -ForegroundColor DarkGray
        return "Not offered ($Env keeps its real Accounts)"
    }

    $ExportPath = Resolve-ProdAccountExportPath -Report

    if (-not $ExportPath) {
        Write-Host ""
        Write-Host "No production Account export found - skipping the bootstrap offer." -ForegroundColor DarkGray
        Write-Host "(Drop an .xls/.xlsx/.csv export of the PEO Accounts report in" -ForegroundColor DarkGray
        Write-Host " $(Get-ProdAccountExportDirectory))" -ForegroundColor DarkGray
        return "Not offered (no export file)"
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " OPTIONAL: BOOTSTRAP THE ACCOUNT TREE" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "A production Account export is available:"
    Write-Host "  $ExportPath"
    Write-Host ""
    Write-Host "Rebuilds Account names and the parent hierarchy from that export."
    Write-Host "The later loads reconcile onto existing Accounts; without this there"
    Write-Host "are none to attach to."
    Write-Host ""

    if (-not $AlreadyAnswered) {
        # -BootstrapAccounts / -SkipBootstrap already answer this without a
        # prompt. This branch only runs when neither was passed, so a host that
        # cannot prompt is told which flag to use rather than crashing on
        # Read-Host - a half-finished factory reset (deleted, not rebuilt) is a
        # worse place to stop than not starting.
        try {
            $Answer = Read-Host "Run the Account bootstrap against $Alias now? (y/N)"
        }
        catch {
            Write-Host ""
            Write-Host "This host cannot prompt, and neither -BootstrapAccounts nor -SkipBootstrap" -ForegroundColor Yellow
            Write-Host "was passed. The records are deleted but the Account tree was NOT rebuilt." -ForegroundColor Yellow
            Write-Host "Finish the reset with:" -ForegroundColor Yellow
            Write-Host "  .\powershell-scripts\Invoke-AccountBootstrap.ps1 -Environment $Env -Confirmation BOOTSTRAP" -ForegroundColor DarkGray
            return "Not offered (host cannot prompt; pass -BootstrapAccounts)"
        }

        if ($Answer -notmatch '^(y|yes)$') {
            Write-Host ""
            Write-Host "Bootstrap skipped. Run it later with:" -ForegroundColor Yellow
            Write-Host "  .\powershell-scripts\Invoke-AccountBootstrap.ps1 -Environment $Env" -ForegroundColor Yellow
            return "Declined at the prompt"
        }
    }

    $BootstrapScript = Join-Path $PSScriptRoot "Invoke-AccountBootstrap.ps1"

    if (-not (Test-Path -LiteralPath $BootstrapScript)) {
        Write-Host "Bootstrap script not found: $BootstrapScript" -ForegroundColor Red
        return "FAILED (script not found)"
    }

    Write-Host ""
    Write-Host "Handing off to Invoke-AccountBootstrap.ps1..." -ForegroundColor Cyan

    if ($NonInteractive) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $BootstrapScript -Environment $Env -Confirmation BOOTSTRAP
    }
    else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $BootstrapScript -Environment $Env
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "The Account bootstrap exited with code $LASTEXITCODE - review its transcript in logs/data-migration/." -ForegroundColor Red
        return "FAILED (exit $LASTEXITCODE)"
    }

    return "Completed"
}

# ============================================================
# START
# ============================================================

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " SANDBOX FACTORY RESET" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Confirm that Salesforce CLI is installed.
Invoke-SalesforceCli -Arguments @("--version")

# Verify the alias still points at the org the registry says it does, BEFORE
# counting anything. This replaces the old "print `sf org display` and hope the
# operator reads it" check - a repointed alias now stops the run outright.
$OrgInfo = Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias

# ============================================================
# PRODUCTION BLOCK - LAYERS 2 AND 3
# ============================================================
# Layer 1 (the ValidateSet on -Environment) already ran at bind time. These two
# cover what it cannot: a registry edited to point a sandbox key somewhere else,
# and the -OrgAlias override, which deliberately skips the registry entirely.
#
# Both abort rather than prompt. There is no typed confirmation for production
# here on purpose - a factory reset against production is never the intent, so
# offering a way to approve it would only create a way to approve it by mistake.

# Layer 2: the registry's own opinion of this environment.
$EnvironmentEntry = Get-LdgcrmEnvironment -Environment $Environment
if ($EnvironmentEntry.IsProduction) {
    throw ("SAFETY STOP: environment '$Environment' is marked IsProduction in " +
           "powershell-scripts/Common.Orgs.ps1. A Sandbox Factory Reset must never run against " +
           "production. Nothing was read or deleted.")
}

# Layer 3: ask the ORG, not the alias. Assert-LdgcrmOrgTarget already queried
# Organization.IsSandbox and attached it, which is authoritative in a way no
# local config can be - an alias is a mutable pointer, the org is not.
if (-not $OrgInfo.isSandbox) {
    throw ("SAFETY STOP: alias '$OrgAlias' resolves to a NON-SANDBOX org " +
           "($($OrgInfo.orgName), $($OrgInfo.instanceUrl)). A Sandbox Factory Reset only runs " +
           "against pre-production sandboxes. Nothing was read or deleted.")
}

Write-Host ""
Write-Host "Production block: PASSED - target is a sandbox ($($OrgInfo.orgName))." -ForegroundColor Green

Write-Host "API version:       $ApiVersion"
Write-Host "External ID field: $ExternalIdField"
Write-Host "Delete mode:       HARD DELETE" -ForegroundColor Red
Write-Host ""
Write-Host "Only records with $ExternalIdField populated are deleted."
Write-Host "Objects, in order: $($Objects -join ' -> ')"
Write-Host ""

# ============================================================
# PREFLIGHT RECORD COUNTS
# ============================================================

Write-Host "Counting records selected for deletion..." -ForegroundColor Cyan
Write-Host ""

$Counts = [ordered]@{}
$TotalRecords = 0

foreach ($ObjectApiName in $Objects) {
    try {
        $Count = Get-MatchingRecordCount -ObjectApiName $ObjectApiName

        $Counts[$ObjectApiName] = $Count
        $TotalRecords += $Count

        Write-Host ("{0,-35} {1,12:N0}" -f $ObjectApiName, $Count)
    }
    catch {
        Write-Host ""
        Write-Host "PRE-FLIGHT CHECK FAILED" -ForegroundColor Red
        Write-Host "Object: $ObjectApiName" -ForegroundColor Red
        Write-Host "Error:  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Confirm that:" -ForegroundColor Yellow
        Write-Host "  1. The object API name is correct."
        Write-Host "  2. $ExternalIdField exists on the object."
        Write-Host "  3. Your Salesforce user can read and delete the records."
        exit 1
    }
}

# Notes are counted here rather than in the loop above because they aren't
# selected the same way - see Get-MigratedNoteDocumentIds. This must happen
# while the parent records still exist to be walked.
Write-Host ""
Write-Host "Finding migrated notes (walked from their parent records)..." -ForegroundColor Cyan
$NoteDocumentIds = Get-MigratedNoteDocumentIds -ParentObjects $Objects
Write-Host ("{0,-35} {1,12:N0}" -f "ContentNote (migrated)", $NoteDocumentIds.Count)

Write-Host ""
Write-Host "Total records selected: $(($TotalRecords + $NoteDocumentIds.Count).ToString('N0'))" `
    -ForegroundColor Yellow

$Results = @()

if ($TotalRecords -eq 0) {
    Write-Host ""
    Write-Host "No matching records were found. Nothing was deleted." `
        -ForegroundColor Green

    # Deliberately NOT an early exit any more. An org with nothing to delete is
    # the normal state of a freshly-refreshed QA/Full sandbox, and that is
    # precisely when the Account bootstrap is most needed - exiting here would
    # have made the combined "reset this org" workflow impossible to run in one
    # go.
    $BootstrapStatus = Invoke-AccountBootstrapStep `
        -Env $Environment `
        -Alias $OrgAlias `
        -AlreadyAnswered ([bool]$BootstrapAccounts) `
        -Suppressed ([bool]$SkipBootstrap) `
        -NonInteractive ([bool]$Confirmation)

    Write-Host ""
    Write-Host "Account bootstrap: $BootstrapStatus" -ForegroundColor Cyan
    exit 0
}

# ============================================================
# ONE CONFIRMATION
# ============================================================

Write-Host ""
Write-Host "WARNING" -ForegroundColor Red
Write-Host "These records will be permanently deleted from $OrgAlias." `
    -ForegroundColor Red
Write-Host "They will not be placed in the Recycle Bin." `
    -ForegroundColor Red
Write-Host ""

# NOTE: there is deliberately no Assert-LdgcrmProductionConsent call here, and
# its absence is not an oversight. That helper exists to let an operator APPROVE
# a production write; this script cannot target production at all (see the three
# layers at the top), so calling it would be dead code that implies a production
# path exists. The typed confirmation below is the only gate, and it guards a
# sandbox.
if (-not (Assert-LdgcrmTypedConfirmation `
        -Token "HARD DELETE" `
        -Provided $Confirmation `
        -Action ("HARD DELETE $(($TotalRecords + $NoteDocumentIds.Count).ToString('N0')) migrated record(s) from $OrgAlias"))) {
    Write-Host ""
    Write-Host "Factory reset cancelled. No records were deleted." `
        -ForegroundColor Yellow
    exit 0
}

# ============================================================
# CREATE RUN DIRECTORY
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $OutputDirectory `
    -Force | Out-Null

Write-Host ""
Write-Host "Output directory:" -ForegroundColor Cyan
Write-Host $OutputDirectory

# ============================================================
# DELETE MIGRATED NOTES - FIRST, WHILE THEIR PARENTS STILL EXIST
# ============================================================
# Order is load-bearing. Once a parent record is deleted its ContentDocumentLink
# goes with it, and the note becomes an unreachable orphan in Files. The ids
# were collected during preflight for exactly this reason.

if ($NoteDocumentIds.Count -gt 0) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Processing migrated notes (ContentDocument)" -ForegroundColor Cyan
    Write-Host "============================================================"

    # Export-DataLoaderCsv, NOT Export-Csv: this file is fed straight back to
    # the Bulk API, and PowerShell 5.1's Export-Csv -Encoding UTF8 always writes
    # a BOM. Bulk API reads the BOM bytes as the start of an unquoted first
    # field, hits the opening quote of "Id" and fails the whole job with
    #   InvalidBatch : Failed to parse CSV. Found unescaped quote.
    # - an error that says nothing about encoding. Cost a failed reset run on
    # 2026-08-13, the first time this path ever had a note to delete.
    #
    # Every OTHER object's delete file is written by `sf data export bulk`,
    # which emits no BOM, so this is the one hand-built CSV in the script and
    # the only place the trap could bite. The summary CSVs below are read by
    # humans in Excel, where the BOM is harmless and actually helps.
    $NoteIdFile = Join-Path $OutputDirectory "ContentDocument-ids.csv"
    Export-DataLoaderCsv `
        -InputObject @($NoteDocumentIds | ForEach-Object { [PSCustomObject]@{ Id = $_ } }) `
        -Path $NoteIdFile

    Write-Host "Exported $($NoteDocumentIds.Count) note id(s) for the audit trail:"
    Write-Host "  $NoteIdFile"

    # Deleting the ContentDocument removes the note and its links together.
    # Deleting ContentNote directly is not the equivalent operation.
    Remove-Records -ObjectApiName "ContentDocument" -CsvFile $NoteIdFile

    # SHAPE MUST MATCH the per-object results added below. Format-Table builds
    # its columns from the FIRST object it sees, and this one is first - so a
    # different property set here renders every later row's counts as BLANK
    # while the totals underneath stay correct. That is exactly what the
    # 2026-08-13 reload printed: "Deleted 537" for notes and empty cells for all
    # nine objects, against a real total of 6,335.
    $Results += [PSCustomObject]@{
        Object         = "ContentDocument (notes)"
        PreflightCount = $NoteDocumentIds.Count
        ExportedCount  = $NoteDocumentIds.Count
        Status         = "Completed"
    }
}

# ============================================================
# EXPORT AND DELETE
# ============================================================

foreach ($ObjectApiName in $Objects) {
    $ExpectedCount = $Counts[$ObjectApiName]

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Processing $ObjectApiName" -ForegroundColor Cyan
    Write-Host "============================================================"

    if ($ExpectedCount -eq 0) {
        Write-Host "No matching records. Skipped." -ForegroundColor DarkGray

        $Results += [PSCustomObject]@{
            Object        = $ObjectApiName
            PreflightCount = 0
            ExportedCount = 0
            Status        = "Skipped"
        }

        continue
    }

    $CsvFile = Join-Path $OutputDirectory "$ObjectApiName.csv"

    try {
        Write-Host ""
        Write-Host "Exporting record IDs..." -ForegroundColor Cyan

        Export-RecordIds `
            -ObjectApiName $ObjectApiName `
            -OutputFile $CsvFile

        $ExportedCount = Test-DeleteFile -CsvFile $CsvFile

        Write-Host ""
        Write-Host "Exported IDs: $($ExportedCount.ToString('N0'))"

        if ($ExportedCount -eq 0) {
            Write-Host "No IDs were exported. Delete skipped." `
                -ForegroundColor Yellow

            $Results += [PSCustomObject]@{
                Object         = $ObjectApiName
                PreflightCount = $ExpectedCount
                ExportedCount  = 0
                Status         = "No exported records"
            }

            continue
        }

        if ($ExportedCount -ne $ExpectedCount) {
            Write-Host ""
            Write-Host "Notice: the current export count differs from the preflight count." `
                -ForegroundColor Yellow
            Write-Host "Preflight count: $ExpectedCount"
            Write-Host "Export count:    $ExportedCount"
            Write-Host "The script will delete only the IDs in the exported CSV." `
                -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "Hard deleting $($ExportedCount.ToString('N0')) records..." `
            -ForegroundColor Yellow

        Remove-Records `
            -ObjectApiName $ObjectApiName `
            -CsvFile $CsvFile

        Write-Host ""
        Write-Host "$ObjectApiName completed successfully." `
            -ForegroundColor Green

        $Results += [PSCustomObject]@{
            Object         = $ObjectApiName
            PreflightCount = $ExpectedCount
            ExportedCount  = $ExportedCount
            Status         = "Completed"
        }
    }
    catch {
        Write-Host ""
        Write-Host "DELETE FAILED" -ForegroundColor Red
        Write-Host "Object: $ObjectApiName" -ForegroundColor Red
        Write-Host "Error:  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Stopped. Parent objects were not processed." -ForegroundColor Yellow
        Write-Host "The Account bootstrap was not offered." -ForegroundColor Yellow

        $Results += [PSCustomObject]@{
            Object         = $ObjectApiName
            PreflightCount = $ExpectedCount
            ExportedCount  = 0
            Status         = "FAILED"
        }

        $PartialSummaryFile = Join-Path `
            $OutputDirectory `
            "cleanup-summary.csv"

        $Results |
            Export-Csv `
                -LiteralPath $PartialSummaryFile `
                -NoTypeInformation `
                -Encoding UTF8

        Write-Host ""
        Write-Host "Partial summary:" -ForegroundColor Cyan
        Write-Host $PartialSummaryFile

        exit 1
    }
}

# ============================================================
# FINAL SUMMARY
# ============================================================

$SummaryFile = Join-Path $OutputDirectory "cleanup-summary.csv"

$Results |
    Export-Csv `
        -LiteralPath $SummaryFile `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " CLEANUP COMPLETED" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

$Results | Format-Table -AutoSize

Write-Host ""
Write-Host "Summary file:" -ForegroundColor Cyan
Write-Host $SummaryFile
Write-Host ""
Write-Host "Exported ID files:" -ForegroundColor Cyan
Write-Host $OutputDirectory

# ============================================================
# OPTIONAL ACCOUNT BOOTSTRAP
# ============================================================

$BootstrapStatus = Invoke-AccountBootstrapStep `
    -Env $Environment `
    -Alias $OrgAlias `
    -AlreadyAnswered ([bool]$BootstrapAccounts) `
    -Suppressed ([bool]$SkipBootstrap) `
    -NonInteractive ([bool]$Confirmation)

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " DONE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Environment:       $Environment ($OrgAlias)"
Write-Host "Records deleted:   $(($Results | Where-Object { $_.Status -eq 'Completed' } | Measure-Object -Property ExportedCount -Sum).Sum)"
Write-Host "Account bootstrap: $BootstrapStatus"

}
finally {
    Stop-ScriptLog
}

