@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title [3] Local Config Build (Test)
echo.
echo ========================================
echo   [3] Local Config Build (Test)
echo   Excel -^> .build + src luau (no commit)
echo ========================================
echo.
call "%~dp0BuildConfig.bat" Framework
set "EC=%ERRORLEVEL%"
echo.
if "%EC%"=="0" (
  echo OK. Updated config/.build and src ConfigInstance/Language.
  echo Test in Studio, then commit when ready.
) else (
  echo FAILED. exit=%EC%
  if exist "%~dp0ShowHookAlert.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ShowHookAlert.ps1" -Reason BuildFailed -Level Error
  )
)
echo.
pause
exit /b %EC%
