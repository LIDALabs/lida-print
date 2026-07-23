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

    NOTA: $repoRef debe actualizarse a cada nuevo tag antes de publicar el release.
    Nunca apuntar a una rama mutable (main) en produccion.
#>

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Ref inmutable del release. Cambiar a la etiqueta correspondiente antes de publicar.
$repoRef     = "main"
$repoRaw     = "https://raw.githubusercontent.com/LIDALabs/lida-print/$repoRef"
$installPath = Join-Path $env:LOCALAPPDATA "LidaPrint"

# Valida que el contenido descargado sea un archivo real y no una pagina de error HTML.
# Retorna $true si la descarga es valida, $false en caso contrario.
function Test-DownloadValid {
    param([string]$path, [string]$name)
    if (-not (Test-Path $path)) { return $false }
    $len = (Get-Item -LiteralPath $path).Length
    if ($len -eq 0) {
        Write-Host " FALLO (archivo vacio)" -ForegroundColor Red
        return $false
    }
    # Detectar paginas de error de GitHub (HTML): empiezan con "<"
    $buf = New-Object byte[] 16
    $fs = [System.IO.File]::OpenRead($path)
    $read = $fs.Read($buf, 0, 16)
    $fs.Close()
    if ($read -gt 0 -and $buf[0] -eq 0x3C) {
        Write-Host " FALLO (respuesta HTML, posible error 404 o token invalido)" -ForegroundColor Red
        return $false
    }
    return $true
}

# Descarga un archivo a una ruta temporal, valida el contenido y mueve al destino.
# Aborta la instalacion completa si la descarga falla o el contenido no es valido.
function Get-RepoFile {
    param([string]$name, [string]$dest)
    $tmp = "$dest.tmp"
    Write-Host "[*] Descargando $name..." -NoNewline
    try {
        Invoke-WebRequest -Uri "$repoRaw/$name" -OutFile $tmp -UseBasicParsing
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        Write-Host " FALLO" -ForegroundColor Red
        Write-Host "    $_" -ForegroundColor Red
        Write-Host "Instalacion abortada. Verifica tu conexion y que el repositorio sea accesible." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-DownloadValid $tmp $name)) {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        Write-Host "Instalacion abortada." -ForegroundColor Red
        exit 1
    }
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    Write-Host " OK" -ForegroundColor Green
}

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
    Get-RepoFile $file (Join-Path $installPath $file)
}

# config.json: solo si no existe (no pisar la configuracion del usuario en re-instalaciones)
$cfgDest = Join-Path $installPath "config.json"
if (-not (Test-Path $cfgDest)) {
    $cfgTmp = "$cfgDest.tmp"
    Write-Host "[*] Descargando config.json (plantilla inicial)..." -NoNewline
    try {
        Invoke-WebRequest -Uri "$repoRaw/config.json" -OutFile $cfgTmp -UseBasicParsing
        if (Test-DownloadValid $cfgTmp "config.json") {
            Move-Item -LiteralPath $cfgTmp -Destination $cfgDest -Force
            Write-Host " OK" -ForegroundColor Green
        } else {
            if (Test-Path $cfgTmp) { Remove-Item $cfgTmp -Force -ErrorAction SilentlyContinue }
            Write-Host " (el Configurator creara uno al guardar)" -ForegroundColor Yellow
        }
    } catch {
        if (Test-Path $cfgTmp) { Remove-Item $cfgTmp -Force -ErrorAction SilentlyContinue }
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
