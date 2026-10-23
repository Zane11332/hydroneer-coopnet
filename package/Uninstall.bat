@echo off
rem Hydroneer Co-op: remove everything Install.bat added
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
pause
