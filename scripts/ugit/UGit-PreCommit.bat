@echo off
setlocal EnableExtensions

REM Always: hook version check. On workspace config Excel change: confirm, then validate (optional product add).

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%..\.."
set "REPO_ROOT=%CD%"
popd
set "BUILD_BAT=%SCRIPT_DIR%BuildConfig.bat"
set "ALERT_PS1=%SCRIPT_DIR%ShowHookAlert.ps1"
set "CHECK_PS1=%SCRIPT_DIR%Check-HookVersion.ps1"
set "CONFIRM_PS1=%SCRIPT_DIR%ShowBuildConfirmPrompt.ps1"
set "LOG_FILE=%REPO_ROOT%\scripts\ugit\precommit-last.log"
set "ERR_FILE=%REPO_ROOT%\scripts\ugit\precommit-last-error.txt"
set "ERR_KIND=%REPO_ROOT%\scripts\ugit\precommit-last-error.kind"
set "MSG_KIND=%REPO_ROOT%\scripts\ugit\precommit-last-msg-kind"
set "CFG_LUAU=src\ReplicatedFirst\AllSideCode\ToolBasic\ConfigInstance.luau"
set "LANG_LUAU=src\ReplicatedFirst\AllSideCode\ToolBasic\TranslationHelper\Language.luau"

cd /d "%REPO_ROOT%"
if errorlevel 1 goto FailRepoCd

echo [%DATE% %TIME%] start >>"%LOG_FILE%"

REM Require local hook stamp to match the ugit version file (any commit, not only Excel)
if exist "%ERR_FILE%" del /f /q "%ERR_FILE%" >nul 2>nul
if exist "%ERR_KIND%" del /f /q "%ERR_KIND%" >nul 2>nul
if exist "%CHECK_PS1%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%CHECK_PS1%" -RepoRoot "%REPO_ROOT%"
  if errorlevel 1 (
    echo [UGit-PreCommit] hook version outdated
    if exist "%ALERT_PS1%" powershell -NoProfile -ExecutionPolicy Bypass -File "%ALERT_PS1%" -Reason HookOutdated -Level Warning
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CHECK_PS1%" -RepoRoot "%REPO_ROOT%"
    if errorlevel 1 goto FailVersion
  )
)

if not exist "%CONFIRM_PS1%" goto FailConfirmMissing

REM DetectOnly: 0=no xlsx changes, 3=need prompt, other=fail (do not use errorlevel GE)
powershell -NoProfile -ExecutionPolicy Bypass -File "%CONFIRM_PS1%" -RepoRoot "%REPO_ROOT%" -DetectOnly
set "DETECT_EC=%ERRORLEVEL%"
if "%DETECT_EC%"=="0" (
  echo [UGit-PreCommit] no workspace config xlsx, skip build
  echo skip_build >>"%LOG_FILE%"
  if exist "%MSG_KIND%" del /f /q "%MSG_KIND%" >nul 2>nul
  exit /b 0
)
if not "%DETECT_EC%"=="3" goto FailDetect

echo [UGit-PreCommit] config xlsx change detected, confirm build...
powershell -NoProfile -ExecutionPolicy Bypass -File "%CONFIRM_PS1%" -RepoRoot "%REPO_ROOT%"
set "CONFIRM_EC=%ERRORLEVEL%"
if "%CONFIRM_EC%"=="0" (
  echo staged_only_build >>"%LOG_FILE%"
  >"%MSG_KIND%" echo build
  goto DoBuildStaged
)
if "%CONFIRM_EC%"=="5" (
  echo stage_extra >>"%LOG_FILE%"
  >"%MSG_KIND%" echo build
  goto DoBuildDisk
)
if "%CONFIRM_EC%"=="10" (
  echo skip_products_validate >>"%LOG_FILE%"
  >"%MSG_KIND%" echo nbuild
  goto DoValidateStaged
)
if "%CONFIRM_EC%"=="20" goto FailCancel
goto FailConfirm

:DoBuildStaged
echo [UGit-PreCommit] full-disk validate then copy luau to src
echo building >>"%LOG_FILE%"
if exist "%ERR_FILE%" del /f /q "%ERR_FILE%" >nul 2>nul
if exist "%ERR_KIND%" del /f /q "%ERR_KIND%" >nul 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%CONFIRM_PS1%" -RepoRoot "%REPO_ROOT%" -RunStagedBuild
if errorlevel 1 goto FailBuild
if exist "%ERR_FILE%" goto FailBuild
goto StageProducts

:DoValidateStaged
echo [UGit-PreCommit] full-disk validate, do not stage luau
echo validate_only >>"%LOG_FILE%"
if exist "%ERR_FILE%" del /f /q "%ERR_FILE%" >nul 2>nul
if exist "%ERR_KIND%" del /f /q "%ERR_KIND%" >nul 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%CONFIRM_PS1%" -RepoRoot "%REPO_ROOT%" -RunStagedBuild -ValidateOnly
if errorlevel 1 goto FailBuild
if exist "%ERR_FILE%" goto FailBuild
echo [UGit-PreCommit] validate ok; skip staging ConfigInstance.luau Language.luau
echo ok validate_only >>"%LOG_FILE%"
exit /b 0

:DoBuildDisk
echo [UGit-PreCommit] config xlsx change detected, building from disk...
echo building >>"%LOG_FILE%"
if exist "%ERR_FILE%" del /f /q "%ERR_FILE%" >nul 2>nul
if exist "%ERR_KIND%" del /f /q "%ERR_KIND%" >nul 2>nul
call "%BUILD_BAT%" Framework
if errorlevel 1 goto FailBuild
if exist "%ERR_FILE%" goto FailBuild

:StageProducts
git add -- "%CFG_LUAU%" "%LANG_LUAU%"
if errorlevel 1 goto FailGitAdd
echo [UGit-PreCommit] build ok; staged ConfigInstance.luau Language.luau
echo ok staged >>"%LOG_FILE%"
exit /b 0

:FailCancel
echo [UGit-PreCommit] user cancelled commit at build confirm
echo cancel_build >>"%LOG_FILE%"
if exist "%MSG_KIND%" del /f /q "%MSG_KIND%" >nul 2>nul
exit /b 1

:FailConfirm
echo [UGit-PreCommit] build confirm prompt failed
echo confirm_fail >>"%LOG_FILE%"
if exist "%ALERT_PS1%" powershell -NoProfile -ExecutionPolicy Bypass -File "%ALERT_PS1%" -Reason BuildFailed -Level Error
exit /b 1

:FailDetect
echo [UGit-PreCommit] config xlsx detect failed
echo detect_fail >>"%LOG_FILE%"
exit /b 1

:FailConfirmMissing
echo [UGit-PreCommit] missing ShowBuildConfirmPrompt.ps1, abort commit
echo confirm_missing >>"%LOG_FILE%"
if exist "%ALERT_PS1%" powershell -NoProfile -ExecutionPolicy Bypass -File "%ALERT_PS1%" -Reason Custom -Level Error -Message "missing scripts/ugit/ShowBuildConfirmPrompt.ps1; commit aborted (no silent table-build)"
exit /b 1

:FailRepoCd
echo [UGit-PreCommit] cannot cd to repo root
if exist "%ALERT_PS1%" powershell -NoProfile -ExecutionPolicy Bypass -File "%ALERT_PS1%" -Reason RepoCdFailed -Level Error
exit /b 1

:FailVersion
echo [UGit-PreCommit] hook version check failed
echo version_fail >>"%LOG_FILE%"
exit /b 1

:FailBuild
echo [UGit-PreCommit] build failed
if exist "%MSG_KIND%" del /f /q "%MSG_KIND%" >nul 2>nul
if exist "%ALERT_PS1%" powershell -NoProfile -ExecutionPolicy Bypass -File "%ALERT_PS1%" -Reason BuildFailed -Level Error
exit /b 1

:FailGitAdd
echo [UGit-PreCommit] git add products failed
if exist "%ALERT_PS1%" powershell -NoProfile -ExecutionPolicy Bypass -File "%ALERT_PS1%" -Reason GitAddFailed -Level Error
exit /b 1
