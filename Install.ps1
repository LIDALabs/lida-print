#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instalador del sistema de auto-impresion de facturas Odoo.
.DESCRIPTION
    - Verifica/instala SumatraPDF
    - Copia scripts a la ruta de instalacion
    - Crea tarea programada para arranque automatico
    - Ejecuta el Configurator
.NOTES
    Ejecutar como Administrador: powershell -ExecutionPolicy Bypass -File Install.ps1
#>

$ErrorActionPreference = "Stop"

# ===================== CONFIGURACION INICIAL =====================
$defaultInstallPath = "C:\AutoPrintFacturas"
$taskName = "LidaPrint"
$sumatraUrl = "https://www.sumatrapdfreader.org/dl/rel/3.5.2/SumatraPDF-3.5.2-64.exe"
# ===================== CONFIGURACION INICIAL =====================

function Write-Step {
    param([string]$msg)
    Write-Host "`n[*] " -ForegroundColor Cyan -NoNewline
    Write-Host $msg
}

function Write-OK {
    param([string]$msg)
    Write-Host "[OK] " -ForegroundColor Green -NoNewline
    Write-Host $msg
}

function Write-Warn {
    param([string]$msg)
    Write-Host "[!] " -ForegroundColor Yellow -NoNewline
    Write-Host $msg
}

function Write-Fail {
    param([string]$msg)
    Write-Host "[X] " -ForegroundColor Red -NoNewline
    Write-Host $msg
}

# ===================== 1. VERIFICAR ADMIN =====================
Write-Step "Verificando permisos de administrador..."
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Fail "Este script requiere permisos de Administrador."
    Write-Host "    Click derecho -> Ejecutar como administrador"
    pause
    exit 1
}
Write-OK "Ejecutando como Administrador"

# ===================== 2. PEDIR RUTA DE INSTALACION =====================
Write-Step "Ruta de instalacion..."
Write-Host "    Ruta por defecto: $defaultInstallPath"
$inputPath = Read-Host "    Presione Enter para usar defecto, o escriba otra ruta"
$installPath = if ([string]::IsNullOrWhiteSpace($inputPath)) { $defaultInstallPath } else { $inputPath.Trim() }

# Crear directorio
if (-not (Test-Path $installPath)) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    Write-OK "Directorio creado: $installPath"
} else {
    Write-OK "Directorio existente: $installPath"
}

# Crear subdirectorio de logs
$logsPath = Join-Path $installPath "logs"
if (-not (Test-Path $logsPath)) {
    New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
}

# ===================== 3. VERIFICAR/INSTALAR SUMATRAPDF =====================
Write-Step "Verificando SumatraPDF..."

$sumatraPaths = @(
    "${env:ProgramFiles}\SumatraPDF\SumatraPDF.exe",
    "${env:ProgramFiles(x86)}\SumatraPDF\SumatraPDF.exe",
    "$env:LOCALAPPDATA\SumatraPDF\SumatraPDF.exe"
)

$sumatraPath = $sumatraPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($sumatraPath) {
    Write-OK "SumatraPDF encontrado: $sumatraPath"
} else {
    Write-Warn "SumatraPDF no encontrado. Intentando instalar..."
    
    # Intentar con winget
    $hasWinget = Get-Command winget -ErrorAction SilentlyContinue
    if ($hasWinget) {
        Write-Host "    Instalando con winget..."
        winget install SumatraPDF.SumatraPDF --accept-package-agreements --accept-source-agreements
        # Re-verificar
        $sumatraPath = $sumatraPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    
    # Si winget fallo, descargar manualmente
    if (-not $sumatraPath) {
        Write-Warn "Winget no disponible. Descargando SumatraPDF..."
        $tempInstaller = Join-Path $env:TEMP "SumatraPDF-Installer.exe"
        
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $sumatraUrl -OutFile $tempInstaller -UseBasicParsing
            
            Write-Host "    Ejecutando instalador ( modo silencioso )..."
            Start-Process -FilePath $tempInstaller -ArgumentList "/S" -Wait
            
            # Re-verificar
            $sumatraPath = $sumatraPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            
            Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Fail "No se pudo instalar SumatraPDF automaticamente."
            Write-Host "    Descargue manualmente desde: https://www.sumatrapdfreader.org/download-free-pdf-viewer"
            Write-Host "    Instale y vuelva a ejecutar este script."
            pause
            exit 1
        }
    }
    
    if ($sumatraPath) {
        Write-OK "SumatraPDF instalado: $sumatraPath"
    } else {
        Write-Fail "No se pudo instalar SumatraPDF. Instale manualmente."
        pause
        exit 1
    }
}

# ===================== 4. COPIAR SCRIPTS =====================
Write-Step "Copiando scripts a $installPath..."

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$filesToCopy = @(
    "LidaPrint.ps1",
    "Configurator.ps1",
    "config.json",
    "logo.png",
    "LidaPrint.bat",
    "LidaPrint.vbs"
)

foreach ($file in $filesToCopy) {
    $src = Join-Path $scriptDir $file
    $dst = Join-Path $installPath $file
    
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $dst -Force
        Write-OK "Copiado: $file"
    } else {
        Write-Warn "No encontrado: $file (omite)"
    }
}

# Actualizar config.json con la ruta de SumatraPDF y ruta de instalacion
$configPath = Join-Path $installPath "config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $config.sumatraPath = $sumatraPath
    $config.installPath = $installPath
    $config.downloadFolder = $env:USERPROFILE + "\Downloads"
    $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
    Write-OK "config.json actualizado"
}

# ===================== 5. AGREGAR AL PATH =====================
Write-Step "Agregando ruta al PATH del usuario..."
$currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($currentPath -notlike '*AutoPrintFacturas*') {
    [Environment]::SetEnvironmentVariable('Path', $currentPath + ";$installPath", 'User')
    Write-OK "Ruta agregada al PATH: $installPath"
} else {
    Write-OK "Ruta ya existe en PATH"
}

# ===================== 6. CREAR TASK SCHEDULER =====================
Write-Step "Configurando tarea programada..."

# Eliminar tarea existente si existe
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Warn "Tarea existente eliminada"
}

# Crear accion
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installPath\LidaPrint.ps1`""

# Crear triggers (al iniciar sesion + al iniciar sistema)
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$triggerStartup = New-ScheduledTaskTrigger -AtStartup

# Configurar settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# Registrar tarea
Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($triggerLogon, $triggerStartup) `
    -Settings $settings `
    -Description "LidaPrint - Impresion automatica de facturas Odoo" `
    -RunLevel Highest | Out-Null

Write-OK "Tarea programada creada: $taskName"

# ===================== 7. RESUMEN =====================
Write-Host "`n" -NoNewline
Write-Host "============================================" -ForegroundColor Green
Write-Host "  INSTALACION COMPLETADA" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Scripts:     $installPath"
Write-Host "  SumatraPDF:  $sumatraPath"
Write-Host "  Tarea:       $taskName (arranca al login)" -ForegroundColor Green
Write-Host ""
Write-Host "  SIGUIENTE PASO: Ejecutar Configurator" -ForegroundColor Yellow
Write-Host ""

$openConfig = Read-Host "  Abrir Configurator ahora? (S/N)"
if ($openConfig -eq "S" -or $openConfig -eq "s") {
    $configuratorPath = Join-Path $installPath "Configurator.ps1"
    if (Test-Path $configuratorPath) {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$configuratorPath`""
    } else {
        Write-Warn "Configurator.ps1 no encontrado en $installPath"
    }
}

Write-Host ""
pause
