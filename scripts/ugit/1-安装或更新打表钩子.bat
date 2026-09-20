@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title [1] Install or Update UGit Hooks
echo.
echo ========================================
echo   [1] Install / Update UGit Hooks
echo   (pre-commit/push version check + pre-merge + ugit-sync + pull.rebase)
echo ========================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-GitHook.ps1" %*
set "EC=%ERRORLEVEL%"
echo.
if "%EC%"=="0" (
  echo OK. Hook installed/updated.
) else (
  echo FAILED. exit=%EC%
)
echo.
pause
exit /b %EC%
