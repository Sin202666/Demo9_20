@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%BuildConfig.ps1"

if not exist "%PS1%" (
  echo [BuildConfig] missing BuildConfig.ps1
  exit /b 1
)

set "MODE=%~1"
set "PROJECT=%~2"
set "A3=%~3"
set "A4=%~4"

if "%MODE%"=="" set "MODE=Framework"

if /I "%MODE%"=="Work" (
  if "%PROJECT%"=="" (
    echo [BuildConfig] Work mode needs project name: BuildConfig.bat Work T49
    exit /b 1
  )
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Work -ProjectName "%PROJECT%" %A3% %A4%
) else if /I "%MODE%"=="Framework" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Framework %PROJECT% %A3% %A4%
) else (
  echo [BuildConfig] unknown mode: %MODE%
  exit /b 1
)

set "EC=%ERRORLEVEL%"
if not "%EC%"=="0" (
  echo [BuildConfig] failed exit=%EC%
  exit /b %EC%
)
echo [BuildConfig] success
exit /b 0
