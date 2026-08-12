#Requires -Version 5.1
<#
    Pulls the metadata listed in sfdx/manifest/package.xml from the sandbox
    into sfdx/force-app, using the Salesforce CLI.

    Before retrieving, this also checks the sandbox for anything that looks
    like it belongs to the LDGCRM app (by naming convention: an "LDGCRM_" or
    "LGDCRM_" component) but isn't yet listed in the manifest, and adds it
    automatically. This sandbox hosts several unrelated apps (FCIC, standard
    Salesforce apps, etc.) that share the same metadata types, so anything
    that DOESN'T match the naming convention is reported instead of added -
    review it and either add a <members> entry by hand, or record it in
    ldgcrm-manifest-ignore.json if it's confirmed unrelated (see that file
    for the running list of known false positives).

    Usage:
        powershell scripts/metadata/Sync-Metadata.ps1
        powershell scripts/metadata/Sync-Metadata.ps1 -OrgAlias gsa-peo
        powershell scripts/metadata/Sync-Metadata.ps1 -WhatIf          # report only; no manifest edit, no retrieve
        powershell scripts/metadata/Sync-Metadata.ps1 -SkipDiscovery   # retrieve the manifest as-is, skip the scan
#>
param(
    [string]$OrgAlias = "gsa-peo",
    [switch]$WhatIf,
    [switch]$SkipDiscovery
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\common\Common.ps1")

# Anything found in the org that matches this pattern - and isn't already a
# manifest member or in the ignore list - is assumed to be a new LDGCRM
# component and gets added automatically. Everything else is reported for
# manual review rather than guessed at.
$RelevancePattern = '(?i)ldgcrm|lgdcrm'

function Get-IgnoredComponents {
    param([string]$Path)

    $Ignored = @{}
    if (Test-Path $Path) {
        foreach ($Entry in (Get-Content $Path -Raw | ConvertFrom-Json)) {
            $Ignored["$($Entry.type)|$($Entry.name)"] = $Entry.reason
        }
    }
    return $Ignored
}

function Update-ManifestDiscovery {
    param(
        [string]$ManifestPath,
        [string]$OrgAlias,
        [hashtable]$Ignored,
        [switch]$WhatIf
    )

    [xml]$Manifest = Get-Content $ManifestPath -Raw
    $ManifestLines = [System.Collections.Generic.List[string]](Get-Content $ManifestPath)

    $AutoAdded = [System.Collections.Generic.List[string]]::new()
    $NeedsReview = [System.Collections.Generic.List[string]]::new()

    foreach ($TypeNode in $Manifest.Package.types) {
        $TypeName = $TypeNode.name
        $ExistingMembers = @($TypeNode.members)

        if ($ExistingMembers -contains "*") {
            continue
        }

        Write-Host "Checking $TypeName..." -ForegroundColor Cyan

        $ListResult = sf org list metadata --metadata-type $TypeName --target-org $OrgAlias --json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $ListResult) {
            Write-Warning "Could not list metadata for type '$TypeName' - skipping."
            continue
        }

        $Parsed = $ListResult | ConvertFrom-Json
        $OrgComponents = @($Parsed.result | ForEach-Object { $_.fullName } | Where-Object { $_ })
        $NewComponents = $OrgComponents | Where-Object { $ExistingMembers -notcontains $_ } | Sort-Object -Unique

        foreach ($Name in $NewComponents) {
            if ($Ignored.ContainsKey("$TypeName|$Name")) {
                continue
            }

            if ($Name -match $RelevancePattern) {
                $AutoAdded.Add("${TypeName}: $Name")

                if (-not $WhatIf) {
                    $NameLinePattern = "^(\s*)<name>$([regex]::Escape($TypeName))</name>\s*$"
                    for ($i = 0; $i -lt $ManifestLines.Count; $i++) {
                        if ($ManifestLines[$i] -match $NameLinePattern) {
                            $Indent = $Matches[1]
                            $ManifestLines.Insert($i, "$Indent<members>$Name</members>")
                            break
                        }
                    }
                }
            }
            else {
                $NeedsReview.Add("${TypeName}: $Name")
            }
        }
    }

    Write-Host ""
    if ($AutoAdded.Count -gt 0) {
        $Verb = if ($WhatIf) { "Would add" } else { "Added" }
        Write-Host "$Verb $($AutoAdded.Count) new LDGCRM component(s) to the manifest:" -ForegroundColor Green
        $AutoAdded | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green }
    }
    else {
        Write-Host "No new LDGCRM-named components found." -ForegroundColor Green
    }

    if ($NeedsReview.Count -gt 0) {
        Write-Host ""
        Write-Host "$($NeedsReview.Count) new component(s) don't match the LDGCRM naming convention - not added automatically:" -ForegroundColor Yellow
        $NeedsReview | ForEach-Object { Write-Host "  ? $_" -ForegroundColor Yellow }
        Write-Host "If any of these belong to LDGCRM, add a <members> entry by hand in manifest/package.xml." -ForegroundColor Yellow
        Write-Host "Otherwise, add them to scripts/metadata/ldgcrm-manifest-ignore.json so they stop resurfacing." -ForegroundColor Yellow
    }

    if ($AutoAdded.Count -gt 0 -and -not $WhatIf) {
        Set-Content -Path $ManifestPath -Value $ManifestLines
        Write-Host ""
        Write-Host "Manifest updated: $ManifestPath" -ForegroundColor Green
    }

    return $AutoAdded.Count
}

Start-ScriptLog -Category "metadata" -ScriptName "Sync-Metadata" | Out-Null

try {
    $ProjectDir = Join-Path (Get-RepoRoot) "sfdx"
    $ManifestPath = Join-Path $ProjectDir "manifest/package.xml"
    $IgnorePath = Join-Path $PSScriptRoot "ldgcrm-manifest-ignore.json"

    if (-not (Get-Command sf -ErrorAction SilentlyContinue)) {
        Write-Error "Salesforce CLI (sf) is not installed or not in your PATH."
        exit 1
    }

    if (-not (Test-Path $ProjectDir)) {
        Write-Error "Salesforce DX project not found at: $ProjectDir"
        exit 1
    }

    Write-Host "Target org alias: $OrgAlias" -ForegroundColor Cyan
    Push-Location $ProjectDir
    try {
        sf org display --target-org $OrgAlias
    }
    finally {
        Pop-Location
    }

    if (-not $SkipDiscovery) {
        Write-Host ""
        Write-Host "Scanning $OrgAlias for new LDGCRM components not yet in the manifest..." -ForegroundColor Cyan
        $Ignored = Get-IgnoredComponents -Path $IgnorePath
        Update-ManifestDiscovery -ManifestPath $ManifestPath -OrgAlias $OrgAlias -Ignored $Ignored -WhatIf:$WhatIf | Out-Null
    }

    if ($WhatIf) {
        Write-Host ""
        Write-Host "-WhatIf: skipping retrieve." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Retrieving metadata from manifest/package.xml..." -ForegroundColor Cyan

    Push-Location $ProjectDir
    try {
        sf project retrieve start `
            --manifest "manifest/package.xml" `
            --target-org $OrgAlias

        if ($LASTEXITCODE -ne 0) {
            throw "sf project retrieve start failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "Retrieve complete. Review changes with:" -ForegroundColor Green
    Write-Host "  git status sfdx/force-app"
}
finally {
    Stop-ScriptLog
}
