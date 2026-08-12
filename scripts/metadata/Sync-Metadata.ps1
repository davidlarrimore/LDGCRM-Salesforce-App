#Requires -Version 7.0
<#
    Pulls the metadata listed in sfdx/manifest/package.xml from the
    sandbox into sfdx/force-app, using the Salesforce CLI. Extend the
    manifest as the app grows - this script just runs it.

    Usage:
        pwsh scripts/metadata/Sync-Metadata.ps1
        pwsh scripts/metadata/Sync-Metadata.ps1 -OrgAlias gsa-peo
#>
param(
    [string]$OrgAlias = "gsa-peo"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")

Start-ScriptLog -Category "metadata" -ScriptName "Sync-Metadata" | Out-Null

try {
    $ProjectDir = Join-Path (Get-RepoRoot) "sfdx"

    if (-not (Get-Command sf -ErrorAction SilentlyContinue)) {
        Write-Error "Salesforce CLI (sf) is not installed or not in your PATH."
        exit 1
    }

    if (-not (Test-Path $ProjectDir)) {
        Write-Error "Salesforce DX project not found at: $ProjectDir"
        exit 1
    }

    Push-Location $ProjectDir

    Write-Host "Target org alias: $OrgAlias" -ForegroundColor Cyan
    sf org display --target-org $OrgAlias

    Write-Host ""
    Write-Host "Retrieving metadata from manifest/package.xml..." -ForegroundColor Cyan

    sf project retrieve start `
        --manifest "manifest/package.xml" `
        --target-org $OrgAlias

    if ($LASTEXITCODE -ne 0) {
        throw "sf project retrieve start failed with exit code $LASTEXITCODE."
    }

    Write-Host ""
    Write-Host "Retrieve complete. Review changes with:" -ForegroundColor Green
    Write-Host "  git status sfdx/force-app"
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    Stop-ScriptLog
}
