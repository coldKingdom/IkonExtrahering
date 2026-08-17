@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh.exe^) hittades inte.
  echo Installera PowerShell 7 och prova igen.
  pause
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Ikonextraheraren.ps1" %*
if errorlevel 1 pause
