@echo off
rem Hydroneer Co-op: opens the launcher window (install, uninstall, host, join, logs)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0launcher.ps1"
