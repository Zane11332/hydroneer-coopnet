@echo off
rem Hydroneer Co-op: join a Steam friend who is hosting. Optional: Join.bat --lobby <id>
title Hydroneer Co-op - JOIN
if not exist "%~dp0installed.json" echo Run Install.bat first. & pause & exit /b 1
if not exist "%~dp0logs" mkdir "%~dp0logs"
cd /d "%~dp0relay"
"%~dp0python\python.exe" -I coopnet_relay.py --role client --transport steam --run-dir "%~dp0run" --log "%~dp0logs\relay-join.log" %*
pause
