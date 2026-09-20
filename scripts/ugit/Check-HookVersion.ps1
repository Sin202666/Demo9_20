#Requires -Version 5.1
<#
.SYNOPSIS
  Compare scripts/ugit/VERSION with .git/hooks/ugit-version.
  Exit 0 if up to date; exit 1 if outdated / not installed (writes error files for ShowHookAlert).
  Called from pre-commit (every commit) and pre-push.
#>
param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

function Decode-Utf8B64([string]$Text) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Write-HookError([string]$Message, [string]$Kind) {
    $dir = $PSScriptRoot
    $errPath = Join-Path $dir "precommit-last-error.txt"
    $kindPath = Join-Path $dir "precommit-last-error.kind"
    $utf8bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($errPath, ($Message.Trim() + "`r`n"), $utf8bom)
    [System.IO.File]::WriteAllText($kindPath, ($Kind.Trim() + "`r`n"), [System.Text.Encoding]::ASCII)
}

if (-not $RepoRoot) {
    $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}

$versionFile = Join-Path $PSScriptRoot "VERSION"
$installedFile = Join-Path $RepoRoot ".git\hooks\ugit-version"

if (-not (Test-Path -LiteralPath $versionFile)) {
    Write-Host "[Check-HookVersion] no VERSION file, skip"
    exit 0
}

$expected = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction Stop).Trim()
if (-not $expected) {
    Write-Host "[Check-HookVersion] empty VERSION, skip"
    exit 0
}

$installed = ""
if (Test-Path -LiteralPath $installedFile) {
    $installed = (Get-Content -LiteralPath $installedFile -Raw -ErrorAction SilentlyContinue)
    if ($installed) { $installed = $installed.Trim() }
}

if ($installed -eq $expected) {
    Write-Host "[Check-HookVersion] ok version=$expected"
    exit 0
}

$installedShow = if ($installed) { $installed } else { "(not installed)" }
Write-Host "[Check-HookVersion] outdated installed=$installedShow expected=$expected"

$head = Decode-Utf8B64 "6YWN572u5omT6KGo6ZKp5a2Q54mI5pys6L+H5pyf77yM5o+Q5Lqk5bey5Lit5q2i44CC"
$line1 = Decode-Utf8B64 "5LuT5bqT6YeM55qE5omT6KGo6ISa5pys5bey5pu05paw77yM5L2G5pys5py65bCa5pyq5a6J6KOF5Yiw5pyA5paw6ZKp5a2Q54mI5pys44CC"
$curLabel = Decode-Utf8B64 "5b2T5YmN5bey5a6J6KOF54mI5pysOiA="
$newLabel = Decode-Utf8B64 "5LuT5bqT6ISa5pys54mI5pysOiA="
$hint = Decode-Utf8B64 "6K+354K55Ye75LiL5pa557u/6Imy5oyJ6ZKu44CM5LiA6ZSu5pu05paw6ZKp5a2Q44CN77yM5oiW5Y+M5Ye76L+Q6KGM77yaCiAgc2NyaXB0c1x1Z2l0XDEt5a6J6KOF5oiW5pu05paw5omT6KGo6ZKp5a2QLmJhdAoK5pu05paw5a6M5oiQ5ZCO77yM6K+36YeN5paw5o+Q5Lqk44CC"

$msg = @(
    $head
    ""
    $line1
    ""
    ($curLabel + $installedShow)
    ($newLabel + $expected)
    ""
    $hint
) -join "`r`n"

Write-HookError $msg "HookOutdated"
exit 1
