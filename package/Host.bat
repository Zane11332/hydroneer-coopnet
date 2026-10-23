@echo off
rem Hydroneer Co-op: host. Creates a friends-only Steam lobby; keep this window open while playing.
title Hydroneer Co-op - HOST
if not exist "%~dp0installed.json" echo Run Install.bat first. & pause & exit /b 1
if not exist "%~dp0logs" mkdir "%~dp0logs"
cd /d "%~dp0relay"
"%~dp0python\python.exe" -I coopnet_relay.py --role host --transport steam --run-dir "%~dp0run" --log "%~dp0logs\relay-host.log" %*
pause
