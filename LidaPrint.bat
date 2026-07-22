@echo off
:: Abre el Configurator sin dejar consola abierta.
:: Delega en LidaPrint.vbs, que lanza PowerShell oculto como proceso
:: independiente: cerrar la consola desde la que se ejecuto este .bat
:: no cierra el Configurator.
start "" wscript.exe "%~dp0LidaPrint.vbs"
