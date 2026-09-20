@echo off
setlocal EnableExtensions
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0UGit-Git.ps1" %*
exit /b %ERRORLEVEL%

