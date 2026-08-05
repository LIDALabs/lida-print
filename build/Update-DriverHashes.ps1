# Recomputes the sha256 field of every entry in drivers/drivers.json
# from the actual files on disk. Run after adding or updating a driver.
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot "drivers/drivers.json"
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
foreach ($d in $manifest.drivers) {
    $file = Join-Path $repoRoot $d.file
    if (-not (Test-Path $file)) { throw "Missing driver file: $($d.file)" }
    $d.sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content $manifestPath -Encoding UTF8
Write-Output "Updated: $manifestPath"
