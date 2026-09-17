#Requires -Version 5.1
<#
.SYNOPSIS
    Opens Claude Code in the repository root.

.DESCRIPTION
    Calls claude.exe by its absolute path, because PATH cannot be changed on
    this machine. Always starts in the folder this script lives in, whatever
    directory it was launched from. Any arguments are passed straight through.

.EXAMPLE
    .\Start-Claude.ps1

.EXAMPLE
    .\Start-Claude.ps1 --continue
#>

$ClaudeExe = 'C:\Users\DaveKLarrimore\.local\bin\claude.exe'

if (-not (Test-Path -LiteralPath $ClaudeExe -PathType Leaf)) {
    Write-Error "Claude Code not found at $ClaudeExe"
    exit 1
}

Push-Location -LiteralPath $PSScriptRoot
try {
    & $ClaudeExe @args
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
