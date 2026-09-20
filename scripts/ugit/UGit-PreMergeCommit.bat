@echo off
setlocal EnableExtensions

REM pre-merge-commit entry: block merge commit and show rebase guidance.

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%UGit-PreMergeCommit.ps1"

set "REPO_ROOT="
for /f "delims=" %%I in ('git rev-parse --show-toplevel 2^>nul') do set "REPO_ROOT=%%I"
if "%REPO_ROOT%"=="" (
  echo [UGit-PreMergeCommit] cannot resolve git toplevel
  exit /b 1
)

cd /d "%REPO_ROOT%"
if errorlevel 1 (
  echo [UGit-PreMergeCommit] cannot cd to repo root
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RepoRoot "%REPO_ROOT%"
exit /b %ERRORLEVEL%
