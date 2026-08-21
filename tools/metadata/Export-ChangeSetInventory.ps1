#Requires -Version 5.1
<#
    Generates docs/engineering/PRODUCTION-CHANGE-SET-INVENTORY.md - the
    component-by-component inventory of a change set, handed to the GSA IT
    Engineering team so they can verify a deployment landed completely.

    Usage:
        powershell tools/metadata/Export-ChangeSetInventory.ps1 -ChangeSetName "LDGCRM_Sprint_1_24"
        powershell tools/metadata/Export-ChangeSetInventory.ps1 -ChangeSetName "LDGCRM_Sprint_1_25" -WhatIf
        powershell tools/metadata/Export-ChangeSetInventory.ps1 -ChangeSetName "LDGCRM_Sprint_1_25" -OutputPath docs\engineering\OTHER.md

    =========================================================================
    RETRIEVE FROM THE SOURCE ORG, NOT THE ONE YOU ARE VERIFYING
    =========================================================================
    A change set is only exposed as an unmanaged package by the org that BUILT
    it. Asking the receiving org for its INBOUND copy fails with:

        INVALID_CROSS_REFERENCE_KEY: No package named '<name>' found

    which reads exactly like a typo or a permissions problem and is neither.
    So -Environment defaults to Dev (the source org) even though the change set
    being verified is the inbound one sitting in QA. The generated document
    states this, because it bounds what the inventory proves: it is the
    definition of what was SENT, not evidence of what ARRIVED.

    =========================================================================
    WHY THIS IS A tools/ SCRIPT AND NOT PART OF THE BUNDLE
    =========================================================================
    It writes into docs/ and reads metadata. Both are engineering-only - see
    Common.Tools.ps1. It only ever RETRIEVES, never deploys, and it retrieves to
    a scratch folder under logs/tools/ rather than into sfdx/force-app, so it
    cannot disturb the tracked metadata.

    =========================================================================
    CURATED NOTES SURVIVE REGENERATION
    =========================================================================
    The generator produces all 200+ rows from the retrieved XML, but the facts
    worth knowing about a component are often NOT in the XML - that an API name
    contains a typo, that a field is Flow-populated, that an external ID holds
    a name rather than an ID. Hand-editing those into the document would make
    regeneration destructive, and the document's own instruction is to
    regenerate wholesale.

    So they live in changeset-inventory-notes.json, keyed "<Type>|<member>",
    and are merged in here. Same pattern as ldgcrm-manifest-ignore.json. Add a
    note there, not to the generated markdown.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ChangeSetName,

    # The org that BUILT the change set. See the header - this is deliberately
    # not the org you are verifying.
    [ValidateSet("Dev", "QA", "UAT", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (Common.Orgs.ps1).
    [string]$OrgAlias = "",

    # Relative to the repo root when not rooted.
    [string]$OutputPath = "docs\engineering\PRODUCTION-CHANGE-SET-INVENTORY.md",

    # Retrieve and report the component counts, but do not write the document.
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\Common.Tools.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\powershell-scripts\Common.ps1")

$OrgAlias = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

function Get-Text {
    <#
        One XML child element as trimmed text, or "" when absent. Guards the
        PS 5.1 case where $Node.$Name on a missing element returns $null and
        .Trim() then throws.
    #>
    param($Node, [string]$Name)

    if ($null -eq $Node) { return "" }

    $Value = $Node.$Name
    if ($null -eq $Value) { return "" }
    if ($Value -is [System.Xml.XmlElement]) { $Value = $Value.InnerText }

    return ([string]$Value).Trim()
}

function Format-Cell {
    <#
        Makes a value safe inside a markdown table cell: collapses the newlines
        that LongTextArea descriptions carry, and escapes the pipes that would
        otherwise silently split the row into extra columns.
    #>
    param([string]$Text, [int]$MaxLength = 0)

    if (-not $Text) { return "" }

    $Clean = ($Text -replace "\s+", " ").Trim()
    $Clean = $Clean -replace "\|", "\|"

    if ($MaxLength -gt 0 -and $Clean.Length -gt $MaxLength) {
        $Clean = $Clean.Substring(0, $MaxLength).TrimEnd() + "..."
    }

    return $Clean
}

function Get-CuratedNotes {
    <#
        Returns a hashtable of "<Type>|<member>" -> note text. Entries without a
        key (the file's leading comment object) are skipped.

        CONTRACT: returns a hashtable the caller uses as an object.
    #>
    param([string]$Path)

    $Notes = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "No curated notes file at $Path - generating without notes." -ForegroundColor Yellow
        return $Notes
    }

    foreach ($Entry in (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($Entry.key) { $Notes[$Entry.key] = $Entry.note }
    }

    return $Notes
}

function Add-Note {
    <#
        Appends a curated note to a generated description, keeping whichever
        parts exist. Either side may legitimately be empty.
    #>
    param([hashtable]$Notes, [string]$Key, [string]$Description)

    if (-not $Notes.ContainsKey($Key)) { return $Description }

    # The note is appended AFTER Format-Cell has run on the description, so it
    # has to escape its own pipes. A note documenting a composite key such as
    # <contactExtId>|<applicationExtId> otherwise splits its row into an extra
    # markdown column - silent, and only visible in the rendered table.
    $Note = $Notes[$Key] -replace "\|", "\|"

    if (-not $Description) { return $Note }

    return "$Description. $Note"
}

function Invoke-ChangeSetRetrieve {
    <#
        Retrieves the change set as an unmanaged package into $Destination and
        returns the folder holding package.xml.

        Runs from inside sfdx/ because `sf project retrieve start` needs
        sfdx-project.json in the working directory.
    #>
    param([string]$Name, [string]$Alias, [string]$Destination)

    $ProjectDir = Join-Path (Get-RepoRoot) "sfdx"

    if (-not (Test-Path -LiteralPath $ProjectDir)) {
        throw "Salesforce DX project not found at: $ProjectDir"
    }

    Push-Location $ProjectDir
    try {
        # Two separate traps in one call, both of which have bitten here.
        #
        # | Out-Host is REQUIRED, not cosmetic. A native command's stdout goes
        # to the function's OUTPUT stream, so without it sf's progress banner
        # becomes part of what this function returns and the caller's
        # $PackageRoot ends up as sf's console text - which then fails several
        # lines later inside Join-Path, blaming a drive that does not exist.
        #
        # No 2>&1 anywhere near this. PS 5.1 wraps a native command's stderr in
        # ErrorRecords, and sf writes its "update available" banner there, so a
        # redirect turns a harmless notice into a script-killing
        # NativeCommandError pointing at the wrong line.
        sf project retrieve start `
            --package-name $Name `
            --target-metadata-dir $Destination `
            --unzip `
            --target-org $Alias `
            --wait 30 | Out-Host

        if ($LASTEXITCODE -ne 0) {
            throw ("sf project retrieve start failed with exit code $LASTEXITCODE. " +
                   "If the error was INVALID_CROSS_REFERENCE_KEY, you are almost certainly " +
                   "pointed at the RECEIVING org - an inbound change set cannot be retrieved. " +
                   "Target the org that built it (see this script's header).")
        }
    }
    finally {
        Pop-Location
    }

    $Unpackaged = Join-Path $Destination "unpackaged"
    $Root = Join-Path $Unpackaged $Name

    # sf names the folder after the package, but falls back to "unpackaged" for
    # some shapes. Accept either rather than failing on a cosmetic difference.
    if (Test-Path -LiteralPath (Join-Path $Root "package.xml")) { return $Root }
    if (Test-Path -LiteralPath (Join-Path $Unpackaged "package.xml")) { return $Unpackaged }

    throw "Retrieved the change set but found no package.xml under $Unpackaged."
}

function Get-PackageTypes {
    <#
        package.xml as an ordered list of [PSCustomObject]@{ Name; Members }.

        CONTRACT: returns a plain array; wrap the call in @().
    #>
    param([string]$PackageRoot)

    [xml]$Package = Get-Content -LiteralPath (Join-Path $PackageRoot "package.xml") -Raw -Encoding UTF8

    $Types = @()
    foreach ($Type in $Package.Package.types) {
        $Types += [PSCustomObject]@{
            Name    = $Type.name
            Members = @($Type.members | Sort-Object)
        }
    }

    return $Types
}

function Read-ObjectDetail {
    <#
        Fields and list views out of the retrieved single-file .object metadata.

        CONTRACT: returns a hashtable the caller uses as an object.
    #>
    param([string]$PackageRoot)

    $Fields    = @()
    $ListViews = @()

    $ObjectDir = Join-Path $PackageRoot "objects"
    if (-not (Test-Path -LiteralPath $ObjectDir)) {
        return @{ Fields = $Fields; ListViews = $ListViews }
    }

    foreach ($File in (Get-ChildItem -LiteralPath $ObjectDir -Filter *.object)) {
        $ObjectName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        [xml]$Object = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        foreach ($Field in @($Object.CustomObject.fields)) {
            if ($null -eq $Field) { continue }

            # A formula field declares an ordinary <type> - Percent, Text,
            # Number - and is nonetheless rejected on write. The <formula> tag
            # is the only reliable tell, so surface it in the type column.
            $Type = Get-Text $Field "type"
            if (Get-Text $Field "formula") { $Type = "$Type (formula)" }

            $Attributes = @()
            $Length = Get-Text $Field "length"
            if ($Length) { $Attributes += "len $Length" }
            $ReferenceTo = Get-Text $Field "referenceTo"
            if ($ReferenceTo) { $Attributes += "-> ``$ReferenceTo``" }
            if ((Get-Text $Field "externalId") -eq "true") { $Attributes += "external ID" }
            if ((Get-Text $Field "unique") -eq "true") { $Attributes += "unique" }
            if ((Get-Text $Field "required") -eq "true") { $Attributes += "required" }
            $Rollup = Get-Text $Field "summaryOperation"
            if ($Rollup) { $Attributes += "rollup: $Rollup" }

            # Description first, inline help second. They are frequently
            # identical, so never concatenate them.
            $Description = Get-Text $Field "description"
            if (-not $Description) { $Description = Get-Text $Field "inlineHelpText" }

            $Fields += [PSCustomObject]@{
                Object      = $ObjectName
                ApiName     = Get-Text $Field "fullName"
                Label       = Get-Text $Field "label"
                Type        = $Type
                Attributes  = ($Attributes -join "; ")
                Description = $Description
            }
        }

        foreach ($View in @($Object.CustomObject.listViews)) {
            if ($null -eq $View) { continue }
            $ListViews += [PSCustomObject]@{
                Object  = $ObjectName
                ApiName = Get-Text $View "fullName"
                Label   = Get-Text $View "label"
            }
        }
    }

    return @{ Fields = $Fields; ListViews = $ListViews }
}

function Read-FlowDetail {
    <#
        CONTRACT: returns a plain array; wrap the call in @().
    #>
    param([string]$PackageRoot)

    $Flows = @()
    $Dir = Join-Path $PackageRoot "flows"
    if (-not (Test-Path -LiteralPath $Dir)) { return $Flows }

    foreach ($File in (Get-ChildItem -LiteralPath $Dir -Filter *.flow)) {
        [xml]$Flow = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
        $Start = $Flow.Flow.start

        $Trigger = @()
        $TriggerType = Get-Text $Start "triggerType"
        if ($TriggerType) { $Trigger += $TriggerType }
        $RecordTrigger = Get-Text $Start "recordTriggerType"
        if ($RecordTrigger) { $Trigger += $RecordTrigger }

        $Flows += [PSCustomObject]@{
            ApiName     = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
            Status      = Get-Text $Flow.Flow "status"
            Object      = Get-Text $Start "object"
            Trigger     = ($Trigger -join ", ")
            Description = Get-Text $Flow.Flow "description"
        }
    }

    return $Flows
}

function Read-SharingDetail {
    <#
        CONTRACT: returns a plain array; wrap the call in @().
    #>
    param([string]$PackageRoot)

    $Rules = @()
    $Dir = Join-Path $PackageRoot "sharingRules"
    if (-not (Test-Path -LiteralPath $Dir)) { return $Rules }

    foreach ($File in (Get-ChildItem -LiteralPath $Dir -Filter *.sharingRules)) {
        $ObjectName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        [xml]$Sharing = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        foreach ($Kind in @("sharingCriteriaRules", "sharingOwnerRules")) {
            foreach ($Rule in @($Sharing.SharingRules.$Kind)) {
                if ($null -eq $Rule) { continue }

                $SharedTo = ""
                if ($Rule.sharedTo) {
                    $SharedTo = ($Rule.sharedTo.ChildNodes | ForEach-Object { $_.InnerText }) -join ", "
                }
                $SharedFrom = ""
                if ($Rule.sharedFrom) {
                    $SharedFrom = ($Rule.sharedFrom.ChildNodes | ForEach-Object { $_.InnerText }) -join ", "
                }
                $Criteria = ""
                if ($Rule.criteriaItems) {
                    $Criteria = (@($Rule.criteriaItems) | ForEach-Object {
                        "$(Get-Text $_ 'field') $(Get-Text $_ 'operation') $(Get-Text $_ 'value')"
                    }) -join " AND "
                }

                $RuleKind = "Owner"
                if ($Kind -eq "sharingCriteriaRules") { $RuleKind = "Criteria" }

                $Rules += [PSCustomObject]@{
                    Object      = $ObjectName
                    Kind        = $RuleKind
                    ApiName     = Get-Text $Rule "fullName"
                    AccessLevel = Get-Text $Rule "accessLevel"
                    SharedFrom  = $SharedFrom
                    SharedTo    = $SharedTo
                    Criteria    = $Criteria
                    Description = Get-Text $Rule "description"
                }
            }
        }
    }

    return $Rules
}

function Read-PermissionSetDetail {
    <#
        CONTRACT: returns a plain array; wrap the call in @().
    #>
    param([string]$PackageRoot)

    $Sets = @()
    $Dir = Join-Path $PackageRoot "permissionsets"
    if (-not (Test-Path -LiteralPath $Dir)) { return $Sets }

    foreach ($File in (Get-ChildItem -LiteralPath $Dir -Filter *.permissionset)) {
        [xml]$Set = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
        $Sets += [PSCustomObject]@{
            ApiName     = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
            Label       = Get-Text $Set.PermissionSet "label"
            Description = Get-Text $Set.PermissionSet "description"
            FieldCount  = @($Set.PermissionSet.fieldPermissions).Count
        }
    }

    return $Sets
}

function Read-ReportTypeDetail {
    <#
        CONTRACT: returns a plain array; wrap the call in @().
    #>
    param([string]$PackageRoot)

    $Types = @()
    $Dir = Join-Path $PackageRoot "reportTypes"
    if (-not (Test-Path -LiteralPath $Dir)) { return $Types }

    foreach ($File in (Get-ChildItem -LiteralPath $Dir -Filter *.reportType)) {
        [xml]$Type = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
        $Types += [PSCustomObject]@{
            ApiName    = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
            Label      = Get-Text $Type.ReportType "label"
            BaseObject = Get-Text $Type.ReportType "baseObject"
        }
    }

    return $Types
}

function Read-GlobalValueSetDetail {
    <#
        CONTRACT: returns a plain array; wrap the call in @().
    #>
    param([string]$PackageRoot)

    $Sets = @()
    $Dir = Join-Path $PackageRoot "globalValueSets"
    if (-not (Test-Path -LiteralPath $Dir)) { return $Sets }

    foreach ($File in (Get-ChildItem -LiteralPath $Dir -Filter *.globalValueSet)) {
        [xml]$Set = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
        $Values = @($Set.GlobalValueSet.customValue | ForEach-Object { Get-Text $_ "fullName" })
        $Sets += [PSCustomObject]@{
            ApiName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
            Count   = $Values.Count
            Values  = ($Values -join "; ")
        }
    }

    return $Sets
}

# =============================================================================
# Document assembly
# =============================================================================

function New-InventoryDocument {
    param(
        [string]$Name,
        [string]$Alias,
        [string]$EnvironmentName,
        [string]$SnapshotDate,
        $Types,
        $Detail,
        [hashtable]$Notes
    )

    $Total = 0
    foreach ($Type in $Types) { $Total += $Type.Members.Count }

    $Lines = New-Object System.Collections.Generic.List[string]
    function Add-Line { param([string]$Text = "") $Lines.Add($Text) }

    Add-Line "# Production change set inventory"
    Add-Line ""
    Add-Line "> **Who this is for:** the **GSA IT Engineering team**, to verify that every component"
    Add-Line "> below is present and correct in the target org after the change set is deployed."
    Add-Line ">"
    Add-Line "> **Source change set:** ``$Name``"
    Add-Line ">"
    Add-Line "> **Snapshotted:** **$SnapshotDate**, from $EnvironmentName (``$Alias``)"
    Add-Line ">"
    Add-Line "> **Total: $Total components across $(@($Types).Count) metadata types.**"
    Add-Line ""
    Add-Line "---"
    Add-Line ""
    Add-Line "## About this snapshot"
    Add-Line ""
    Add-Line "This is a **point-in-time record of what ``$Name`` contains.** It is not maintained against"
    Add-Line "the org. When a new version of the change set is cut, **regenerate this file** rather than"
    Add-Line "editing it - a partially-updated inventory is worse than an obviously dated one, because the"
    Add-Line "reader cannot tell which rows were refreshed:"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line "tools\metadata\Export-ChangeSetInventory.ps1 -ChangeSetName `"$Name`""
    Add-Line '```'
    Add-Line ""
    Add-Line "**Provenance, stated precisely because it bounds what this proves.** The contents were read"
    Add-Line "by retrieving the change set from **$EnvironmentName (``$Alias``)**, the org that *built* it."
    Add-Line "It cannot be read from the receiving org: **an inbound change set is not retrievable**, and"
    Add-Line "Salesforce answers ``INVALID_CROSS_REFERENCE_KEY: No package named '$Name' found``. The"
    Add-Line "receiving org's inbound copy is the deployed form of this same outbound set and should match"
    Add-Line "component-for-component, but **that equivalence is an assumption this document does not"
    Add-Line "verify** - confirming it is the verification task itself."
    Add-Line ""
    Add-Line "Every count and description here was read from the retrieved XML, not from a Setup screen."
    Add-Line ""
    Add-Line "---"
    Add-Line ""

    # ---- Summary -------------------------------------------------------------
    Add-Line "## Summary by metadata type"
    Add-Line ""
    Add-Line "| Metadata type | Count |"
    Add-Line "| --- | ---: |"
    foreach ($Type in ($Types | Sort-Object { -$_.Members.Count }, Name)) {
        Add-Line "| $($Type.Name) | $($Type.Members.Count) |"
    }
    Add-Line "| **Total** | **$Total** |"
    Add-Line ""
    Add-Line "---"
    Add-Line ""

    # ---- Custom fields, grouped by object ------------------------------------
    $Fields = @($Detail.Fields)
    if ($Fields.Count -gt 0) {
        Add-Line "## Custom fields ($($Fields.Count))"
        Add-Line ""
        Add-Line "Descriptions are the field's own Description, falling back to its inline help text."
        Add-Line "``Attributes`` records length, lookup target, external-ID/unique/required flags and roll-up"
        Add-Line "operation where set. **A ``(formula)`` type is not writable** - Salesforce rejects direct"
        Add-Line "writes, and the declared type alone does not reveal it."
        Add-Line ""
        foreach ($Group in ($Fields | Group-Object Object | Sort-Object { $_.Group.Count }, Name)) {
            Add-Line "### $($Group.Name) ($($Group.Count))"
            Add-Line ""
            Add-Line "| API name | Label | Type | Attributes | Description |"
            Add-Line "| --- | --- | --- | --- | --- |"
            foreach ($Field in ($Group.Group | Sort-Object ApiName)) {
                $Description = Add-Note -Notes $Notes -Key "CustomField|$($Field.Object).$($Field.ApiName)" -Description (Format-Cell $Field.Description 220)
                Add-Line "| ``$($Field.ApiName)`` | $(Format-Cell $Field.Label) | $($Field.Type) | $($Field.Attributes) | $Description |"
            }
            Add-Line ""
        }
        Add-Line "---"
        Add-Line ""
    }

    # ---- Flows ---------------------------------------------------------------
    $Flows = @($Detail.Flows)
    if ($Flows.Count -gt 0) {
        Add-Line "## Flows ($($Flows.Count))"
        Add-Line ""
        Add-Line "The ``Status`` column is the status **in the change set XML**, which is not a guarantee of"
        Add-Line "the status after deployment - see the verification notes."
        Add-Line ""
        Add-Line "| API name | Status | Object | Trigger | Description |"
        Add-Line "| --- | --- | --- | --- | --- |"
        foreach ($Flow in ($Flows | Sort-Object ApiName)) {
            Add-Line "| ``$($Flow.ApiName)`` | $($Flow.Status) | $($Flow.Object) | $($Flow.Trigger) | $(Format-Cell $Flow.Description 200) |"
        }
        Add-Line ""
        Add-Line "---"
        Add-Line ""
    }

    # ---- Sharing -------------------------------------------------------------
    $Sharing = @($Detail.Sharing)
    if ($Sharing.Count -gt 0) {
        Add-Line "## Sharing rules ($($Sharing.Count))"
        Add-Line ""
        Add-Line "| Object | Kind | API name | Access | Shared from | Shared to | Criteria |"
        Add-Line "| --- | --- | --- | --- | --- | --- | --- |"
        foreach ($Rule in ($Sharing | Sort-Object Object, Kind, ApiName)) {
            Add-Line "| $($Rule.Object) | $($Rule.Kind) | ``$($Rule.ApiName)`` | $($Rule.AccessLevel) | $($Rule.SharedFrom) | $($Rule.SharedTo) | $(Format-Cell $Rule.Criteria) |"
        }
        Add-Line ""
    }

    # ---- Permission sets -----------------------------------------------------
    $PermissionSets = @($Detail.PermissionSets)
    if ($PermissionSets.Count -gt 0) {
        Add-Line "## Permission sets ($($PermissionSets.Count))"
        Add-Line ""
        Add-Line "| API name | Label | Description | Field permissions |"
        Add-Line "| --- | --- | --- | ---: |"
        foreach ($Set in ($PermissionSets | Sort-Object ApiName)) {
            Add-Line "| ``$($Set.ApiName)`` | $(Format-Cell $Set.Label) | $(Format-Cell $Set.Description) | $($Set.FieldCount) |"
        }
        Add-Line ""
    }

    # ---- Report types --------------------------------------------------------
    $ReportTypes = @($Detail.ReportTypes)
    if ($ReportTypes.Count -gt 0) {
        Add-Line "## Report types ($($ReportTypes.Count))"
        Add-Line ""
        Add-Line "| API name | Label | Base object |"
        Add-Line "| --- | --- | --- |"
        foreach ($Type in ($ReportTypes | Sort-Object ApiName)) {
            Add-Line "| ``$($Type.ApiName)`` | $(Format-Cell $Type.Label) | $($Type.BaseObject) |"
        }
        Add-Line ""
    }

    # ---- List views ----------------------------------------------------------
    $ListViews = @($Detail.ListViews)
    if ($ListViews.Count -gt 0) {
        Add-Line "## List views ($($ListViews.Count))"
        Add-Line ""
        Add-Line "| Object | API name | Label |"
        Add-Line "| --- | --- | --- |"
        foreach ($View in ($ListViews | Sort-Object Object, ApiName)) {
            Add-Line "| $($View.Object) | ``$($View.ApiName)`` | $(Format-Cell $View.Label) |"
        }
        Add-Line ""
    }

    # ---- Global value sets ---------------------------------------------------
    $ValueSets = @($Detail.GlobalValueSets)
    if ($ValueSets.Count -gt 0) {
        Add-Line "## Global value sets ($($ValueSets.Count))"
        Add-Line ""
        foreach ($Set in ($ValueSets | Sort-Object ApiName)) {
            Add-Line "**``$($Set.ApiName)``** - $($Set.Count) values: $(Format-Cell $Set.Values)"
            Add-Line ""
        }
    }

    # ---- Everything else, as name lists --------------------------------------
    # Driven off package.xml rather than a fixed list, so a metadata type this
    # script has never seen still gets a heading instead of vanishing.
    $Detailed = @("CustomField", "ListView", "Flow", "SharingCriteriaRule",
                  "SharingOwnerRule", "PermissionSet", "ReportType", "GlobalValueSet")

    $Remaining = @($Types | Where-Object { $Detailed -notcontains $_.Name })
    if ($Remaining.Count -gt 0) {
        Add-Line "---"
        Add-Line ""
        Add-Line "## Remaining components"
        Add-Line ""
        foreach ($Type in ($Remaining | Sort-Object Name)) {
            Add-Line "### $($Type.Name) ($($Type.Members.Count))"
            Add-Line ""
            Add-Line "| Component | Notes |"
            Add-Line "| --- | --- |"
            foreach ($Member in $Type.Members) {
                $Readable = $Member -replace "%2E", "." -replace "%2F", "/"
                $Note = ""
                if ($Notes.ContainsKey("$($Type.Name)|$Member")) { $Note = $Notes["$($Type.Name)|$Member"] }
                Add-Line "| ``$Readable`` | $Note |"
            }
            Add-Line ""
        }
    }

    # ---- Verification notes (static) ----------------------------------------
    Add-Line "---"
    Add-Line ""
    Add-Line "## Verification notes"
    Add-Line ""
    Add-Line "Five ways a component looks deployed when it is not, or the reverse. Each has cost time on"
    Add-Line "this project."
    Add-Line ""
    Add-Line "1. **A Flow can be Active in the change set and land as Draft in the target.** All of the"
    Add-Line "   flows above once landed in QA as Draft, and the migration still ran to completion - 8,740"
    Add-Line "   records, zero failures, every object count matching - because flow activation changes"
    Add-Line "   field *contents*, not row counts. **Verify status in the target org, not against this"
    Add-Line "   document:** ``SELECT ApiName, IsActive FROM FlowDefinitionView WHERE ApiName LIKE"
    Add-Line "   'LDGCRM%'``, then **repeat it for ``'LGDCRM%'``** - some flows use a transposed prefix, and"
    Add-Line "   a single ``LIKE '%DGCRM%'`` matches neither reliably."
    Add-Line "2. **A change set cannot delete anything.** Components removed in the source org survive in"
    Add-Line "   the target and appear in no deployment report. They must be deleted by hand in Setup."
    Add-Line "3. **A profile is merged, not replaced.** Permissions already in the target's profile stay,"
    Add-Line '   so "deployed successfully" does not mean the target profile matches the source.'
    Add-Line "4. **Record-type picklist narrowing is enforced on load and is invisible to ``sf sobject"
    Add-Line "   describe``,** which reports field-level values only. Read"
    Add-Line "   ``objects/<Object>/recordTypes/<RecordType>.recordType-meta.xml`` instead - its ``fullName``"
    Add-Line "   entries are URL-encoded (``,``->``%2C``, ``/``->``%2F``, ``&``->``%26``)."
    Add-Line "5. **A metadata deploy deactivates a picklist value rather than deleting it,** and"
    Add-Line "   ``sf sobject describe`` hides inactive values - so a field can look clean while the old"
    Add-Line "   value is still in the value set. The retrieved metadata file is the authority."
    Add-Line ""

    return ($Lines -join "`r`n")
}

# =============================================================================
# Main
# =============================================================================

Start-ToolLog -ScriptName "Export-ChangeSetInventory" | Out-Null

try {
    if (-not (Get-Command sf -ErrorAction SilentlyContinue)) {
        Write-Error "Salesforce CLI (sf) is not installed or not in your PATH."
        exit 1
    }

    Assert-LdgcrmOrgTarget -Environment $Environment -OrgAlias $OrgAlias | Out-Null

    Write-Host ""
    Write-Host "Change set : $ChangeSetName" -ForegroundColor Cyan
    Write-Host "Source org : $OrgAlias ($Environment)" -ForegroundColor Cyan
    Write-Host ""

    # Deliberately NOT Get-LogDirectory. That helper returns the run directory
    # while one is open, but falls back to scripts/logs/<category> otherwise -
    # inside the Operations bundle, which engineering-only output must never
    # enter. Start-ToolLog has already published the run directory under
    # logs/tools/, so read it directly and keep the fallback impossible.
    $RunDirectory = Get-LdgcrmRunDirectory
    if (-not $RunDirectory) { throw "Start-ToolLog did not publish a run directory." }

    $Scratch = Join-Path $RunDirectory "changeset"
    $PackageRoot = Invoke-ChangeSetRetrieve -Name $ChangeSetName -Alias $OrgAlias -Destination $Scratch

    $Types = @(Get-PackageTypes -PackageRoot $PackageRoot)
    $ObjectDetail = Read-ObjectDetail -PackageRoot $PackageRoot

    $Detail = @{
        Fields          = @($ObjectDetail.Fields)
        ListViews       = @($ObjectDetail.ListViews)
        Flows           = @(Read-FlowDetail -PackageRoot $PackageRoot)
        Sharing         = @(Read-SharingDetail -PackageRoot $PackageRoot)
        PermissionSets  = @(Read-PermissionSetDetail -PackageRoot $PackageRoot)
        ReportTypes     = @(Read-ReportTypeDetail -PackageRoot $PackageRoot)
        GlobalValueSets = @(Read-GlobalValueSetDetail -PackageRoot $PackageRoot)
    }

    $Total = 0
    foreach ($Type in $Types) { $Total += $Type.Members.Count }

    Write-Host "Retrieved $Total components across $(@($Types).Count) metadata types." -ForegroundColor Green
    foreach ($Type in ($Types | Sort-Object Name)) {
        Write-Host ("  {0,-24} {1}" -f $Type.Name, $Type.Members.Count)
    }

    # A member in package.xml with no matching row in the document would be a
    # silent omission - exactly the failure this inventory exists to prevent -
    # so prove coverage rather than trusting the counts.
    $DeclaredFields = 0
    foreach ($Type in $Types) { if ($Type.Name -eq "CustomField") { $DeclaredFields = $Type.Members.Count } }
    if ($DeclaredFields -ne @($Detail.Fields).Count) {
        Write-Warning ("package.xml declares $DeclaredFields CustomField members but " +
                       "$(@($Detail.Fields).Count) were parsed from the .object files. " +
                       "The document would be incomplete.")
    }

    if ($WhatIf) {
        Write-Host ""
        Write-Host "-WhatIf: not writing the document." -ForegroundColor Yellow
        return
    }

    $Notes = Get-CuratedNotes -Path (Join-Path $PSScriptRoot "changeset-inventory-notes.json")

    $Resolved = $OutputPath
    if (-not [System.IO.Path]::IsPathRooted($Resolved)) {
        $Resolved = Join-Path (Get-RepoRoot) $OutputPath
    }

    $Document = New-InventoryDocument `
        -Name $ChangeSetName `
        -Alias $OrgAlias `
        -EnvironmentName $Environment `
        -SnapshotDate (Get-Date -Format "yyyy-MM-dd") `
        -Types $Types `
        -Detail $Detail `
        -Notes $Notes

    # UTF-8 WITHOUT a BOM. Set-Content/Out-File in PS 5.1 are inconsistent about
    # this, and a BOM at the top of a markdown file shows up as stray characters
    # in some renderers and in a git diff.
    [System.IO.File]::WriteAllText($Resolved, $Document, (New-Object System.Text.UTF8Encoding $false))

    Write-Host ""
    Write-Host "Wrote $Resolved" -ForegroundColor Green
    Write-Host "Retrieved metadata kept at $PackageRoot" -ForegroundColor DarkGray
}
finally {
    Stop-ToolLog
}
