@echo off
rem 双击启动 Claude Code 桌宠（无黑窗）；已经在跑时不会重复启动
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0pet\desk-pet.ps1"
