# Builds LidaPrint.exe: merges the PowerShell sources into a single script
# with a mode dispatcher, then compiles it with ps2exe (Windows only).
# -MergeOnly stops after generating the merged script (usable on any OS).
param(
    [Parameter(Mandatory)][string]$Version,
    [switch]$MergeOnly,
    [string]$OutDir
)
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repoRoot "dist" }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$serviceSrc = Get-Content (Join-Path $repoRoot "LidaPrint.ps1") -Raw
$guiSrc     = Get-Content (Join-Path $repoRoot "Configurator.ps1") -Raw
$uninsSrc   = Get-Content (Join-Path $repoRoot "uninstall.ps1") -Raw
$logoB64    = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $repoRoot "logo.png")))

# Header: dispatcher params + global contract + Write-Host stub.
# Write-Host must be a no-op: under ps2exe -noConsole every Write-Host
# becomes a message box, which would spam popups from the service loop.
$header = @"
param([switch]`$Service, [switch]`$Uninstall)
`$Global:LidaPrintVersion = '$Version'
`$Global:LidaPrintExeDir = Split-Path -Parent ([Environment]::GetCommandLineArgs()[0])
`$Global:LidaPrintLogoB64 = '$logoB64'
function Write-Host {
    param([Parameter(ValueFromRemainingArguments = `$true)]`$Rest, `$ForegroundColor, `$BackgroundColor, [switch]`$NoNewline)
}
"@

$merged = @"
$header
if (`$Service) {
$serviceSrc
exit 0
}
if (`$Uninstall) {
$uninsSrc
exit 0
}
$guiSrc
"@

$mergedPath = Join-Path $OutDir "LidaPrint.merged.ps1"
Set-Content -Path $mergedPath -Value $merged -Encoding UTF8

# Fail fast if the merge produced an unparseable script.
$t = $e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($mergedPath, [ref]$t, [ref]$e)
if ($e.Count) { $e | ForEach-Object { Write-Error $_.Message }; throw "Merged script has parse errors" }

if ($MergeOnly) { Write-Output "Merged: $mergedPath"; return }

# ---- Windows-only from here ----
Import-Module ps2exe

# Best-effort icon from logo.png; the build proceeds without one on failure.
$iconPath = $null
try {
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::FromFile((Join-Path $repoRoot "logo.png"))
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $iconPath = Join-Path $OutDir "LidaPrint.ico"
    $fs = [IO.File]::Create($iconPath)
    $icon.Save($fs); $fs.Close(); $bmp.Dispose()
} catch { $iconPath = $null }

$exePath = Join-Path $OutDir "LidaPrint.exe"
$ps2exeArgs = @{
    inputFile  = $mergedPath
    outputFile = $exePath
    noConsole  = $true
    title      = "LidaPrint"
    product    = "LidaPrint"
    company    = "LIDA"
    version    = ($Version -replace '[^\d.].*$', '')
}
if ($iconPath) { $ps2exeArgs.iconFile = $iconPath }
Invoke-ps2exe @ps2exeArgs

$hash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
Set-Content -Path (Join-Path $OutDir "SHA256SUMS.txt") -Value "$hash  LidaPrint.exe" -Encoding ASCII
Write-Output "Built: $exePath"
