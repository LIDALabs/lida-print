<#
.SYNOPSIS
    Instalador de LidaPrint.
.DESCRIPTION
    - Instala a una ubicacion ESTABLE: %LOCALAPPDATA%\LidaPrint.
      Mover o borrar la carpeta descargada no rompe la instalacion.
    - Verifica/instala SumatraPDF (por usuario, sin admin).
    - Verifica/instala Ghostscript (motor de alta calidad; puede pedir UAC).
    - Crea la tarea programada LidaPrint (nivel usuario, sin admin).
    - Abre el Configurator al terminar.
.NOTES
    No requiere Administrador. Ejecutar: powershell -ExecutionPolicy Bypass -File Install.ps1
#>

$ErrorActionPreference = "Stop"

# ===================== CONFIGURACION =====================
$installPath = Join-Path $env:LOCALAPPDATA "LidaPrint"
$taskName    = "LidaPrint"
$sumatraUrl  = "https://www.sumatrapdfreader.org/dl/rel/3.5.2/SumatraPDF-3.5.2-64-install.exe"
$gsUrl       = "https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10031/gs10031w64.exe"

function Write-Step { param([string]$msg) Write-Host "`n[*] " -ForegroundColor Cyan -NoNewline; Write-Host $msg }
function Write-OK   { param([string]$msg) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Warn { param([string]$msg) Write-Host "[!] "  -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Write-Fail { param([string]$msg) Write-Host "[X] "  -ForegroundColor Red -NoNewline; Write-Host $msg }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ===================== 1. CARPETA DE INSTALACION =====================
Write-Step "Preparando $installPath..."
if (-not (Test-Path $installPath)) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    Write-OK "Directorio creado"
} else {
    Write-OK "Directorio existente"
}
New-Item -ItemType Directory -Path (Join-Path $installPath "logs") -Force | Out-Null

# ===================== 2. COPIAR ARCHIVOS =====================
# Si el instalador ya corre desde la carpeta de instalacion (web-install), no copia.
if ($scriptDir -ne $installPath) {
    Write-Step "Copiando archivos..."
    $filesToCopy = @(
        "LidaPrint.ps1", "Configurator.ps1", "Install.ps1", "uninstall.ps1",
        "Instalador.bat", "LidaPrint.bat", "LidaPrint.vbs",
        "logo.png", "README.md"
    )
    foreach ($file in $filesToCopy) {
        $src = Join-Path $scriptDir $file
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination (Join-Path $installPath $file) -Force
            Write-OK "Copiado: $file"
        } else {
            Write-Warn "No encontrado: $file (omitido)"
        }
    }
    # config.json: NO pisar la configuracion existente del usuario
    $srcCfg = Join-Path $scriptDir "config.json"
    $dstCfg = Join-Path $installPath "config.json"
    if ((Test-Path $srcCfg) -and -not (Test-Path $dstCfg)) {
        Copy-Item -Path $srcCfg -Destination $dstCfg -Force
        Write-OK "Copiado: config.json (plantilla inicial)"
    } elseif (Test-Path $dstCfg) {
        Write-OK "config.json existente conservado"
    }
} else {
    Write-OK "Ejecutando desde la carpeta de instalacion, copia omitida"
}

# ===================== 3. SUMATRAPDF =====================
Write-Step "Verificando SumatraPDF..."
$sumatraPaths = @(
    "$env:LOCALAPPDATA\SumatraPDF\SumatraPDF.exe",
    "${env:ProgramFiles}\SumatraPDF\SumatraPDF.exe",
    "${env:ProgramFiles(x86)}\SumatraPDF\SumatraPDF.exe"
)
$sumatraPath = $sumatraPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($sumatraPath) {
    Write-OK "SumatraPDF encontrado: $sumatraPath"
} else {
    Write-Warn "SumatraPDF no encontrado. Descargando (instalacion por usuario, sin admin)..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tempInstaller = Join-Path $env:TEMP "SumatraPDF-Installer.exe"
        Invoke-WebRequest -Uri $sumatraUrl -OutFile $tempInstaller -UseBasicParsing
        Start-Process -FilePath $tempInstaller -ArgumentList "-s" -Wait
        Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
        $sumatraPath = $sumatraPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    } catch {
        Write-Warn "Descarga de SumatraPDF fallo: $_"
    }
    if ($sumatraPath) { Write-OK "SumatraPDF instalado: $sumatraPath" }
    else { Write-Warn "SumatraPDF no disponible. Ghostscript sera el unico motor." }
}

# ===================== 4. GHOSTSCRIPT =====================
Write-Step "Verificando Ghostscript (motor de alta calidad)..."
function Find-Gs {
    foreach ($base in @("$env:ProgramFiles\gs", "${env:ProgramFiles(x86)}\gs", "$env:LOCALAPPDATA\Programs\gs")) {
        if (Test-Path $base) {
            $found = Get-ChildItem -Path $base -Recurse -Filter "gswin*c.exe" -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return $null
}
$gsPath = Find-Gs

if ($gsPath) {
    Write-OK "Ghostscript encontrado: $gsPath"
} else {
    $hasWinget = Get-Command winget -ErrorAction SilentlyContinue
    if ($hasWinget) {
        Write-Host "    Instalando Ghostscript con winget..."
        try { winget install ArtifexSoftware.GhostScript --accept-package-agreements --accept-source-agreements } catch { }
        $gsPath = Find-Gs
    }
    if (-not $gsPath) {
        Write-Warn "Descargando instalador de Ghostscript (puede pedir UAC)..."
        try {
            $tempGs = Join-Path $env:TEMP "gs-installer.exe"
            Invoke-WebRequest -Uri $gsUrl -OutFile $tempGs -UseBasicParsing
            Start-Process -FilePath $tempGs -ArgumentList "/S" -Wait
            Remove-Item $tempGs -Force -ErrorAction SilentlyContinue
            $gsPath = Find-Gs
        } catch {
            Write-Warn "Instalacion de Ghostscript fallo: $_"
        }
    }
    if ($gsPath) { Write-OK "Ghostscript instalado: $gsPath" }
    else { Write-Warn "Ghostscript no disponible. El motor de alta calidad queda desactivado (SumatraPDF sigue funcionando)." }
}

if (-not $sumatraPath -and -not $gsPath) {
    Write-Fail "No se pudo instalar ningun motor de impresion. Revisa tu conexion e intenta de nuevo."
    pause
    exit 1
}

# ===================== 5. ACTUALIZAR CONFIG =====================
Write-Step "Actualizando config.json..."
$configPath = Join-Path $installPath "config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    if ($sumatraPath) { $config.sumatraPath = $sumatraPath }
    if ($gsPath) {
        if ($null -eq $config.gsPath) { $config | Add-Member -NotePropertyName gsPath -NotePropertyValue $gsPath -Force }
        else { $config.gsPath = $gsPath }
    }
    $config.installPath = $installPath
    if (-not $config.downloadFolder) { $config.downloadFolder = Join-Path $env:USERPROFILE "Downloads" }
    $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
    Write-OK "config.json actualizado"
} else {
    Write-Warn "config.json no encontrado; el Configurator creara uno al guardar."
}

# ===================== 6. TAREA PROGRAMADA (NIVEL USUARIO) =====================
Write-Step "Configurando tarea programada..."
$monitorPath = Join-Path $installPath "LidaPrint.ps1"

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-OK "Tarea anterior eliminada (se re-registra apuntando a la instalacion estable)"
    } catch {
        # Tarea creada desde una sesion elevada: un proceso normal no puede
        # borrarla. Pedir elevacion UNA vez (UAC) solo para eliminarla.
        Write-Warn "La tarea existente fue creada como Administrador. Acepta el UAC para migrarla..."
        try {
            $elevArgs = '-NoProfile -Command "Unregister-ScheduledTask -TaskName ''' + $taskName + ''' -Confirm:$false"'
            Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList $elevArgs
        } catch {
            Write-Warn "Elevacion cancelada."
        }
    }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Write-Fail "La tarea existente no pudo eliminarse. Ejecuta como Administrador: Unregister-ScheduledTask -TaskName $taskName -Confirm:0  y reinstala."
    }
}

$taskRegistered = $false
try {
    # conhost --headless: el monitor corre en una consola SIN ventana, esquivando
    # Windows Terminal (host por defecto en Win11) donde tanto -WindowStyle Hidden
    # (cuelga el arranque) como los trucos de ocultar ventana fallan. Sin ventana
    # no hay nada que el usuario pueda cerrar por accidente.
    # -NoProfile: el perfil del usuario puede colgarse o fallar en sesion no interactiva.
    $action  = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$monitorPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 0)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "LidaPrint - Impresion automatica de facturas Odoo" | Out-Null
    $taskRegistered = $true
    Write-OK "Tarea programada creada: $taskName (arranca al iniciar sesion)"
} catch {
    Write-Warn "No se pudo crear la tarea programada: $_"
}

# Arrancar el monitor YA, sin esperar al proximo inicio de sesion.
# (La politica por defecto de la tarea ignora arranques si ya esta corriendo.)
if ($taskRegistered) {
    try {
        Start-ScheduledTask -TaskName $taskName
        Write-OK "Monitor iniciado (ya esta vigilando la carpeta)"
    } catch {
        Write-Warn "El monitor arrancara en el proximo inicio de sesion."
    }
}

# ===================== 7. PATH DEL USUARIO =====================
# Uso tecnico por consola: escribir 'lidaprint' abre el Configurator
# (resuelve LidaPrint.bat via PATHEXT). Solo PATH de usuario, sin admin.
Write-Step "Agregando la instalacion al PATH del usuario..."
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $userPath) { $userPath = "" }
if (($userPath -split ';') -notcontains $installPath) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$installPath").TrimStart(';'), 'User')
    Write-OK "PATH actualizado. Abre una consola NUEVA y ejecuta: lidaprint"
} else {
    Write-OK "La instalacion ya esta en el PATH"
}

# ===================== 8. RESUMEN Y CONFIGURATOR =====================
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  INSTALACION COMPLETADA" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Instalado en: $installPath"
Write-Host "  SumatraPDF:   $(if ($sumatraPath) { $sumatraPath } else { 'no instalado' })"
Write-Host "  Ghostscript:  $(if ($gsPath) { $gsPath } else { 'no instalado' })"
Write-Host "  Tarea:        $taskName $(if ($taskRegistered) { '(monitor corriendo)' } else { '' })"
Write-Host "  Consola:      escribe 'lidaprint' (en una consola nueva) para abrir el Configurator"
Write-Host ""
# El Configurator se abre SOLO en la primera instalacion (sin impresora
# configurada). En reinstalaciones y updates no se abre nada visual:
# la app se accede escribiendo 'lidaprint' en Win+R o en una consola.
$needsSetup = $true
try {
    $cfgCheck = Get-Content (Join-Path $installPath "config.json") -Raw | ConvertFrom-Json
    if ($cfgCheck.printer) { $needsSetup = $false }
} catch { }

if ($needsSetup) {
    Write-Host "  Primera instalacion: abriendo el Configurator..." -ForegroundColor Yellow
    $configuratorPath = Join-Path $installPath "Configurator.ps1"
    if (Test-Path $configuratorPath) {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$configuratorPath`""
    }
} else {
    Write-Host "  Configuracion existente detectada. Para abrir la app: Win+R -> lidaprint" -ForegroundColor Gray
}
