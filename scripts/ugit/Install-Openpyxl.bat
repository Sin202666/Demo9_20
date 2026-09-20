@echo off
setlocal EnableExtensions
cd /d "%~dp0"
REM Compat alias. Prefer: 2-*.bat (installs Python + openpyxl).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Python.ps1" %*
exit /b %ERRORLEVEL%
