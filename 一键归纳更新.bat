@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0sync_to_share.ps1"
pause
