@echo off
rem Hydroneer Co-op: install (backs up your saves first)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
