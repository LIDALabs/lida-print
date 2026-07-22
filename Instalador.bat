@echo off
setlocal
title LidaPrint - Instalador

:: ============================================================
::  LidaPrint - Instalador
::  Doble clic para instalar. Se eleva a Administrador solo,
::  instala SumatraPDF, copia los scripts y crea la tarea
::  programada. Delega todo el trabajo en Install.ps1.
:: ============================================================

:: --- Verificar permisos de administrador ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

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
