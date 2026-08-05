# LidaPrint web installer. Run with:
#   irm https://raw.githubusercontent.com/LIDALabs/lida-print/main/get.ps1 | iex
# Downloads only the compiled LidaPrint.exe from the latest GitHub Release,
# verifies its SHA256 and installs it. No source files land on the machine.
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo        = "LIDALabs/lida-print"
$installPath = Join-Path $env:LOCALAPPDATA "LidaPrint"
$taskName    = "LidaPrint"

# GS installer URL and expected SHA256 (update when upgrading GS version).
# If $gsExpectedSha256 is empty, verification falls back to Authenticode signature.
$gsUrl             = "https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10031/gs10031w64.exe"
$gsExpectedSha256  = ""

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg"  -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red }

function Test-Sha256Sum {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$SumsContent,
        [Parameter(Mandatory)][string]$FileName
    )
    $escaped = [regex]::Escape($FileName)
    $line = $SumsContent -split "`r?`n" | Where-Object { $_ -match $escaped } | Select-Object -First 1
    if (-not $line) { return $false }
    $expected = ($line -split '\s+')[0]
    if ($expected.Length -ne 64) { return $false }
    $actual = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash
    return ($actual -eq $expected)
}

# --- 1. Resolve latest release ---
Write-Step "Consultando ultima version publicada..."
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
    -Headers @{ "User-Agent" = "LidaPrint-Installer" } -UseBasicParsing
$exeAsset  = $release.assets | Where-Object name -eq "LidaPrint.exe"
$sumsAsset = $release.assets | Where-Object name -eq "SHA256SUMS.txt"
if (-not $exeAsset -or -not $sumsAsset) { Write-Fail "El Release $($release.tag_name) no tiene los assets esperados."; throw "Missing release assets: $($release.tag_name)" }

# --- 2. Download + verify ---
$tempExe = Join-Path $env:TEMP "LidaPrint.exe.download"
try {
    Write-Step "Descargando LidaPrint.exe $($release.tag_name)..."
    Invoke-WebRequest -Uri $exeAsset.browser_download_url -OutFile $tempExe -UseBasicParsing
    $sums = (Invoke-WebRequest -Uri $sumsAsset.browser_download_url -UseBasicParsing).Content
    if (-not (Test-Sha256Sum -FilePath $tempExe -SumsContent $sums -FileName "LidaPrint.exe")) {
        Write-Fail "La verificacion SHA256 fallo. Instalacion abortada."; throw "SHA256 verification failed for LidaPrint.exe"
    }

    # --- 3. Stop running instances ---
    Write-Step "Deteniendo instancias en ejecucion..."
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Get-Process -Name "LidaPrint" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*LidaPrint.ps1*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    # --- 4. Install exe + clean legacy source files ---
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $installPath "logs") -Force | Out-Null
    Move-Item -LiteralPath $tempExe -Destination (Join-Path $installPath "LidaPrint.exe") -Force
    foreach ($legacy in "LidaPrint.ps1","Configurator.ps1","Install.ps1","uninstall.ps1","web-install.ps1",
                        "Instalador.bat","LidaPrint.bat","LidaPrint.vbs","logo.png","README.md") {
        Remove-Item -LiteralPath (Join-Path $installPath $legacy) -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue
}

# --- 5. Logs ACL ---
# Copied verbatim from Install.ps1:41-72 (icacls block on $installPath\logs).
$logsPath = Join-Path $installPath "logs"
try {
    $icaclsArgs = @(
        $logsPath,
        "/inheritance:r",
        "/grant:r", "NT AUTHORITY\SYSTEM:(OI)(CI)F",
        "/grant:r", "BUILTIN\Administrators:(OI)(CI)F",
        "/grant:r", "${env:USERDOMAIN}\${env:USERNAME}:(OI)(CI)F"
    )
    $existingTaskForAcl = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTaskForAcl) {
        $taskUserId = $existingTaskForAcl.Principal.UserId
        # Normalizar: la tarea puede guardar solo el nombre sin dominio
        $taskUserNorm = if ($taskUserId -like "*\*") { $taskUserId } else { "${env:USERDOMAIN}\$taskUserId" }
        $currentUserNorm = "${env:USERDOMAIN}\${env:USERNAME}"
        if ($taskUserNorm -ne $currentUserNorm) {
            # El monitor corre como otro usuario: garantizar que siga escribiendo logs
            $icaclsArgs += "/grant:r"
            $icaclsArgs += "${taskUserId}:(OI)(CI)F"
        }
    }
    & icacls.exe @icaclsArgs | Out-Null
    Write-OK "ACL del directorio de logs configurada"
} catch {
    Write-Warn "No se pudo configurar el ACL del directorio de logs: $_"
}

# --- 6. Ghostscript ---
# Copied verbatim from Install.ps1:105-180 (Find-Gs, winget, verified download
# of gs10031w64.exe with SHA256/Authenticode Artifex, silent install /S).
# Change applied: removed all `pause` calls (get.ps1 runs via irm | iex).
Write-Step "Verificando Ghostscript (motor de impresion)..."
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

            # Verificar integridad antes de ejecutar
            $gsOk = $false
            if ($gsExpectedSha256) {
                $actual = (Get-FileHash -LiteralPath $tempGs -Algorithm SHA256).Hash
                if ($actual -ne $gsExpectedSha256) {
                    Remove-Item $tempGs -Force -ErrorAction SilentlyContinue
                    Write-Fail "El hash SHA-256 del instalador de Ghostscript no coincide."
                    Write-Fail "  Esperado: $gsExpectedSha256"
                    Write-Fail "  Obtenido: $actual"
                    Write-Fail "Descarga abortada por seguridad. Reinstala manualmente desde ghostscript.com."
                    throw "GS installer SHA256 mismatch"
                }
                $gsOk = $true
            } else {
                # Sin hash conocido: verificar firma Authenticode
                $sig = Get-AuthenticodeSignature -LiteralPath $tempGs
                if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notlike "*Artifex*") {
                    Remove-Item $tempGs -Force -ErrorAction SilentlyContinue
                    Write-Fail "La firma digital del instalador de Ghostscript no es valida o no pertenece a Artifex."
                    Write-Fail "  Estado: $($sig.Status)"
                    Write-Fail "  Firmante: $($sig.SignerCertificate.Subject)"
                    Write-Fail "Descarga abortada por seguridad. Reinstala manualmente desde ghostscript.com."
                    throw "GS installer Authenticode signature invalid"
                }
                $gsOk = $true
            }

            if ($gsOk) {
                Start-Process -FilePath $tempGs -ArgumentList "/S" -Wait
                Remove-Item $tempGs -Force -ErrorAction SilentlyContinue
                $gsPath = Find-Gs
            }
        } catch {
            Write-Warn "Instalacion de Ghostscript fallo: $_"
        }
    }
    if ($gsPath) { Write-OK "Ghostscript instalado: $gsPath" }
}

if (-not $gsPath) {
    Write-Fail "Ghostscript es el motor de impresion y no pudo instalarse. Revisa tu conexion o instalalo desde ghostscript.com e intenta de nuevo."
    throw "Ghostscript installation failed"
}

# --- 7. config.json (only if not present; upgrade otherwise) ---
$configPath = Join-Path $installPath "config.json"
if (-not (Test-Path $configPath)) {
    $defaultDownload = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"
    @{ printer = ""; copies = 2; gsPath = $gsPath; installPath = $installPath
       downloadFolder = $defaultDownload; autoStart = $true; enableLogging = $true } |
        ConvertTo-Json | Set-Content $configPath -Encoding UTF8
} else {
    # Upgrade: refresh gsPath/installPath, preserve the rest.
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $cfg.installPath = $installPath
    if ($gsPath) { $cfg.gsPath = $gsPath }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
}

# --- 8. Scheduled task ---
Write-Step "Registrando tarea programada..."
# Remove existing task (with elevation fallback), copied from Install.ps1:199-273.
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-OK "Tarea anterior eliminada (se re-registra apuntando a la instalacion estable)"
    } catch {
        Write-Warn "La tarea existente fue creada como Administrador. Intentando eliminar con schtasks..."
        try {
            & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
        } catch {
            Write-Warn "schtasks /Delete fallo: $_"
        }
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Write-Warn "Acepta el UAC para eliminar la tarea con permisos de Administrador..."
            try {
                Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile -NonInteractive -Command `"Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false`""
            } catch {
                Write-Warn "Elevacion cancelada."
            }
        }
    }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Write-Fail "La tarea existente no pudo eliminarse. Ejecuta como Administrador: Unregister-ScheduledTask -TaskName $taskName -Confirm:0  y reinstala."
        throw "Scheduled task '$taskName' could not be removed; aborting to avoid registering on top of a broken task"
    }
}

$action   = New-ScheduledTaskAction -Execute (Join-Path $installPath "LidaPrint.exe") -Argument "-Service"
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $taskName
} catch {
    Write-Warn "El servicio arrancara en el proximo inicio de sesion."
}

# --- 9. Start Menu shortcut ---
$shortcutDir = [Environment]::GetFolderPath("Programs")
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut((Join-Path $shortcutDir "LidaPrint.lnk"))
$sc.TargetPath = Join-Path $installPath "LidaPrint.exe"
$sc.WorkingDirectory = $installPath
$sc.Save()

# --- 10. PATH (user scope) ---
# Copied verbatim from Install.ps1:275-286.
Write-Step "Agregando la instalacion al PATH del usuario..."
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $userPath) { $userPath = "" }
if (($userPath -split ';') -notcontains $installPath) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$installPath").TrimStart(';'), 'User')
    Write-OK "PATH actualizado. Abre una consola NUEVA y ejecuta: lidaprint"
} else {
    Write-OK "La instalacion ya esta en el PATH"
}

# --- 11. Summary + first-run ---
Write-Host ""
Write-Host "LidaPrint $($release.tag_name) instalado en $installPath" -ForegroundColor Green
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json
if (-not $cfg.printer) {
    Write-Step "Abriendo el Configurador (primera instalacion)..."
    Start-Process -FilePath (Join-Path $installPath "LidaPrint.exe")
}
