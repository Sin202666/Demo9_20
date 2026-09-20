echo off
setlocal EnableExtensions
cd /d "%~dp0"
title [2] Install Python for Config Build
echo.
echo ========================================
echo   [2] Install Python 3.12 + openpyxl (need 3.10+)
echo ========================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Python.ps1" %*
set "EC=%ERRORLEVEL%"
echo.
if "%EC%"=="0" (
  echo OK. Python environment ready.
  echo Retry your git commit.
) else (
  echo FAILED. exit=%EC%
)
echo.
pause
exit /b %EC%
