@echo off
setlocal
title LidaPrint - Instalador

:: ============================================================
::  LidaPrint - Instalador
::  Doble clic para instalar. Instala a %LOCALAPPDATA%\LidaPrint
::  (no requiere Administrador), instala SumatraPDF y Ghostscript,
::  crea la tarea programada y abre el Configurator al terminar.
::  Delega todo el trabajo en Install.ps1.
:: ============================================================

cd /d "%~dp0"

if not exist "%~dp0Install.ps1" (
    echo [ERROR] No se encontro Install.ps1 en esta carpeta.
    echo Ejecuta Instalador.bat desde la carpeta del proyecto.
    echo.
    pause
    exit /b 1
)

echo ============================================
echo    LidaPrint - Instalador
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"

echo.
echo Instalacion finalizada.
pause
