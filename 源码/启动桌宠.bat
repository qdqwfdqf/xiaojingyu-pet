@echo off
rem Fallback launcher (shows a console briefly). Prefer ??.exe or the VBS.
cd /d "%~dp0"
if not exist "deskpet.ps1" cd /d "%~dp0app"
if not exist "deskpet.ps1" (
  echo deskpet.ps1 not found. Please extract the whole package again.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "deskpet.ps1"
exit