@echo off
rem Start the Claude Code desk pet without a console window (single instance).
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0pet\desk-pet.ps1"
