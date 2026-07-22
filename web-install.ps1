<#
.SYNOPSIS
    Instalacion web de LidaPrint en un solo comando.
.DESCRIPTION
    Descarga LidaPrint desde GitHub (raw) a %LOCALAPPDATA%\LidaPrint
    y ejecuta el instalador completo. No requiere Administrador.
.NOTES
    Uso (PowerShell):
      irm https://raw.githubusercontent.com/LIDALabs/lida-print/main/web-install.ps1 | iex

    Uso (cmd con curl):
      curl -L -o "%TEMP%\web-install.ps1" https://raw.githubusercontent.com/LIDALabs/lida-print/main/web-install.ps1 && powershell -ExecutionPolicy Bypass -File "%TEMP%\web-install.ps1"
#>

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repoRaw     = "https://raw.githubusercontent.com/LIDALabs/lida-print/main"
$installPath = Join-Path $env:LOCALAPPDATA "LidaPrint"

# raw.githubusercontent.com no lista carpetas: la lista de archivos va embebida.
$files = @(
    "LidaPrint.ps1",
    "Configurator.ps1",
    "Install.ps1",
    "uninstall.ps1",
    "Instalador.bat",
    "LidaPrint.bat",
    "LidaPrint.vbs",
    "logo.png",
    "README.md"
)

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  LidaPrint - Instalacion web" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Destino: $installPath"
Write-Host ""

if (-not (Test-Path $installPath)) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
}

foreach ($file in $files) {
    Write-Host "[*] Descargando $file..." -NoNewline
    try {
        Invoke-WebRequest -Uri "$repoRaw/$file" -OutFile (Join-Path $installPath $file) -UseBasicParsing
        Write-Host " OK" -ForegroundColor Green
    } catch {
        Write-Host " FALLO" -ForegroundColor Red
        Write-Host "    $_" -ForegroundColor Red
        Write-Host "Instalacion abortada. Verifica tu conexion y que el repositorio sea accesible." -ForegroundColor Red
        return
    }
}

# config.json: solo si no existe (no pisar la configuracion del usuario en re-instalaciones)
$cfgDest = Join-Path $installPath "config.json"
if (-not (Test-Path $cfgDest)) {
    Write-Host "[*] Descargando config.json (plantilla inicial)..." -NoNewline
    try {
        Invoke-WebRequest -Uri "$repoRaw/config.json" -OutFile $cfgDest -UseBasicParsing
        Write-Host " OK" -ForegroundColor Green
    } catch {
        Write-Host " FALLO (el Configurator creara uno al guardar)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[OK] config.json existente conservado" -ForegroundColor Green
}

Write-Host ""
Write-Host "Descarga completa. Ejecutando el instalador..." -ForegroundColor Green
Write-Host ""

# Install.ps1 detecta que corre desde la carpeta de instalacion (no re-copia),
# instala Ghostscript, registra la tarea y abre el Configurator (solo primera vez).
& powershell.exe -ExecutionPolicy Bypass -File (Join-Path $installPath "Install.ps1")
