#Requires -Version 5.1

<#
    Loads the notes prepared by Build-NotesLoad.ps1.

    ============================================================
    WHY THIS DOES NOT USE THE BULK API LIKE EVERY OTHER CHUNK
    ============================================================
    It can't. Proven against Dev on 2026-08-13 by trying it:

        InvalidBatch : Binary field Content is only supported for content
        types ZIP_XML and ZIP_CSV

    ContentNote.Content is a binary/base64 field, and Bulk API 2.0 CSV ingest -
    which `sf data import bulk` uses - refuses binary fields outright. So this
    is the one object in the pipeline loaded over the REST API, which accepts
    base64 as an ordinary JSON string.

    It uses the sObject Collections endpoint (POST /composite/sobjects), which
    takes up to 200 records per call, so ~537 notes is a handful of round trips
    rather than one call per note.

    CORRELATION IS BY POSITION, AND THAT IS SAFE HERE. sObject Collections
    returns its results array in the SAME ORDER as the records array it was
    given - unlike Bulk API, where row order is not guaranteed and the earlier
    design had to match on content. Each batch is small and self-contained, so
    index i of the response is index i of the request.

    ============================================================
    THE SEQUENCE - TWO STEPS, NOT THREE
    ============================================================
        1. POST /composite/sobjects  ContentNote          (Title, Content, OwnerId)
        2. POST /composite/sobjects  ContentDocumentLink  (ContentDocumentId = the
                                                           Id returned by step 1)

    There is no read-back step. ContentNote has NO ContentDocumentId field - the
    note's own Id IS the ContentDocument Id (it appears in ContentDocument with
    FileType 'SNOTE'). Querying for one fails with "No such column". An earlier
    version of this script had that read-back and would have died on it.

    ============================================================
    THE RISK THIS IS BUILT AROUND
    ============================================================
    Between step 1 and step 2 the notes exist attached to NOTHING, and
    ContentNote has no external ID, so there is no key to find them by later. If
    step 2 fails, those notes are orphans.

    Three things guard that:
      - the edit-access preflight runs BEFORE anything is created (see below);
      - the created note Ids are written to disk after EVERY batch, not at the
        end, so a crash still leaves a complete record of what exists;
      - -ResumeFromNoteIdFile re-runs step 2 alone from that file.

    ============================================================
    SHARING
    ============================================================
    ShareType 'I' (Inferred - a user's access to the note follows their access
    to the record it hangs off) and Visibility 'InternalUsers'. Both verified
    accepted by a real insert. Visibility is deliberately not 'AllUsers': this
    org has active Guest and Chatter-only users and these notes carry internal
    commentary about partners.

    IDEMPOTENCY: there is no upsert for ContentNote. Re-running is safe only
    because Build-NotesLoad.ps1 diffs against what is already attached before
    writing the staging file - re-run THAT first, not this.
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    [string]$StagingFile = "",

    # Write the request payloads and stop. Nothing is sent to Salesforce.
    [switch]$PlanOnly,

    # Skip note creation and re-run only the linking step, from an earlier run's
    # note-Id file. For recovering orphaned notes.
    [string]$ResumeFromNoteIdFile = "",

    # sObject Collections caps at 200. Lower also bounds how much is in flight
    # if a batch fails, and keeps each request payload well under REST limits -
    # some note bodies are several KB of base64.
    [ValidateRange(1, 200)]
    [int]$BatchSize = 100
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Invoke-NotesLoad"

$ShareType = "I"
$Visibility = "InternalUsers"

function Invoke-SalesforceRestJson {
    <#
        POSTs a JSON payload via `sf api request rest` and returns the parsed
        response.

        WHY THE OUTPUT IS FILTERED: the CLI prints an update-available notice
        and a "this command is in beta" warning to the same stream as the
        response body, so the raw output is not valid JSON. This takes
        everything from the first line that starts a JSON value.

        WHY THE BODY COMES FROM A FILE: base64 note bodies run to several KB and
        a batch of them would blow the command-line length limit.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BodyFile,
        [Parameter(Mandatory = $true)][string]$Org
    )

    $Output = & sf api request rest $Path --method POST --body "@$BodyFile" --target-org $Org

    $Lines = @($Output | ForEach-Object { "$_" })
    $Start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].TrimStart().StartsWith("[") -or $Lines[$i].TrimStart().StartsWith("{")) {
            $Start = $i
            break
        }
    }

    if ($Start -lt 0) {
        throw "No JSON in the response from $Path. Raw output:`n$($Lines -join "`n")"
    }

    return (($Lines[$Start..($Lines.Count - 1)]) -join "`n") | ConvertFrom-Json
}

function New-CompositeBody {
    <#
        Builds the sObject Collections payload.

        allOrNone = false on purpose: one bad row should not discard a whole
        batch of good notes. Failures are reported per record and written to a
        review CSV instead.

        -Depth matters. ConvertTo-Json defaults to depth 2, which silently
        mangles the nested "attributes" object into a type name string and
        produces a payload Salesforce rejects.
    #>
    param([object[]]$Records)

    return [PSCustomObject]@{
        allOrNone = $false
        records   = $Records
    } | ConvertTo-Json -Depth 10
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " NOTES LOAD (ContentNote + ContentDocumentLink, via REST)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias | Out-Null

$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

if (-not $StagingFile) { $StagingFile = Join-Path $LoadDir "ContentNote-staging.csv" }
if (-not (Test-Path -LiteralPath $StagingFile)) {
    throw "No staging file at $StagingFile. Run Build-NotesLoad.ps1 first."
}

$Staging = @(Import-Csv -LiteralPath $StagingFile)
Write-Host ""
Write-Host "Staging file   : $StagingFile"
Write-Host "Notes to create: $($Staging.Count)"
Write-Host "Batch size     : $BatchSize (sObject Collections, max 200)"
Write-Host "Sharing        : ShareType=$ShareType  Visibility=$Visibility"

if ($Staging.Count -eq 0) {
    Write-Host "Nothing to do." -ForegroundColor Yellow
    exit 0
}

$RunDirectory = Join-Path $LogDir "notes-load-$Timestamp"
New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null

# ============================================================
# PREFLIGHT: can this user attach to these records?
# ============================================================
# The org has an unmanaged ContentDocumentLinkTrigger (not in this repo - found
# by the standing "check the live org" rule). Its beforeInsert queries
# UserRecordAccess for the RUNNING USER against every LinkedEntityId and rejects
# the row if they lack EDIT access.
#
# IT CANNOT BE TURNED OFF. It looks like it has a kill switch
# (Trigger_Settings__mdt.ContentDocumentLinkTrigger.isActive__c) but the switch
# is inert: IsDisabled() sets a flag and returns from ITSELF while the
# dispatcher calls beforeInsert unconditionally.
#
# This runs before ANY note is created, because failing at the link step is what
# produces orphans. It also catches the case that makes the trigger throw rather
# than reject: a LinkedEntityId with no UserRecordAccess row yields a null
# Boolean, which the trigger negates without a null check - an unhandled NPE
# that fails the whole request.
Write-Host ""
Write-Host "Preflight: checking edit access to every parent record..." -ForegroundColor Cyan

$CurrentUserId = (& sf org display user --target-org $OrgAlias --json | ConvertFrom-Json).result.id
$ParentIds = @($Staging | ForEach-Object { $_.LinkedEntityId } | Sort-Object -Unique)
$NoEditAccess = [System.Collections.Generic.List[string]]::new()

for ($Offset = 0; $Offset -lt $ParentIds.Count; $Offset += 200) {
    $Last = [Math]::Min($Offset + 200, $ParentIds.Count) - 1
    $Chunk = @($ParentIds[$Offset..$Last])
    $Literals = ($Chunk | ForEach-Object { "'$_'" }) -join ","

    $Access = @{}
    foreach ($Row in @(Invoke-SalesforceQuery `
            -Soql ("SELECT RecordId, HasEditAccess FROM UserRecordAccess " +
                   "WHERE UserId = '$CurrentUserId' AND RecordId IN ($Literals)") `
            -OrgAlias $OrgAlias -ApiVersion $ApiVersion)) {
        $Access[$Row.RecordId] = [bool]$Row.HasEditAccess
    }

    foreach ($Id in $Chunk) {
        if (-not $Access.ContainsKey($Id) -or -not $Access[$Id]) { $NoEditAccess.Add($Id) }
    }
}

if ($NoEditAccess.Count -gt 0) {
    $AccessFile = Join-Path $RunDirectory "no-edit-access.csv"
    $NoEditAccess | ForEach-Object { [PSCustomObject]@{ LinkedEntityId = $_ } } |
        Export-Csv -LiteralPath $AccessFile -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "STOPPING: $($NoEditAccess.Count) parent record(s) are not editable by this user." -ForegroundColor Red
    Write-Host "The org's ContentDocumentLink trigger would reject those links - and the" -ForegroundColor Red
    Write-Host "notes would already exist, attached to nothing." -ForegroundColor Red
    Write-Host "  $AccessFile" -ForegroundColor Red
    exit 1
}

Write-Host "All $($ParentIds.Count) parent record(s) are editable by this user." -ForegroundColor Green

if ($PlanOnly) {
    $PreviewFile = Join-Path $RunDirectory "contentnote-batch-1-preview.json"
    $Preview = @($Staging | Select-Object -First $BatchSize | ForEach-Object {
        [PSCustomObject]@{
            attributes = [PSCustomObject]@{ type = "ContentNote" }
            Title      = $_.Title
            Content    = $_.Content
            OwnerId    = $_.OwnerId
        }
    })
    [System.IO.File]::WriteAllText($PreviewFile, (New-CompositeBody -Records $Preview), (New-Object System.Text.UTF8Encoding $false))

    Write-Host ""
    Write-Host "-PlanOnly: nothing was sent. First batch payload written for inspection:" -ForegroundColor Yellow
    Write-Host "  $PreviewFile"
    exit 0
}

# ============================================================
# CONFIRMATION
# ============================================================
Write-Host ""
Write-Host "This creates $($Staging.Count) ContentNote records and the same number of" -ForegroundColor Yellow
Write-Host "ContentDocumentLink records in $OrgAlias." -ForegroundColor Yellow
Write-Host "ContentNote has no external ID - these cannot be matched or re-upserted" -ForegroundColor Yellow
Write-Host "later, only found by what they are attached to." -ForegroundColor Yellow

if (-not (Assert-LdgcrmProductionConsent -Environment $Environment -Action "create $($Staging.Count) notes and attach them")) {
    exit 0
}

$Typed = Read-Host "Type LOAD to continue"
if ($Typed -cne "LOAD") {
    Write-Host "Not confirmed. Nothing was written." -ForegroundColor Yellow
    exit 0
}

$NoteIdFile = Join-Path $RunDirectory "created-note-ids.csv"
$FailureFile = Join-Path $RunDirectory "failures.csv"
$Failures = [System.Collections.Generic.List[object]]::new()
$CreatedNotes = [System.Collections.Generic.List[object]]::new()

# ============================================================
# STEP 1 - create the notes
# ============================================================
if ($ResumeFromNoteIdFile) {
    Write-Host ""
    Write-Host "RESUMING from $ResumeFromNoteIdFile - skipping note creation." -ForegroundColor Yellow
    foreach ($Row in @(Import-Csv -LiteralPath $ResumeFromNoteIdFile)) { $CreatedNotes.Add($Row) }
}
else {
    Write-Host ""
    Write-Host "Step 1: creating ContentNote records..." -ForegroundColor Cyan

    $BatchNumber = 0
    for ($Offset = 0; $Offset -lt $Staging.Count; $Offset += $BatchSize) {
        $BatchNumber++
        $Last = [Math]::Min($Offset + $BatchSize, $Staging.Count) - 1
        $Batch = @($Staging[$Offset..$Last])

        $Records = @($Batch | ForEach-Object {
            [PSCustomObject]@{
                attributes = [PSCustomObject]@{ type = "ContentNote" }
                Title      = $_.Title
                Content    = $_.Content
                OwnerId    = $_.OwnerId
            }
        })

        $BodyFile = Join-Path $RunDirectory "contentnote-batch-$BatchNumber.json"
        [System.IO.File]::WriteAllText($BodyFile, (New-CompositeBody -Records $Records), (New-Object System.Text.UTF8Encoding $false))

        $Response = @(Invoke-SalesforceRestJson `
            -Path "/services/data/v$ApiVersion/composite/sobjects" `
            -BodyFile $BodyFile -Org $OrgAlias)

        if ($Response.Count -ne $Batch.Count) {
            throw ("Batch $BatchNumber returned $($Response.Count) results for $($Batch.Count) records. " +
                   "Positional correlation is unsafe - stopping. Notes created so far are in $NoteIdFile.")
        }

        for ($i = 0; $i -lt $Batch.Count; $i++) {
            $Result = $Response[$i]
            $Source = $Batch[$i]

            if ($Result.success) {
                $CreatedNotes.Add([PSCustomObject]@{
                    NoteId           = $Result.id      # doubles as ContentDocumentId
                    LinkedEntityId   = $Source.LinkedEntityId
                    Title            = $Source.Title
                    ParentObject     = $Source.ParentObject
                    ParentExternalId = $Source.ParentExternalId
                })
            }
            else {
                $Failures.Add([PSCustomObject]@{
                    Step             = "ContentNote"
                    Title            = $Source.Title
                    ParentExternalId = $Source.ParentExternalId
                    Error            = (($Result.errors | ForEach-Object { $_.message }) -join "; ")
                })
            }
        }

        # Written after EVERY batch, not at the end: an interruption here leaves
        # notes attached to nothing, and this file is the only way to find them.
        $CreatedNotes | Export-Csv -LiteralPath $NoteIdFile -NoTypeInformation -Encoding UTF8

        Write-Host ("  batch {0,-3} {1,5} sent  {2,5} created  (running total {3})" -f `
            $BatchNumber, $Batch.Count, @($Response | Where-Object { $_.success }).Count, $CreatedNotes.Count)
    }

    Write-Host "$($CreatedNotes.Count) note(s) created. Ids saved to:" -ForegroundColor Green
    Write-Host "  $NoteIdFile"
}

if ($CreatedNotes.Count -eq 0) {
    Write-Host "No notes were created - nothing to link." -ForegroundColor Yellow
    if ($Failures.Count -gt 0) { $Failures | Export-Csv -LiteralPath $FailureFile -NoTypeInformation -Encoding UTF8 }
    exit 1
}

# ============================================================
# STEP 2 - attach them
# ============================================================
Write-Host ""
Write-Host "Step 2: attaching notes to their records..." -ForegroundColor Cyan

$Linked = 0
$BatchNumber = 0

for ($Offset = 0; $Offset -lt $CreatedNotes.Count; $Offset += $BatchSize) {
    $BatchNumber++
    $Last = [Math]::Min($Offset + $BatchSize, $CreatedNotes.Count) - 1
    $Batch = @($CreatedNotes[$Offset..$Last])

    $Records = @($Batch | ForEach-Object {
        [PSCustomObject]@{
            attributes        = [PSCustomObject]@{ type = "ContentDocumentLink" }
            # The note's own Id IS the ContentDocument Id - ContentNote has no
            # ContentDocumentId field to look up.
            ContentDocumentId = $_.NoteId
            LinkedEntityId    = $_.LinkedEntityId
            ShareType         = $ShareType
            Visibility        = $Visibility
        }
    })

    $BodyFile = Join-Path $RunDirectory "contentdocumentlink-batch-$BatchNumber.json"
    [System.IO.File]::WriteAllText($BodyFile, (New-CompositeBody -Records $Records), (New-Object System.Text.UTF8Encoding $false))

    $Response = @(Invoke-SalesforceRestJson `
        -Path "/services/data/v$ApiVersion/composite/sobjects" `
        -BodyFile $BodyFile -Org $OrgAlias)

    for ($i = 0; $i -lt $Batch.Count; $i++) {
        if ($i -lt $Response.Count -and $Response[$i].success) { $Linked++ }
        else {
            $Message = if ($i -lt $Response.Count) { (($Response[$i].errors | ForEach-Object { $_.message }) -join "; ") } else { "No result returned" }
            $Failures.Add([PSCustomObject]@{
                Step             = "ContentDocumentLink"
                Title            = $Batch[$i].Title
                ParentExternalId = $Batch[$i].ParentExternalId
                Error            = $Message
            })
        }
    }

    Write-Host ("  batch {0,-3} {1,5} sent  {2,5} attached  (running total {3})" -f `
        $BatchNumber, $Batch.Count, @($Response | Where-Object { $_.success }).Count, $Linked)
}

if ($Failures.Count -gt 0) {
    $Failures | Export-Csv -LiteralPath $FailureFile -NoTypeInformation -Encoding UTF8
}

# ============================================================
# VERIFY
# ============================================================
Write-Host ""
Write-Host "Verifying against the org..." -ForegroundColor Cyan

$Attached = 0
$LinkedIds = @($Staging | ForEach-Object { $_.LinkedEntityId } | Sort-Object -Unique)

for ($Offset = 0; $Offset -lt $LinkedIds.Count; $Offset += 100) {
    $Last = [Math]::Min($Offset + 100, $LinkedIds.Count) - 1
    $Literals = (@($LinkedIds[$Offset..$Last]) | ForEach-Object { "'$_'" }) -join ","

    $Attached += @(Invoke-SalesforceQuery `
        -Soql ("SELECT Id FROM ContentDocumentLink WHERE LinkedEntityId IN ($Literals) " +
               "AND ContentDocument.FileType = 'SNOTE'") `
        -OrgAlias $OrgAlias -ApiVersion $ApiVersion).Count
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " NOTES LOAD COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ("{0,-46} {1,6:N0}" -f "Notes staged", $Staging.Count)
Write-Host ("{0,-46} {1,6:N0}" -f "Notes created", $CreatedNotes.Count)
Write-Host ("{0,-46} {1,6:N0}" -f "Notes attached", $Linked)
Write-Host ("{0,-46} {1,6:N0}" -f "Failures", $Failures.Count)
Write-Host ("{0,-46} {1,6:N0}" -f "Notes now on those records (verified in org)", $Attached)
Write-Host ""

if ($Linked -lt $CreatedNotes.Count) {
    Write-Host "WARNING: $($CreatedNotes.Count - $Linked) note(s) exist but are NOT attached." -ForegroundColor Red
    Write-Host "They have no external ID - this file is the only record of them:" -ForegroundColor Red
    Write-Host "  $NoteIdFile" -ForegroundColor Red
    Write-Host "Re-run the link step alone with:" -ForegroundColor Yellow
    Write-Host "  Invoke-NotesLoad.ps1 -Environment $Environment -ResumeFromNoteIdFile `"$NoteIdFile`"" -ForegroundColor DarkGray
}

Write-Host "Run output: $RunDirectory"
if ($Failures.Count -gt 0) {
    Write-Host "Failures:   $FailureFile" -ForegroundColor Yellow
}

}
finally {
    Stop-ScriptLog
}
