@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0splitswan-wsl.ps1" -Action status -PauseAtEnd %*
