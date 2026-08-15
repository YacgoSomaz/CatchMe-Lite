@echo off
setlocal
set "CATCHME_SCRIPT=%~dp0CatchMe.ps1"
start "" /b "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%CATCHME_SCRIPT%" -StartAuthorized
endlocal
