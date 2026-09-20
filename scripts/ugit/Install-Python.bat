@echo off
setlocal EnableExtensions
cd /d "%~dp0"
REM Compat alias. Prefer: 2-*.bat in this folder.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Python.ps1" %*
exit /b %ERRORLEVEL%
