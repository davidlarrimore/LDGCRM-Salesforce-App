#Requires -Version 5.1

<#
    Renders a migration report HTML file to PDF using headless Chrome (or Edge).

    WHY A PDF EXISTS AT ALL: the stakeholder report is authored as HTML, but
    Google Drive does not render a standalone .html file - it shows the raw
    markup - so anyone sharing it through Drive needs the PDF. Send the PDF;
    keep the HTML as the source.

    TWO THINGS THAT SILENTLY PRODUCE A BROKEN PDF, both handled here:

    1. PATHS WITH BRACES. This machine's real paths run through a SnapVolumes
       mount whose folder names contain { and }, which are invalid unescaped in
       a file:// URL. Chrome does not error - it loads about:blank and writes a
       perfectly valid ONE-PAGE PDF of nothing. Building the URL with
       System.Uri escapes correctly. (Hand-rolling it with -replace on
       backslashes is what produced a blank 24 KB file the first time.)

    2. A FAILED RENDER STILL LOOKS LIKE SUCCESS. Chrome reports "N bytes
       written" and exits 0 whether or not it rendered the page. So this script
       VERIFIES the output by reading the PDF's page-tree /Count and fails loudly
       if it is 1 or less, rather than handing over a blank file that looks fine
       until someone opens it.

    Usage:
        scripts\powershell-scripts\Export-ReportPdf.ps1
        scripts\powershell-scripts\Export-ReportPdf.ps1 -HtmlPath "docs\my-report.html"
#>

param(
    # Defaults to the most recent migration load report in docs/.
    [string]$HtmlPath,

    # Defaults to the same name/folder as the HTML, with a .pdf extension.
    [string]$PdfPath,

    # A real report is many pages; anything at or below this means a blank or
    # clipped render.
    [int]$MinimumPages = 2
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.Tools.ps1")
. (Join-Path $PSScriptRoot "..\scripts\powershell-scripts\Common.ps1")

$RepoRoot = Get-RepoRoot

if (-not $HtmlPath) {
    $DocsDir = Join-Path $RepoRoot "docs"
    $Candidate = Get-ChildItem -LiteralPath $DocsDir -Filter "migration-load-report-*.html" |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $Candidate) {
        throw "No migration-load-report-*.html found in $DocsDir. Pass -HtmlPath explicitly."
    }
    $HtmlPath = $Candidate.FullName
}

if (-not (Test-Path -LiteralPath $HtmlPath)) {
    throw "Source HTML not found: $HtmlPath"
}

$HtmlFull = (Resolve-Path -LiteralPath $HtmlPath).Path
if (-not $PdfPath) {
    $PdfPath = [System.IO.Path]::ChangeExtension($HtmlFull, ".pdf")
}

# Chrome preferred, Edge as fallback - both ship Blink's print-to-pdf.
$Browsers = @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
)
$Browser = $Browsers | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $Browser) {
    throw "Neither Chrome nor Edge was found. Checked:`n  $($Browsers -join "`n  ")"
}

# See note 1 in the header - this escaping is the whole point.
$Uri = ([System.Uri]$HtmlFull).AbsoluteUri

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " EXPORT REPORT TO PDF" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Browser : $(Split-Path $Browser -Leaf)"
Write-Host "Source  : $HtmlFull"
Write-Host "URI     : $Uri"
Write-Host "Output  : $PdfPath"
Write-Host ""

if (Test-Path -LiteralPath $PdfPath) { Remove-Item -LiteralPath $PdfPath -Force }

# --virtual-time-budget gives layout time to settle before the snapshot;
# --run-all-compositor-stages-before-draw stops it printing mid-paint.
# stderr is deliberately NOT redirected: in PS 5.1 redirecting a native
# command's stderr wraps each line in an ErrorRecord and trips $ErrorActionPreference.
& $Browser `
    --headless=new `
    --disable-gpu `
    --no-pdf-header-footer `
    --virtual-time-budget=20000 `
    --run-all-compositor-stages-before-draw `
    "--print-to-pdf=$PdfPath" `
    $Uri | Out-Null

if (-not (Test-Path -LiteralPath $PdfPath)) {
    throw "The browser exited without producing a PDF at $PdfPath."
}

# --- Verify, don't trust (see note 2 in the header) ---
$Bytes = [System.IO.File]::ReadAllBytes($PdfPath)
$Text = [System.Text.Encoding]::ASCII.GetString($Bytes)

$Header = [System.Text.Encoding]::ASCII.GetString($Bytes[0..4])
if ($Header -ne "%PDF-") {
    throw "Output is not a PDF (header was '$Header')."
}

$CountMatch = [regex]::Match($Text, '/Count\s+(\d+)')
$Pages = if ($CountMatch.Success) { [int]$CountMatch.Groups[1].Value } else { 0 }

$SizeKb = [math]::Round($Bytes.Length / 1KB, 1)
Write-Host "Size    : $SizeKb KB"
Write-Host "Pages   : $Pages"
Write-Host ""

if ($Pages -lt $MinimumPages) {
    throw @"
Only $Pages page(s) rendered - the PDF is almost certainly blank or clipped.
The usual cause is the page failing to load, in which case the browser still
writes a valid one-page file. Open $Uri in a browser to confirm it renders,
and check the path for characters that need escaping in a URL.
"@
}

Write-Host "PDF exported successfully." -ForegroundColor Green
Write-Host $PdfPath
