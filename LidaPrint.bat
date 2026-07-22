@echo off
set "myPath=%~dp0"
set "myPath=%myPath:~0,-1%"
echo %PATH% | findstr /I /C:"%myPath%" >nul 2>&1
if errorlevel 1 (
    powershell -ExecutionPolicy Bypass -Command "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';%myPath%', 'User')"
)
start "" "%~dp0LidaPrint.vbs"
