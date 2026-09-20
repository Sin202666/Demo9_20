@echo off
setlocal EnableExtensions
cd /d "%~dp0"
REM Compat alias. Prefer: 1-*.bat in this folder.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-GitHook.ps1" %*
exit /b %ERRORLEVEL%
