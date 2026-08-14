#Requires -Version 5.1
param(
    [ValidateSet("Dev", "QA", "Full", "Prod")]
    [string]$Environment = "Dev",

    # Empty = use the environment's registered alias (scripts/powershell-scripts/Common.Orgs.ps1).
    [string]$OrgAlias = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\Common.Tools.ps1")
. (Join-Path $PSScriptRoot "..\..\scripts\powershell-scripts\Common.ps1")

$TargetOrg = Resolve-LdgcrmOrgAlias -Environment $Environment -OrgAlias $OrgAlias

# Standard Salesforce objects to include.
# Salesforce Activities are represented by Task and Event.
$ObjectApiNames = @(
    "Account",
    "Contact",
    "User",
    "Opportunity",
    "Task",
    "Event"
)

# Custom objects to locate by their Salesforce labels.
$CustomObjectLabels = @(
    "Impediment",
    "Market Segment",
    "Partner Account",
    "Opportunity Impediments",
    "Application"
)

$Timestamp = Start-ToolLog -ScriptName "Get-LDGCRMDataDictionary"
$OutputFile = Join-Path (Get-LdgcrmRunDirectory) "SalesforceObjectsAndFields-$Timestamp.csv"

try {
    Write-Host "Finding custom objects..." -ForegroundColor Cyan

    $EntityQuery = @"
SELECT QualifiedApiName, Label
FROM EntityDefinition
WHERE QualifiedApiName LIKE 'LDGCRM_%'
ORDER BY Label
"@

    # NO 2>$null - see the note in Sync-Metadata.ps1 and CLAUDE.md's PowerShell
    # 5.1 traps. Redirecting a native command's stderr turns the sf CLI's
    # harmless "update available" banner into a terminating NativeCommandError.
    # The JSON is on stdout and is captured either way.
    $EntityResponse = sf data query `
        --target-org $TargetOrg `
        --use-tooling-api `
        --query $EntityQuery `
        --json

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Unable to retrieve the custom-object list from Salesforce."
        exit 1
    }

    $EntityData = $EntityResponse | ConvertFrom-Json
    $AvailableObjects = $EntityData.result.records

    foreach ($RequestedLabel in $CustomObjectLabels) {
        $MatchingObject = $AvailableObjects |
            Where-Object {
                $_.Label -eq $RequestedLabel -and
                $_.QualifiedApiName -like "*__c"
            } |
            Select-Object -First 1

        if ($MatchingObject) {
            Write-Host "Found $RequestedLabel -> $($MatchingObject.QualifiedApiName)" `
                -ForegroundColor Green

            $ObjectApiNames += $MatchingObject.QualifiedApiName
        }
        else {
            Write-Warning "Could not find a custom object with label: $RequestedLabel"
        }
    }

    $Results = foreach ($ObjectApiName in ($ObjectApiNames | Select-Object -Unique)) {
        Write-Host "Reading $ObjectApiName..." -ForegroundColor Cyan

        $DescribeResponse = sf sobject describe `
            --sobject $ObjectApiName `
            --target-org $TargetOrg `
            --json

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not describe object: $ObjectApiName"
            continue
        }

        $DescribeData = $DescribeResponse | ConvertFrom-Json
        $ObjectMetadata = $DescribeData.result

        foreach ($Field in $ObjectMetadata.fields) {
            [PSCustomObject]@{
                ObjectLabel       = $ObjectMetadata.label
                ObjectApiName     = $ObjectMetadata.name
                ObjectIsCustom    = $ObjectMetadata.custom
                FieldLabel        = $Field.label
                FieldApiName      = $Field.name
                DataType          = $Field.type
                FieldIsCustom     = $Field.custom
                Required          = (-not $Field.nillable -and -not $Field.defaultedOnCreate)
                Length            = $Field.length
                Precision         = $Field.precision
                Scale             = $Field.scale
                Createable        = $Field.createable
                Updateable        = $Field.updateable
                ReferenceTo       = ($Field.referenceTo -join "; ")
                RelationshipName  = $Field.relationshipName
                Calculated        = $Field.calculated
                Unique            = $Field.unique
                ExternalId        = $Field.externalId
            }
        }
    }

    if (-not $Results) {
        Write-Error "No field metadata was retrieved."
        exit 1
    }

    $Results |
        Sort-Object ObjectLabel, FieldLabel |
        Export-Csv `
            -Path $OutputFile `
            -NoTypeInformation `
            -Encoding UTF8

    Write-Host ""
    Write-Host "Export complete:" -ForegroundColor Green
    Write-Host $OutputFile -ForegroundColor Green
    Write-Host "Objects exported: $(($Results.ObjectApiName | Select-Object -Unique).Count)"
    Write-Host "Fields exported: $($Results.Count)"
}
finally {
    Stop-ToolLog
}
