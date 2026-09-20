@echo off
setlocal EnableExtensions

REM pre-push entry: RemoteName + stdin file path from generated hook wrapper
REM Repo root must be the repo being pushed (not scripts/ugit parent).

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%UGit-PrePush.ps1"

set "REMOTE_NAME=%~1"
set "STDIN_FILE=%~2"

if "%REMOTE_NAME%"=="" (
  echo [UGit-PrePush] missing remote name
  exit /b 1
)
if "%STDIN_FILE%"=="" (
  echo [UGit-PrePush] missing stdin file
  exit /b 1
)

set "REPO_ROOT="
for /f "delims=" %%I in ('git rev-parse --show-toplevel 2^>nul') do set "REPO_ROOT=%%I"
if "%REPO_ROOT%"=="" (
  echo [UGit-PrePush] cannot resolve git toplevel
  exit /b 1
)

cd /d "%REPO_ROOT%"
if errorlevel 1 (
  echo [UGit-PrePush] cannot cd to repo root
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RemoteName "%REMOTE_NAME%" -StdinFile "%STDIN_FILE%" -RepoRoot "%REPO_ROOT%"
exit /b %ERRORLEVEL%