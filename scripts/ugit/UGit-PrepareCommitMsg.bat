@echo off
setlocal EnableExtensions

REM prepare-commit-msg: prefix commit subject after config-table confirm.

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%ApplyCommitMsgPrefix.ps1"
set "MSGFILE=%~1"

if "%MSGFILE%"=="" exit /b 0
if not exist "%PS1%" exit /b 0

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -MessageFile "%MSGFILE%"
exit /b %ERRORLEVEL%
