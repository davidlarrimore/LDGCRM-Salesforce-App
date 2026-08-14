#Requires -Version 5.1

<#
    The final chunk of the Airtable -> Salesforce data-migration pipeline (see
    docs/engineering/ARCHITECTURE.md). Turns freeform Airtable columns that have no dedicated
    Salesforce field into ContentNote records attached to the record they
    describe. Full candidate analysis and the reasoning behind every inclusion
    and exclusion live in docs/engineering/TRANSFORMATION-RULES.md's "Notes" section.

    MUST RUN LAST. A note attaches to a record that has to already exist, so
    every other object must be loaded first.

    ============================================================
    WHY THIS CHUNK NEEDS ITS OWN LOAD PROCESS
    ============================================================
    Every other chunk here is a single-object CSV that Invoke-SalesforceLoad.ps1
    can push straight in. Notes cannot be, for two independent reasons:

    1. ContentNote HAS NO EXTERNAL ID, and cannot be given one - it is a Files
       object with zero custom fields (verified against the org, not assumed).
       So there is no upsert key and no way to make a re-run idempotent by
       matching. Idempotency is instead READ-THEN-DIFF, the same approach
       OpportunityContactRole uses: read what is already attached, key it on
       (LinkedEntityId, Title), and emit only what is missing. That composite is
       reliable precisely BECAUSE the design is one note per record per source
       column, so a parent never has two notes with the same title.

    2. ATTACHING A NOTE IS A SECOND OBJECT, and it needs an Id that does not
       exist until the note has been inserted. ContentDocumentLink joins the
       note's *document* to the parent record, so the sequence is
       insert -> read back the new ContentDocumentIds -> insert the links.
       That is what Invoke-NotesLoad.ps1 orchestrates; this script only prepares.

    THIS SCRIPT RESOLVES THE PARENT IDS ITSELF. ContentDocumentLink.LinkedEntityId
    is a polymorphic reference, so the Bulk API cannot resolve it from an
    external ID the way "Parent__r.LDGCRM_External_ID__c" works everywhere else
    in this pipeline. The parent has to be looked up and written as a real
    15/18-character Id. That is why this transform queries the org for an
    external-ID -> Id map per object rather than passing the rec... id through.

    ============================================================
    WHAT BECOMES A NOTE, AND WHAT DELIBERATELY DOES NOT
    ============================================================
    The candidate list was re-derived from the data on 2026-08-13 rather than
    inherited - see TRANSFORMATION-RULES.md for the full table. A column
    qualifies only if it is unmapped, long-form, and MOSTLY UNIQUE across rows;
    the distinct-value ratio is what separates prose from a controlled
    vocabulary, and it is not visible from reading a sample.

    Included per the 2026-08-13 decision: Known Blockers and Goals are carried
    as notes too, with the column name as the note title, rather than becoming
    new picklist fields. They are short and repetitive rather than prose, so the
    title is what gives them meaning.

    PLACEHOLDER VALUES ARE SKIPPED. 42 of 92 Known Blockers rows say literally
    "None" or "N/A" - a note reading "None" asserts that a blocker was recorded
    when the data means the opposite, which is the same trap as the Airtable
    Impediment named "None" that this migration already excludes. Those rows
    produce no note at all.

    Meetings columns are NOT included: that object is deferred pending Einstein
    Activity Capture (see docs/engineering/BACKLOG.md 2). If unmatched meetings later land
    here as notes, this chunk grows by up to ~1,800 records.
#>

param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (powershell-scripts/Common.Orgs.ps1).
    [string]$OrgAlias = "",
    [string]$ApiVersion = "67.0",

    # Owner for notes whose parent record has no usable owner to inherit.
    [string]$FallbackOwnerEmail = "peter.marks@gsa.gov",

    # Values that mean "nothing recorded" rather than content. Case-insensitive,
    # matched against the whole trimmed value.
    [string[]]$PlaceholderValues = @("None", "N/A", "NA", "n/a", "-", "--", "TBD", "TBA", "Unknown")
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Common.DataMigration.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

$Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "Build-NotesLoad"

# Every (Airtable column -> note) mapping, in one table so adding a source is a
# data change rather than a code change. Title is what the user sees AND half of
# the idempotency key, so it must stay stable once loaded - changing a title
# later makes the next run create a duplicate note rather than match.
$NoteSources = @(
    @{ Table = "Partner Accounts"; Object = "LDGCRM_Partner_Account__c"; Column = "Account Description"; Title = "Account Description" }
    @{ Table = "Partner Accounts"; Object = "LDGCRM_Partner_Account__c"; Column = "Tasks";               Title = "Tasks" }
    @{ Table = "Partner Accounts"; Object = "LDGCRM_Partner_Account__c"; Column = "Known Blockers";      Title = "Known Blockers" }
    @{ Table = "Partner Accounts"; Object = "LDGCRM_Partner_Account__c"; Column = "Goals";               Title = "Goals" }
    @{ Table = "Applications";     Object = "LDGCRM_application__c";     Column = "Notes";               Title = "Notes" }
    @{ Table = "Applications";     Object = "LDGCRM_application__c";     Column = "Launch Notes";        Title = "Launch Notes" }
    @{ Table = "Applications";     Object = "LDGCRM_application__c";     Column = "IdV Upgrade Notes";   Title = "IdV Upgrade Notes" }
)

function ConvertTo-NoteContent {
    <#
        Builds the base64 body ContentNote.Content expects.

        ORDER MATTERS: HTML-escape FIRST, then insert <br> tags. Doing it the
        other way escapes the tags themselves and the note renders literal
        "&lt;br&gt;" text - the same trap already documented for Opportunity's
        three Html fields.

        Enhanced Notes render a restricted HTML subset; plain escaped text with
        <br> line breaks is inside it and needs no further markup.
    #>
    param([string]$Text)

    $Escaped = [System.Net.WebUtility]::HtmlEncode($Text)
    # Normalise CRLF/CR to LF before converting, or Windows-sourced values
    # produce doubled breaks.
    $Escaped = $Escaped -replace "`r`n", "`n" -replace "`r", "`n"
    $Html = $Escaped -replace "`n", "<br>"

    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    return [System.Convert]::ToBase64String($Bytes)
}

function Test-PlaceholderValue {
    param([string]$Value, [string[]]$Placeholders)

    $Trimmed = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($Trimmed)) { return $true }

    foreach ($P in $Placeholders) {
        if ($Trimmed -eq $P) { return $true }          # -eq on strings is case-insensitive
    }
    return $false
}

try {

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " NOTES LOAD PREP (Airtable -> $OrgAlias)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Reads Salesforce (read-only queries) - writes local files only." -ForegroundColor Yellow
Write-Host "MUST run after every other object is loaded." -ForegroundColor Yellow
Write-Host ""

Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias -Quiet | Out-Null

Write-Host "Resolving the fallback owner ($FallbackOwnerEmail)..." -ForegroundColor Cyan
$FallbackOwnerId = Resolve-FallbackOwnerId -Email $FallbackOwnerEmail -OrgAlias $OrgAlias -ApiVersion $ApiVersion
Write-Host "Fallback owner resolves to $FallbackOwnerId."

# ============================================================
# PARENT LOOKUP: external ID -> real Salesforce Id (and owner)
# ============================================================
# LinkedEntityId is polymorphic, so it cannot be resolved by the Bulk API from
# an external ID. Every parent has to be looked up here and written as a real Id.
$ParentObjects = @($NoteSources | ForEach-Object { $_.Object } | Sort-Object -Unique)
$ParentById = @{}          # "<Object>|<externalId>" -> @{ Id; OwnerId }

foreach ($Object in $ParentObjects) {
    Write-Host ""
    Write-Host "Querying $OrgAlias for $Object records..." -ForegroundColor Cyan

    # Partner Account is a Master-Detail child and has no OwnerId of its own;
    # asking for one is a query error, not an empty column.
    $HasOwner = $Object -ne "LDGCRM_Partner_Account__c"
    $Fields = if ($HasOwner) { "Id, LDGCRM_External_ID__c, OwnerId" } else { "Id, LDGCRM_External_ID__c" }

    $Rows = @(Invoke-SalesforceQuery `
        -Soql "SELECT $Fields FROM $Object WHERE LDGCRM_External_ID__c != null" `
        -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

    foreach ($Row in $Rows) {
        if (-not $Row.LDGCRM_External_ID__c) { continue }
        $Key = "$Object|$($Row.LDGCRM_External_ID__c)"
        $ParentById[$Key] = [PSCustomObject]@{
            Id      = $Row.Id
            OwnerId = if ($HasOwner) { $Row.OwnerId } else { "" }
        }
    }

    Write-Host "$($Rows.Count) $Object record(s) available to attach notes to."
}

# ============================================================
# BUILD THE NOTES
# ============================================================
$StagingRows = [System.Collections.Generic.List[object]]::new()
$SkippedRows = [System.Collections.Generic.List[object]]::new()
$PlaceholderCount = 0
$PerSourceCounts = [ordered]@{}

foreach ($Source in $NoteSources) {
    $Records = Import-AirtableTable -Label $Source.Table
    $Made = 0

    foreach ($Row in $Records) {
        $Raw = $Row.fields.($Source.Column)
        if (-not $Raw) { continue }                    # null-check BEFORE @()

        # A multi-select column arrives as an array; join rather than let
        # PowerShell stringify it as "System.Object[]" - the exact failure that
        # broke Application's Service Level on its first load.
        $Value = if ($Raw -is [array]) { (@($Raw) | ForEach-Object { "$_" }) -join "`n" } else { "$Raw" }

        if (Test-PlaceholderValue -Value $Value -Placeholders $PlaceholderValues) {
            $PlaceholderCount++
            continue
        }

        $ParentKey = "$($Source.Object)|$($Row.id)"
        if (-not $ParentById.ContainsKey($ParentKey)) {
            $SkippedRows.Add([PSCustomObject]@{
                AirtableRecordId = $Row.id
                ParentObject     = $Source.Object
                NoteTitle        = $Source.Title
                Reason           = "Parent record is not in $OrgAlias - it was withheld by its own load (usually the unreconciled-Account data-quality issue). Re-run after it loads; no code change needed."
            })
            continue
        }

        $Parent = $ParentById[$ParentKey]

        # Notes follow their parent's owner where the parent has one, so a note
        # is never more visible than the record it describes. Partner Account
        # has no OwnerId (Master-Detail), so those take the fallback.
        $OwnerId = if ($Parent.OwnerId) { $Parent.OwnerId } else { $FallbackOwnerId }

        $StagingRows.Add([PSCustomObject][ordered]@{
            Title            = $Source.Title
            Content          = (ConvertTo-NoteContent -Text $Value)
            OwnerId          = $OwnerId
            LinkedEntityId   = $Parent.Id
            ParentObject     = $Source.Object
            ParentExternalId = $Row.id
        })
        $Made++
    }

    $PerSourceCounts["$($Source.Object) / $($Source.Title)"] = $Made
}

# ============================================================
# READ-THEN-DIFF (idempotency - there is no upsert key)
# ============================================================
# ContentDocumentLink can only be queried with a filter on LinkedEntityId or
# ContentDocumentId, and the IN list has to stay modest, so this chunks.
Write-Host ""
Write-Host "Checking which notes already exist (read-then-diff)..." -ForegroundColor Cyan

$ExistingKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

$LinkedIds = @($StagingRows | ForEach-Object { $_.LinkedEntityId } | Sort-Object -Unique)
$ChunkSize = 100

for ($Offset = 0; $Offset -lt $LinkedIds.Count; $Offset += $ChunkSize) {
    $Last = [Math]::Min($Offset + $ChunkSize, $LinkedIds.Count) - 1
    $Chunk = @($LinkedIds[$Offset..$Last])
    $Literals = ($Chunk | ForEach-Object { "'$_'" }) -join ","

    $Existing = @(Invoke-SalesforceQuery `
        -Soql ("SELECT LinkedEntityId, ContentDocument.Title FROM ContentDocumentLink " +
               "WHERE LinkedEntityId IN ($Literals)") `
        -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

    foreach ($Link in $Existing) {
        if ($Link.ContentDocument -and $Link.ContentDocument.Title) {
            $ExistingKeys.Add("$($Link.LinkedEntityId)|$($Link.ContentDocument.Title)") | Out-Null
        }
    }
}

$NewRows = [System.Collections.Generic.List[object]]::new()
$AlreadyPresent = 0

foreach ($Note in $StagingRows) {
    if ($ExistingKeys.Contains("$($Note.LinkedEntityId)|$($Note.Title)")) {
        $AlreadyPresent++
        continue
    }
    $NewRows.Add($Note)
}

Write-Host "$($ExistingKeys.Count) note(s) already attached; $AlreadyPresent of this run's notes match one."

# ============================================================
# OUTPUT
# ============================================================
$LoadDir = Get-SalesforceLoadDirectory
$LogDir = Get-LogDirectory -Category "data-migration"

$StagingFile = Join-Path $LoadDir "ContentNote-staging.csv"
$SkippedFile = Join-Path $LogDir "Notes-skipped-$Timestamp.csv"

if ($NewRows.Count -gt 0) {
    Export-DataLoaderCsv -InputObject $NewRows.ToArray() -Path $StagingFile
}

if ($SkippedRows.Count -gt 0) {
    $SkippedRows | Export-Csv -LiteralPath $SkippedFile -NoTypeInformation -Encoding UTF8
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " NOTES PREP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Notes by source column:" -ForegroundColor Cyan
foreach ($Key in $PerSourceCounts.Keys) {
    Write-Host ("    {0,-48} {1,6:N0}" -f $Key, $PerSourceCounts[$Key])
}
Write-Host ""
Write-Host ("{0,-54} {1,6:N0}" -f "Notes ready to create", $NewRows.Count)
Write-Host ("{0,-54} {1,6:N0}" -f "Already attached (re-run safe, skipped)", $AlreadyPresent)
Write-Host ("{0,-54} {1,6:N0}" -f "Placeholder values skipped (None/N/A/...)", $PlaceholderCount)
Write-Host ("{0,-54} {1,6:N0}" -f "Skipped - parent not loaded", $SkippedRows.Count)
Write-Host ""

if ($NewRows.Count -gt 0) {
    Write-Host "Staging file (NOT loadable directly - see below):" -ForegroundColor Cyan
    Write-Host $StagingFile
    Write-Host ""
    Write-Host "This file carries BOTH the note and its parent link, which are two" -ForegroundColor Yellow
    Write-Host "different objects. Load it with the orchestrator, not Invoke-SalesforceLoad:" -ForegroundColor Yellow
    Write-Host "  scripts\powershell-scripts\Invoke-NotesLoad.ps1 -Environment $Environment" -ForegroundColor DarkGray
}

if ($SkippedRows.Count -gt 0) {
    Write-Host "Notes whose parent isn't loaded yet:" -ForegroundColor Yellow
    Write-Host $SkippedFile
}

}
finally {
    Stop-ScriptLog
}
