#Requires -Version 7.0
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")

# =========================
# CONFIGURATION
# =========================

$OrgAlias = "gsa-peo"
$AppApiName = "LDGCRM_Login_Gov_CRM_App"
$UtilityBarApiName = "Login_gov_CRM_UtilityBar"
$ProjectDir = Join-Path (Get-RepoRoot) "sfdx"

Start-ScriptLog -Category "metadata" -ScriptName "Inspect-SalesforceApp" | Out-Null

try {
    # =========================
    # CHECK SALESFORCE CLI
    # =========================

    Write-Host ""
    Write-Host "Checking Salesforce CLI..."

    if (-not (Get-Command sf -ErrorAction SilentlyContinue)) {
        Write-Error "Salesforce CLI (sf) is not installed or not in your PATH."
        exit 1
    }

    sf --version

    # =========================
    # CONFIRM PROJECT AND ORG
    # =========================

    if (-not (Test-Path $ProjectDir)) {
        Write-Error "Salesforce DX project not found at: $ProjectDir"
        exit 1
    }

    Push-Location $ProjectDir

    Write-Host ""
    Write-Host "Using org alias: $OrgAlias"
    Write-Host "Checking org connection..."

    sf org display --target-org $OrgAlias

    # =========================
    # RETRIEVE LIGHTNING APP
    # =========================

    Write-Host ""
    Write-Host "Retrieving Lightning App metadata..."

    sf project retrieve start `
        --metadata "CustomApplication:$AppApiName" `
        --target-org $OrgAlias

    # =========================
    # RETRIEVE UTILITY BAR
    # =========================

    Write-Host ""
    Write-Host "Retrieving Utility Bar FlexiPage metadata..."

    sf project retrieve start `
        --metadata "FlexiPage:$UtilityBarApiName" `
        --target-org $OrgAlias

    # =========================
    # FILE PATHS
    # =========================

    $ForceAppDefault = Join-Path (Join-Path "force-app" "main") "default"
    $AppFile = Join-Path (Join-Path $ForceAppDefault "applications") "$AppApiName.app-meta.xml"
    $UtilityFile = Join-Path (Join-Path $ForceAppDefault "flexipages") "$UtilityBarApiName.flexipage-meta.xml"

    Write-Host ""
    Write-Host "======================================"
    Write-Host "Retrieved metadata"
    Write-Host "======================================"

    if (Test-Path $AppFile) {
        Write-Host "App:"
        Write-Host $AppFile
    }
    else {
        Write-Warning "App metadata file was not found."
    }

    Write-Host ""

    if (Test-Path $UtilityFile) {
        Write-Host "Utility Bar:"
        Write-Host $UtilityFile
    }
    else {
        Write-Warning "Utility Bar FlexiPage metadata file was not found."
    }

    # =========================
    # INSPECT APP REFERENCE
    # =========================

    Write-Host ""
    Write-Host "======================================"
    Write-Host "Utility Bar references in App metadata"
    Write-Host "======================================"

    if (Test-Path $AppFile) {
        Select-String `
            -Path $AppFile `
            -Pattern "utilityBar" `
            -Context 3, 3
    }

    # =========================
    # SEARCH ALL RETRIEVED METADATA
    # =========================

    Write-Host ""
    Write-Host "======================================"
    Write-Host "All references to $UtilityBarApiName"
    Write-Host "======================================"

    Get-ChildItem `
        -Path $ForceAppDefault `
        -Recurse `
        -File |
        Select-String `
            -Pattern $UtilityBarApiName `
            -Context 2, 2

    # =========================
    # SHOW FLEXIPAGE
    # =========================

    Write-Host ""
    Write-Host "======================================"
    Write-Host "Utility Bar FlexiPage metadata"
    Write-Host "======================================"

    if (Test-Path $UtilityFile) {
        Get-Content $UtilityFile
    }

    Write-Host ""
    Write-Host "======================================"
    Write-Host "Inspection complete"
    Write-Host "======================================"
    Write-Host ""
    Write-Host "Nothing was modified or deployed."
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    Stop-ScriptLog
}
