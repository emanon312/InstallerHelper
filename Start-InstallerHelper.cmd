@echo off
rem InstallerHelper launcher
set "PS1=%~dp0InstallerHelper.ps1"
if not exist "%PS1%" ( echo [!] Cannot find InstallerHelper.ps1 & pause & exit /b 1 )
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS1%"
exit /b 0
