#Requires -Version 5.1
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\Common.Tools.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\powershell-scripts\Common.ps1")

<#
    Compares LDGCRM_ custom fields defined on each object (source of truth:
    sfdx/force-app/main/default/objects/) against the fields actually placed
    on that object's classic Page Layout(s) and/or Lightning Record Page(s)
    (flexipages), to surface fields that exist but aren't shown to users on
    either surface.

    This is a static metadata comparison against the locally synced
    force-app tree (no org connection required) - see CLAUDE.md's note that
    force-app is the source of truth, synced from the LDGCRM_Sprint_1_12
    change set.
#>

# Objects documented in CLAUDE.md's data model as carrying LDGCRM_ custom fields.
$ObjectApiNames = @(
    "Account",
    "Contact",
    "Opportunity",
    "OpportunityContactRole",
    "Activity",
    "LDGCRM_application__c",
    "LDGCRM_Application_Contact__c",
    "LDGCRM_Impediment__c",
    "LDGCRM_Market_Segment__c",
    "LDGCRM_Opportunity_Impediment__c",
    "LDGCRM_Partner_Account__c"
)

$RepoRoot = Get-RepoRoot
$DefaultDir = Join-Path $RepoRoot "sfdx/force-app/main/default"
$ObjectsDir = Join-Path $DefaultDir "objects"
$LayoutsDir = Join-Path $DefaultDir "layouts"
$FlexiPagesDir = Join-Path $DefaultDir "flexipages"

$Timestamp = Start-ScriptLog -Category "metadata" -ScriptName "Find-UnexposedLDGCRMFields"
$OutputFile = Join-Path (Get-LogDirectory -Category "metadata") "UnexposedLDGCRMFields-$Timestamp.csv"

function Get-FieldNamesFromXml {
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlDocument]$Xml,

        [Parameter(Mandatory = $true)]
        [string]$LocalName
    )

    $Nodes = $Xml.SelectNodes("//*[local-name()='$LocalName']")
    return @($Nodes | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ })
}

try {
    Write-Host "Pre-loading flexipages from $FlexiPagesDir..." -ForegroundColor Cyan

    $FlexiPageDocs = @()
    if (Test-Path $FlexiPagesDir) {
        foreach ($File in Get-ChildItem $FlexiPagesDir -Filter "*.flexipage-meta.xml") {
            [xml]$Doc = Get-Content -Raw $File.FullName
            $SobjectNode = $Doc.SelectSingleNode("//*[local-name()='sobjectType']")
            $FlexiPageDocs += [PSCustomObject]@{
                FileName    = $File.Name
                SobjectType = if ($SobjectNode) { $SobjectNode.InnerText.Trim() } else { $null }
                Xml         = $Doc
            }
        }
    }

    $Results = New-Object System.Collections.Generic.List[object]
    $ObjectSummaries = New-Object System.Collections.Generic.List[object]

    foreach ($ObjectApiName in $ObjectApiNames) {
        Write-Host ""
        Write-Host "== $ObjectApiName ==" -ForegroundColor Cyan

        $FieldsDir = Join-Path $ObjectsDir "$ObjectApiName/fields"
        if (-not (Test-Path $FieldsDir)) {
            Write-Warning "No fields/ directory found for $ObjectApiName - skipping."
            continue
        }

        $CustomFieldFiles = Get-ChildItem $FieldsDir -Filter "*.field-meta.xml" |
            Where-Object { $_.Name -match '^LDGCRM_' }

        if (-not $CustomFieldFiles) {
            Write-Host "No LDGCRM_ custom fields defined on $ObjectApiName." -ForegroundColor DarkGray
            continue
        }

        # Classic page layout(s): filename convention is "<ObjectApiName>-<Layout Name>.layout-meta.xml".
        $LayoutFiles = @()
        if (Test-Path $LayoutsDir) {
            $LayoutFiles = Get-ChildItem $LayoutsDir -Filter "$ObjectApiName-*.layout-meta.xml"
        }

        $LayoutExposedFields = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($LayoutFile in $LayoutFiles) {
            [xml]$LayoutXml = Get-Content -Raw $LayoutFile.FullName
            foreach ($FieldName in (Get-FieldNamesFromXml -Xml $LayoutXml -LocalName "field")) {
                [void]$LayoutExposedFields.Add($FieldName)
            }
        }

        # Lightning Record Page(s): matched by <sobjectType> rather than filename,
        # since flexipage names don't follow a fixed "<Object>-..." convention.
        $MatchingFlexiPages = @($FlexiPageDocs | Where-Object { $_.SobjectType -eq $ObjectApiName })

        $FlexiPageExposedFields = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($FlexiPage in $MatchingFlexiPages) {
            $FieldItems = Get-FieldNamesFromXml -Xml $FlexiPage.Xml -LocalName "fieldItem"
            foreach ($FieldItem in $FieldItems) {
                # Only direct fields on this record ("Record.Field__c"), not fields
                # walked through a relationship ("Record.Rel__r.Field__c"), which
                # belong to the related object, not this one.
                if ($FieldItem -match '^Record\.([A-Za-z0-9_]+)$') {
                    [void]$FlexiPageExposedFields.Add($Matches[1])
                }
            }
        }

        $HasLayoutMetadata = $LayoutFiles.Count -gt 0
        $HasFlexiPageMetadata = $MatchingFlexiPages.Count -gt 0
        $UnexposedCount = 0

        foreach ($FieldFile in $CustomFieldFiles) {
            $FieldApiName = $FieldFile.Name -replace '\.field-meta\.xml$', ''

            [xml]$FieldXml = Get-Content -Raw $FieldFile.FullName
            $FieldLabel = $FieldXml.CustomField.label
            $FieldType = $FieldXml.CustomField.type

            $OnLayout = $LayoutExposedFields.Contains($FieldApiName)
            $OnFlexiPage = $FlexiPageExposedFields.Contains($FieldApiName)
            $Exposed = $OnLayout -or $OnFlexiPage

            $Notes = if (-not $HasLayoutMetadata -and -not $HasFlexiPageMetadata) {
                "No layout or flexipage metadata synced locally for this object - verify directly in the org."
            }
            elseif (-not $Exposed) {
                $UnexposedCount++
                "Not present on any synced layout or Lightning record page."
            }
            else {
                ""
            }

            $Results.Add([PSCustomObject]@{
                Object              = $ObjectApiName
                FieldApiName        = $FieldApiName
                FieldLabel          = $FieldLabel
                FieldType           = $FieldType
                OnPageLayout        = $OnLayout
                OnLightningPage     = $OnFlexiPage
                Exposed             = $Exposed
                LayoutFilesChecked  = ($LayoutFiles.Name -join "; ")
                FlexiPageFilesChecked = ($MatchingFlexiPages.FileName -join "; ")
                Notes               = $Notes
            })
        }

        $ObjectSummaries.Add([PSCustomObject]@{
            Object              = $ObjectApiName
            CustomFieldCount    = $CustomFieldFiles.Count
            UnexposedCount      = $UnexposedCount
            HasLayoutMetadata   = $HasLayoutMetadata
            HasFlexiPageMetadata = $HasFlexiPageMetadata
        })

        if (-not $HasLayoutMetadata -and -not $HasFlexiPageMetadata) {
            Write-Warning "$ObjectApiName - no layout or flexipage metadata synced locally; skipped exposure check for $($CustomFieldFiles.Count) field(s)."
        }
        elseif ($UnexposedCount -gt 0) {
            Write-Host "$UnexposedCount of $($CustomFieldFiles.Count) LDGCRM_ field(s) not exposed on any layout or record page." -ForegroundColor Yellow
        }
        else {
            Write-Host "All $($CustomFieldFiles.Count) LDGCRM_ field(s) exposed." -ForegroundColor Green
        }
    }

    $Results |
        Sort-Object Object, FieldApiName |
        Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "Summary by object:" -ForegroundColor Cyan
    $ObjectSummaries | Format-Table -AutoSize | Out-String | Write-Host

    Write-Host "Fields not exposed on any layout or Lightning record page:" -ForegroundColor Yellow
    $Results |
        Where-Object { $_.Notes -eq "Not present on any synced layout or Lightning record page." } |
        Format-Table Object, FieldApiName, FieldLabel, FieldType -AutoSize |
        Out-String | Write-Host

    Write-Host "Export complete:" -ForegroundColor Green
    Write-Host $OutputFile -ForegroundColor Green
}
finally {
    Stop-ScriptLog
}
