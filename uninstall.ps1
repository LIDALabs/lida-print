<#
.SYNOPSIS
    Desinstalacion completa de LidaPrint en un solo comando.
.DESCRIPTION
    Elimina la tarea programada, la instalacion actual, la instalacion
    vieja (si existe) y la entrada del PATH del usuario. Es idempotente:
    se puede correr aunque algo ya no exista, no falla.
    No desinstala Ghostscript (una reinstalacion lo reutiliza).
.NOTES
    Uso (PowerShell, sin admin):
      irm https://raw.githubusercontent.com/LIDALabs/lida-print/main/uninstall.ps1 | iex
#>

$ErrorActionPreference = "SilentlyContinue"

$installPath = Join-Path $env:LOCALAPPDATA "LidaPrint"
$oldPath     = "C:\AutoPrintFacturas"
$taskName    = "LidaPrint"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  LidaPrint - Desinstalacion" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# 1. Detener y eliminar la tarea programada
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host "[OK] Tarea programada eliminada" -ForegroundColor Green
    } catch {
        Write-Host "[!] No se pudo eliminar la tarea (creada como admin). Ejecuta este comando en PowerShell de Administrador." -ForegroundColor Yellow
    }
} else {
    Write-Host "[OK] Tarea programada: no existia" -ForegroundColor Green
}

# 2. Cerrar procesos del monitor que sigan corriendo
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*LidaPrint.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 1000

# 3. Eliminar instalacion actual
if (Test-Path $installPath) {
    Remove-Item -LiteralPath $installPath -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $installPath) {
        Write-Host "[!] No se pudo eliminar completamente: $installPath" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Eliminado: $installPath" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] Instalacion actual: no existia" -ForegroundColor Green
}

# 4. Eliminar instalacion vieja
if (Test-Path $oldPath) {
    Remove-Item -LiteralPath $oldPath -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $oldPath) {
        Write-Host "[!] No se pudo eliminar completamente: $oldPath" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Eliminado: $oldPath (instalacion vieja)" -ForegroundColor Green
    }
}

# 5. Limpiar el PATH del usuario
$p = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($p) {
    $clean = ($p -split ';' | Where-Object { $_ -and $_ -ne $installPath -and $_ -ne $oldPath }) -join ';'
    if ($clean -ne $p) {
        [Environment]::SetEnvironmentVariable('Path', $clean, 'User')
        Write-Host "[OK] PATH del usuario limpiado" -ForegroundColor Green
    } else {
        Write-Host "[OK] PATH: sin entradas de LidaPrint" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Desinstalacion completa." -ForegroundColor Green
Write-Host "Ghostscript NO se elimino (una reinstalacion lo reutiliza)." -ForegroundColor Gray
Write-Host "Para quitarlo: winget uninstall ArtifexSoftware.GhostScript" -ForegroundColor Gray
Write-Host "Si tenias SumatraPDF de versiones anteriores: winget uninstall SumatraPDF.SumatraPDF" -ForegroundColor Gray
Write-Host ""
