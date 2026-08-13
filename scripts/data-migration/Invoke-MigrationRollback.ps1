#Requires -Version 5.1

<#
    MIGRATION ROLLBACK
    ==================
    Undoes ONE run of Invoke-FullMigrationLoad.ps1, using the restore point that
    run captured before it wrote anything.

    READ THIS BEFORE RELYING ON IT
      This is a best-effort tidy-up, NOT a safety net. The actual safety net for
      a production migration is a backup taken immediately before the run and a
      rehearsed restore path. Do not let the existence of this script justify
      skipping that. Everything it cannot do is listed under "LIMITS" below, and
      those limits are properties of Salesforce, not gaps in the implementation.

    THE ASYMMETRY THAT SHAPES THE WHOLE DESIGN
      Undoing an INSERT is easy - delete by external ID. Undoing an UPDATE is
      not. This pipeline does both: it CREATES most objects, but it UPDATES
      Accounts it does not own (Build-AccountReconciliation.ps1 writes
      LDGCRM_External_ID__c, Type and Market Segment onto Accounts that pre-date
      the migration by years; Invoke-AccountBootstrap.ps1 fills in ParentId).

      Deleting a migrated record does not restore an updated one. So this script
      does two different things to two different populations:

        created by the run  -> DELETED
        updated by the run  -> RESTORED from the pre-image, never deleted

    HOW IT KNOWS WHICH IS WHICH
      Not from the load CSVs. Those say what was PLANNED, they can be
      overwritten by any later transform run, and they cannot distinguish a row
      that was inserted from one that was already present and got updated.

      Instead it uses the run's own external-ID capture:

        created = (external IDs tagged in the org NOW)
                - (external IDs tagged BEFORE the run, per external-ids/)

      That is measured reality on both sides. In a sandbox the two definitions
      usually agree; in production they do not, and the difference is the whole
      point - a second production run must not delete the first run's records.

      A run directory with no external-ids/ folder is REFUSED rather than
      treated as "nothing was tagged before". Missing data reads as unknown, and
      unknown must never authorise a delete.

    LIMITS - state these before anyone relies on this script
      - HARD DELETES ARE IRREVERSIBLE. This deletes; it cannot resurrect.
        Anything Invoke-SandboxFactoryReset.ps1 removed is gone short of
        Salesforce's paid Data Recovery service.
      - IT CLOBBERS POST-LOAD HUMAN EDITS. Restoring the Account pre-image
        overwrites whatever anyone changed since. Rollback has a SHELF LIFE: it
        is safe in the minutes after a load and increasingly destructive once
        users touch the data. That window, not this script, is the real
        constraint.
      - CASCADES DELETE MORE THAN THE RUN CREATED. Master-Detail children go
        with their parent - deleting an Application takes its
        LDGCRM_Application_Contact__c rows, including any that pre-dated the run.
      - FLOWS, TRIGGERS AND ROLL-UPS FIRE ON THE WAY BACK OUT, including the
        FCIC and PureCloud automation this repo does not control.
      - IT IS SCOPED TO A BASELINE, NOT TO A RUN ID. If another load ran after
        the one being rolled back, that load's records are newer than this
        baseline too and WILL be deleted. The drift check below detects this and
        stops; -IgnoreDrift overrides it, deliberately awkwardly.
#>

param(
    # The full-load-<timestamp> directory written by Invoke-FullMigrationLoad.ps1.
    # This is what scopes the rollback - the script undoes that run, not "the
    # migration" in general.
    [Parameter(Mandatory = $true)]
    [string]$RunDirectory,

    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (scripts/common/Common.Orgs.ps1).
    [string]$OrgAlias = "",

    [string]$ApiVersion = "67.0",
    [int]$WaitMinutes = 30,

    # Approve without a prompt: -Confirmation "ROLLBACK". Its own token, not
    # "LOAD" and not "HARD DELETE" - so an approval for a load can never be
    # copy-pasted into a rollback, or the reverse.
    [string]$Confirmation = "",

    # Required IN ADDITION to -Confirmation when -Environment Prod. Never bake
    # this into a saved script or a CI variable.
    [string]$ProductionConfirmation = "",

    # Report the full plan and write nothing. ALWAYS run this first.
    [switch]$PlanOnly,

    # created-note-ids.csv from the Notes step. Auto-discovered from the
    # notes-load-* directory belonging to this run if not given.
    [string]$NoteIdFile = "",

    # Skip restoring the Account pre-image (delete-only rollback).
    [switch]$SkipAccountRestore,

    # Proceed even though the org no longer matches the run's post-load counts.
    # See the drift check - this means you are rolling back more than one run.
    [switch]$IgnoreDrift
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Invoke-MigrationRollback"

# Reverse of the load order in Invoke-FullMigrationLoad.ps1, and the same order
# Invoke-SandboxFactoryReset.ps1 deletes in: children and junctions before their
# parents, so a Master-Detail parent is never removed while a child still needs
# it.
#
# Account is absent ON PURPOSE. The migration never creates an Account - it
# matches and updates ones that already exist - so there is nothing on that
# object a rollback may delete. It is restored from the pre-image instead.
#
# LDGCRM_Market_Segment__c is absent for the same reason as in the factory
# reset: the migration does not create or modify it.
$DeleteOrder = @(
    "LDGCRM_Application_Contact__c",
    "LDGCRM_Opportunity_Impediment__c",
    "OpportunityContactRole",
    "LDGCRM_application__c",
    "Opportunity",
    "Contact",
    "LDGCRM_Impediment__c",
    "LDGCRM_Partner_Account__c"
)

# Fields Build-AccountReconciliation.ps1 and Invoke-AccountBootstrap.ps1
# overwrite on Accounts that already existed. These are exactly what the
# pre-image captured, and the only Account fields this script restores.
$AccountRestoreFields = @("LDGCRM_External_ID__c", "Type", "OwnerId", "LDGCRM_Market_Segment__c")

function Invoke-SalesforceCli {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    Write-Host ""
    Write-Host "sf $($Arguments -join ' ')" -ForegroundColor DarkGray

    & sf @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Salesforce CLI command failed with exit code $LASTEXITCODE."
    }
}

function Get-CreatedExternalIds {
    <#
        The set difference that defines "this run created it".

        Returns the external IDs currently tagged in the org that were NOT
        tagged before the run. Anything present in both was already there and
        must be left alone - in a sandbox that set is usually empty, in
        production it is the previous migration run.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ObjectApiName,
        [Parameter(Mandatory = $true)][string]$BaselineFile
    )

    # HashSet, not -contains against an array: Contact and the junctions run to
    # thousands of rows, and -contains inside a loop is O(n*m). This was a
    # measurable difference on LDGCRM_Application_Contact__c's 1,880 rows.
    $Before = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)

    if (Test-Path -LiteralPath $BaselineFile) {
        foreach ($Row in @(Import-Csv -LiteralPath $BaselineFile)) {
            if ($Row.LDGCRM_External_ID__c) { [void]$Before.Add($Row.LDGCRM_External_ID__c) }
        }
    }

    $Now = @(Invoke-SalesforceQuery `
        -Soql "SELECT Id, LDGCRM_External_ID__c FROM $ObjectApiName WHERE LDGCRM_External_ID__c != null" `
        -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

    $Created = @($Now | Where-Object { -not $Before.Contains($_.LDGCRM_External_ID__c) })

    return [PSCustomObject]@{
        Object       = $ObjectApiName
        TaggedBefore = $Before.Count
        TaggedNow    = $Now.Count
        Created      = $Created
    }
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " MIGRATION ROLLBACK" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$OrgInfo = Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias

# --- validate the run directory --------------------------------------------
# Everything below depends on the restore point being complete. A partial one is
# worse than none: it looks authoritative and silently authorises the wrong
# deletes.

if (-not (Test-Path -LiteralPath $RunDirectory)) {
    throw "Run directory not found: $RunDirectory"
}

$RunDirectory = (Resolve-Path -LiteralPath $RunDirectory).Path
$ExternalIdDirectory = Join-Path $RunDirectory "external-ids"
$AccountPreImageFile = Join-Path $RunDirectory "restore-point-Account.csv"
$PostLoadCountsFile = Join-Path $RunDirectory "post-load-counts.csv"

Write-Host ""
Write-Host "Run directory: $RunDirectory"

if (-not (Test-Path -LiteralPath $ExternalIdDirectory)) {
    throw ("This run directory has no external-ids\ folder, so there is no record of which " +
           "records existed BEFORE the run. Without it a rollback cannot tell what the run " +
           "created from what was already there, and deleting on that basis could remove " +
           "records an earlier migration loaded. Refusing to continue. " +
           "(Run directories written before 2026-08-13 predate this capture.)")
}

if (-not (Test-Path -LiteralPath $AccountPreImageFile)) {
    throw "Missing restore-point-Account.csv in $RunDirectory - the Account pre-image is not optional."
}

Write-Host "Restore point is complete (external-ids\ + Account pre-image present)." -ForegroundColor Green

# --- drift check ------------------------------------------------------------
# Rollback is scoped by a baseline, not by a run id, so anything loaded AFTER
# the run being rolled back also looks "created since the baseline". Comparing
# today's totals against the run's own post-load counts is what catches that.
if ((Test-Path -LiteralPath $PostLoadCountsFile) -and -not $PlanOnly) {
    Write-Host ""
    Write-Host "Checking the org still matches this run's post-load state..." -ForegroundColor Cyan

    $Drift = [System.Collections.Generic.List[string]]::new()

    foreach ($Row in @(Import-Csv -LiteralPath $PostLoadCountsFile)) {
        $Current = @(Invoke-SalesforceQuery -Soql "SELECT Id FROM $($Row.Object)" `
            -OrgAlias $OrgAlias -ApiVersion $ApiVersion).Count

        if ($Current -ne [int]$Row.After) {
            $Drift.Add(("{0}: {1} at end of run, {2} now" -f $Row.Object, $Row.After, $Current))
        }
    }

    if ($Drift.Count -gt 0) {
        Write-Host ""
        Write-Host "THE ORG HAS CHANGED SINCE THIS RUN FINISHED:" -ForegroundColor Red
        foreach ($Item in $Drift) { Write-Host "  - $Item" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Rollback is scoped to everything tagged since this run's baseline, so anything" -ForegroundColor Yellow
        Write-Host "loaded AFTER it would be deleted too, and any record edited since would be" -ForegroundColor Yellow
        Write-Host "restored over. Re-run with -IgnoreDrift only if you intend exactly that." -ForegroundColor Yellow

        if (-not $IgnoreDrift) { exit 1 }

        Write-Host ""
        Write-Host "-IgnoreDrift supplied: continuing anyway." -ForegroundColor Yellow
    }
    else {
        Write-Host "  No drift - the org matches this run's post-load counts." -ForegroundColor Green
    }
}

# --- work out what this run created ----------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " WHAT THIS RUN CREATED" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  {0,-34} {1,8} {2,8} {3,8}" -f "OBJECT", "BEFORE", "NOW", "CREATED")

$Plan = [System.Collections.Generic.List[object]]::new()
$TotalToDelete = 0

foreach ($ObjectApiName in $DeleteOrder) {
    $BaselineFile = Join-Path $ExternalIdDirectory "$ObjectApiName.csv"
    $Result = Get-CreatedExternalIds -ObjectApiName $ObjectApiName -BaselineFile $BaselineFile

    Write-Host ("  {0,-34} {1,8:N0} {2,8:N0} {3,8:N0}" -f `
        $ObjectApiName, $Result.TaggedBefore, $Result.TaggedNow, $Result.Created.Count)

    $Plan.Add($Result)
    $TotalToDelete += $Result.Created.Count
}

# --- notes ------------------------------------------------------------------
# ContentNote permits no custom fields, so it has no external ID and the set
# difference above cannot reach it. The only handle on a migrated note is the
# id file the loader wrote at creation time.
if (-not $NoteIdFile) {
    $NotesRuns = @(Get-ChildItem -Path (Get-LogDirectory -Category "data-migration") `
        -Directory -Filter "notes-load-*" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge (Get-Item -LiteralPath $RunDirectory).CreationTime } |
        Sort-Object LastWriteTime)

    foreach ($NotesRun in $NotesRuns) {
        $Candidate = Join-Path $NotesRun.FullName "created-note-ids.csv"
        if (Test-Path -LiteralPath $Candidate) { $NoteIdFile = $Candidate }
    }
}

$NoteIds = @()
if ($NoteIdFile -and (Test-Path -LiteralPath $NoteIdFile)) {
    # The column is NoteId, not Id - Invoke-NotesLoad.ps1 writes
    # NoteId,LinkedEntityId,Title,ParentObject,ParentExternalId. Reading $_.Id
    # yields nothing for every row and the rollback silently reports "0 notes"
    # while 537 sit in the org. Caught by the -PlanOnly dry run on 2026-08-13,
    # which is the entire argument for always dry-running this first.
    #
    # Id is accepted as a fallback so a hand-built file still works.
    $NoteRows = @(Import-Csv -LiteralPath $NoteIdFile)
    $NoteIds = @($NoteRows | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains "NoteId" -and $_.NoteId) { $_.NoteId }
        elseif ($_.PSObject.Properties.Name -contains "Id" -and $_.Id) { $_.Id }
    } | Where-Object { $_ })

    if ($NoteRows.Count -gt 0 -and $NoteIds.Count -eq 0) {
        throw ("$NoteIdFile has $($NoteRows.Count) row(s) but no usable NoteId/Id column " +
               "(found: $(($NoteRows[0].PSObject.Properties.Name) -join ', ')). Refusing to " +
               "continue - silently skipping notes would leave them orphaned in Files with " +
               "nothing to find them by.")
    }
    Write-Host ("  {0,-34} {1,8} {2,8} {3,8:N0}" -f "ContentDocument (notes)", "-", "-", $NoteIds.Count)
    Write-Host ("      from {0}" -f $NoteIdFile) -ForegroundColor DarkGray
}
else {
    Write-Host ("  {0,-34} {1,8} {2,8} {3,8}" -f "ContentDocument (notes)", "-", "-", "none found")
    Write-Host "      No created-note-ids.csv located. If the Notes step ran, pass -NoteIdFile;" -ForegroundColor Yellow
    Write-Host "      ContentNote has no external ID, so nothing else can find those notes." -ForegroundColor Yellow
}

# --- Account restore plan ---------------------------------------------------
$AccountChanges = @()
$AccountMissing = 0

if (-not $SkipAccountRestore) {
    Write-Host ""
    Write-Host "Comparing Accounts against the pre-image..." -ForegroundColor Cyan

    $PreImage = @(Import-Csv -LiteralPath $AccountPreImageFile)

    $CurrentById = @{}
    foreach ($Account in @(Invoke-SalesforceQuery `
            -Soql ("SELECT Id, LDGCRM_External_ID__c, Type, OwnerId, " +
                   "LDGCRM_Market_Segment__c FROM Account") `
            -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
        $CurrentById[$Account.Id] = $Account
    }

    $Changed = [System.Collections.Generic.List[object]]::new()

    foreach ($Was in $PreImage) {
        if (-not $CurrentById.ContainsKey($Was.Id)) {
            # Deleted since the pre-image was taken. Rollback cannot undo a
            # delete, and re-creating it would produce a different record with a
            # different Id that nothing else references.
            $AccountMissing++
            continue
        }

        $Is = $CurrentById[$Was.Id]
        $Restore = [ordered]@{ Id = $Was.Id }
        $Differs = $false

        foreach ($Field in $AccountRestoreFields) {
            # Normalise null and "" to the same thing: SOQL returns null for an
            # empty field, Import-Csv returns "". Without this every blank field
            # reads as a difference and the script "restores" all 1,350 Accounts
            # on every run.
            $Old = if ($null -eq $Was.$Field) { "" } else { [string]$Was.$Field }
            $New = if ($null -eq $Is.$Field) { "" } else { [string]$Is.$Field }

            if ($Old -ne $New) { $Differs = $true }
            $Restore[$Field] = $Old
        }

        if ($Differs) { $Changed.Add([PSCustomObject]$Restore) }
    }

    $AccountChanges = @($Changed)

    Write-Host ("  Accounts in pre-image                 {0:N0}" -f $PreImage.Count)
    Write-Host ("  Changed since, to be restored         {0:N0}" -f $AccountChanges.Count)
    Write-Host ("  In pre-image but now deleted          {0:N0}" -f $AccountMissing)

    if ($AccountMissing -gt 0) {
        Write-Host "  ^ these cannot be restored - rollback deletes, it cannot resurrect." -ForegroundColor Yellow
    }
}
else {
    Write-Host ""
    Write-Host "-SkipAccountRestore: Account field values will NOT be restored." -ForegroundColor Yellow
}

# --- confirm ----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host " ROLLBACK PLAN" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host ("  HARD DELETE  {0,7:N0} record(s) created by this run" -f $TotalToDelete)
Write-Host ("  HARD DELETE  {0,7:N0} note(s)" -f $NoteIds.Count)
Write-Host ("  UPDATE       {0,7:N0} Account(s) back to their pre-run values" -f $AccountChanges.Count)
Write-Host ""
Write-Host "  Deletes are PERMANENT - not the Recycle Bin - and Master-Detail children" -ForegroundColor Yellow
Write-Host "  cascade, so more may go than the count above. Restoring Accounts overwrites" -ForegroundColor Yellow
Write-Host "  any edit made since the run finished." -ForegroundColor Yellow

$OutputDirectory = Join-Path (Get-LogDirectory -Category "data-migration") "rollback-$Timestamp"
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

if ($PlanOnly) {
    foreach ($Item in $Plan) {
        if ($Item.Created.Count -eq 0) { continue }
        $Item.Created | Select-Object Id, LDGCRM_External_ID__c |
            Export-Csv -LiteralPath (Join-Path $OutputDirectory "would-delete-$($Item.Object).csv") `
                -NoTypeInformation -Encoding UTF8
    }

    if ($AccountChanges.Count -gt 0) {
        $AccountChanges | Export-Csv -LiteralPath (Join-Path $OutputDirectory "would-restore-Account.csv") `
            -NoTypeInformation -Encoding UTF8
    }

    Write-Host ""
    Write-Host "-PlanOnly: nothing was changed. Plan written to:" -ForegroundColor Yellow
    Write-Host "  $OutputDirectory"
    Write-Host ""
    Write-Host "Re-run without -PlanOnly (and with -Confirmation `"ROLLBACK`") to apply." -ForegroundColor Yellow
    exit 0
}

if (-not (Assert-LdgcrmProductionConsent -Environment $Environment `
        -Action "ROLL BACK $TotalToDelete record(s), $($NoteIds.Count) note(s) and restore $($AccountChanges.Count) Account(s)" `
        -ProductionConfirmation $ProductionConfirmation)) {
    exit 0
}

if (-not (Assert-LdgcrmTypedConfirmation `
        -Token "ROLLBACK" `
        -Provided $Confirmation `
        -Action "permanently delete $TotalToDelete record(s) + $($NoteIds.Count) note(s) and restore $($AccountChanges.Count) Account(s) in $OrgAlias")) {
    Write-Host "Not confirmed. Nothing was changed." -ForegroundColor Yellow
    exit 0
}

# --- execute ----------------------------------------------------------------
$Results = [System.Collections.Generic.List[object]]::new()

# Notes first, for the same reason the factory reset does it: deleting a parent
# removes its ContentDocumentLink but leaves the note orphaned in Files, where
# nothing can find it again.
if ($NoteIds.Count -gt 0) {
    Write-Host ""
    Write-Host "Deleting notes (ContentDocument)..." -ForegroundColor Cyan

    $NoteFile = Join-Path $OutputDirectory "delete-ContentDocument.csv"
    Export-DataLoaderCsv -InputObject @($NoteIds | ForEach-Object { [PSCustomObject]@{ Id = $_ } }) -Path $NoteFile

    Invoke-SalesforceCli -Arguments @(
        "data", "delete", "bulk",
        "--target-org", $OrgAlias, "--api-version", $ApiVersion,
        "--sobject", "ContentDocument", "--file", $NoteFile,
        "--hard-delete", "--wait", $WaitMinutes.ToString()
    )

    $Results.Add([PSCustomObject]@{ Step = "ContentDocument (notes)"; Records = $NoteIds.Count; Result = "deleted" })
}

foreach ($Item in $Plan) {
    if ($Item.Created.Count -eq 0) {
        $Results.Add([PSCustomObject]@{ Step = $Item.Object; Records = 0; Result = "nothing created by this run" })
        continue
    }

    Write-Host ""
    Write-Host ("Deleting {0:N0} {1} record(s)..." -f $Item.Created.Count, $Item.Object) -ForegroundColor Cyan

    # Audit trail before the delete, exactly as the factory reset does - this is
    # the only record of what went.
    $Item.Created | Select-Object Id, LDGCRM_External_ID__c |
        Export-Csv -LiteralPath (Join-Path $OutputDirectory "deleted-$($Item.Object).csv") `
            -NoTypeInformation -Encoding UTF8

    # Export-DataLoaderCsv, not Export-Csv: the Bulk API rejects a UTF-8 BOM
    # with "Failed to parse CSV. Found unescaped quote", an error that names
    # neither the BOM nor the encoding. Cost a failed factory reset on
    # 2026-08-13.
    $DeleteFile = Join-Path $OutputDirectory "delete-$($Item.Object).csv"
    Export-DataLoaderCsv -InputObject @($Item.Created | ForEach-Object { [PSCustomObject]@{ Id = $_.Id } }) -Path $DeleteFile

    Invoke-SalesforceCli -Arguments @(
        "data", "delete", "bulk",
        "--target-org", $OrgAlias, "--api-version", $ApiVersion,
        "--sobject", $Item.Object, "--file", $DeleteFile,
        "--hard-delete", "--wait", $WaitMinutes.ToString()
    )

    $Results.Add([PSCustomObject]@{ Step = $Item.Object; Records = $Item.Created.Count; Result = "deleted" })
}

if ($AccountChanges.Count -gt 0) {
    Write-Host ""
    Write-Host ("Restoring {0:N0} Account(s) to their pre-run values..." -f $AccountChanges.Count) -ForegroundColor Cyan

    # Id-keyed UPDATE, never an upsert: these Accounts pre-date the migration
    # and must not be created if a match fails.
    $RestoreFile = Join-Path $OutputDirectory "restore-Account.csv"
    Export-DataLoaderCsv -InputObject $AccountChanges -Path $RestoreFile

    Invoke-SalesforceCli -Arguments @(
        "data", "update", "bulk",
        "--target-org", $OrgAlias, "--api-version", $ApiVersion,
        "--sobject", "Account", "--file", $RestoreFile,
        "--wait", $WaitMinutes.ToString()
    )

    $Results.Add([PSCustomObject]@{ Step = "Account (restored)"; Records = $AccountChanges.Count; Result = "updated" })
}

# --- summary ----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " ROLLBACK COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

$Results | Format-Table -AutoSize
$Results | Export-Csv -LiteralPath (Join-Path $OutputDirectory "rollback-summary.csv") -NoTypeInformation -Encoding UTF8

Write-Host "Audit trail (what was deleted and what was restored):"
Write-Host "  $OutputDirectory"
Write-Host ""
Write-Host "This did NOT undo everything. Records the run UPDATED on objects other than" -ForegroundColor Yellow
Write-Host "Account keep their new values, Master-Detail cascades may have removed rows the" -ForegroundColor Yellow
Write-Host "run did not create, and anything a factory reset hard-deleted was already gone." -ForegroundColor Yellow

}
finally {
    Stop-ScriptLog
}
