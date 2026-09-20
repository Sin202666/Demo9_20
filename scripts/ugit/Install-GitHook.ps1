#Requires -Version 5.1
param(
    [string]$RepoRoot = "",
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

function Invoke-GitLocal([string[]]$GitArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & git @GitArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return @{ Code = $code; Output = [string]::Join([Environment]::NewLine, @($output)) }
}

if (-not $RepoRoot) {
    $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}

$preCommitBat = Join-Path $PSScriptRoot "UGit-PreCommit.bat"
$prePushBat = Join-Path $PSScriptRoot "UGit-PrePush.bat"
$preMergeCommitBat = Join-Path $PSScriptRoot "UGit-PreMergeCommit.bat"
$prepareCommitMsgBat = Join-Path $PSScriptRoot "UGit-PrepareCommitMsg.bat"
$safeSyncPs1 = Join-Path $PSScriptRoot "UGit-SafeSync.ps1"
$gitWrapperCmd = Join-Path $PSScriptRoot "UGit-Git.cmd"
$realGitMarker = Join-Path $PSScriptRoot "ugit-real-git.txt"
$preCommitDst = Join-Path $RepoRoot ".git\hooks\pre-commit"
$prePushDst = Join-Path $RepoRoot ".git\hooks\pre-push"
$preMergeCommitDst = Join-Path $RepoRoot ".git\hooks\pre-merge-commit"
$prepareCommitMsgDst = Join-Path $RepoRoot ".git\hooks\prepare-commit-msg"
$versionSrc = Join-Path $PSScriptRoot "VERSION"
$versionDst = Join-Path $RepoRoot ".git\hooks\ugit-version"
$repoGitConfig = Join-Path $RepoRoot ".gitconfig"
$repoGitConfigTemplate = Join-Path $PSScriptRoot "repo.gitconfig"
$includePath = "../.gitconfig"

if (-not (Test-Path -LiteralPath $preCommitBat)) {
    throw "missing $preCommitBat"
}
if (-not (Test-Path -LiteralPath $prePushBat)) {
    throw "missing $prePushBat"
}
if (-not (Test-Path -LiteralPath $preMergeCommitBat)) {
    throw "missing $preMergeCommitBat"
}
if (-not (Test-Path -LiteralPath $prepareCommitMsgBat)) {
    throw "missing $prepareCommitMsgBat"
}
if (-not (Test-Path -LiteralPath $safeSyncPs1)) {
    throw "missing $safeSyncPs1"
}
if (-not (Test-Path -LiteralPath $gitWrapperCmd)) {
    throw "missing $gitWrapperCmd"
}

function Resolve-RealGitPath {
    if (Test-Path -LiteralPath $realGitMarker) {
        $saved = (Get-Content -LiteralPath $realGitMarker -Raw -ErrorAction SilentlyContinue)
        if ($saved) {
            $saved = $saved.Trim()
            if ($saved -and (Test-Path -LiteralPath $saved)) {
                if ($saved -notmatch 'UGit-Git') { return $saved }
            }
        }
    }
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "git.exe not found in PATH" }
    if ($cmd.Source -match 'UGit-Git') { throw "git.exe resolves to UGit wrapper; fix PATH or ugit-real-git.txt" }
    return $cmd.Source
}

function Test-IsLfEol([object]$Value) {
    if ($null -eq $Value) { return $false }
    $s = [string]$Value
    return ($s -eq "`n") -or ($s.Length -eq 1 -and [int][char]$s[0] -eq 10)
}

function ConvertTo-VscodeSettingsJson([System.Collections.Specialized.OrderedDictionary]$Ordered) {
    # Hand-written JSON so files.eol stays "\n" (LF), not PowerShell ConvertTo-Json's "\\n".
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("{")
    $keys = @($Ordered.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = [string]$keys[$i]
        $v = $Ordered[$k]
        $comma = if ($i -lt $keys.Count - 1) { "," } else { "" }
        if ($v -is [bool]) {
            $js = if ($v) { "true" } else { "false" }
            [void]$lines.Add(('  "{0}": {1}{2}' -f $k, $js, $comma))
        } elseif ($v -is [int] -or $v -is [long] -or $v -is [decimal] -or $v -is [double]) {
            [void]$lines.Add(('  "{0}": {1}{2}' -f $k, $v, $comma))
        } elseif (Test-IsLfEol $v) {
            [void]$lines.Add(('  "{0}": "\n"{1}' -f $k, $comma))
        } elseif (($null -ne $v) -and ([string]$v -eq "`r`n")) {
            [void]$lines.Add(('  "{0}": "\r\n"{1}' -f $k, $comma))
        } else {
            $escaped = ([string]$v).Replace("\", "\\").Replace('"', '\"')
            [void]$lines.Add(('  "{0}": "{1}"{2}' -f $k, $escaped, $comma))
        }
    }
    [void]$lines.Add("}")
    return (($lines -join "`n") + "`n")
}

function Update-VscodeSettings([string]$Root) {
    $settingsPath = Join-Path $Root ".vscode\settings.json"
    $dir = Split-Path $settingsPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $wantPath = '${workspaceFolder}/scripts/ugit/UGit-Git.cmd'
    $obj = [ordered]@{}
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $parsed = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $parsed.PSObject.Properties | ForEach-Object { $obj[$_.Name] = $_.Value }
        } catch {}
    }

    $alreadyOk = (
        (Test-IsLfEol $obj["files.eol"]) -and
        ($obj["files.encoding"] -eq "utf8") -and
        ($obj["files.insertFinalNewline"] -eq $true) -and
        ($obj["files.trimTrailingWhitespace"] -eq $true) -and
        ($obj["git.path"] -eq $wantPath) -and
        ($obj["git.autoStash"] -eq $true) -and
        ($obj["git.rebaseWhenSync"] -eq $true)
    )
    if ($alreadyOk) {
        Write-Host "vscode settings already ok, skip rewrite"
        return
    }

    # Use real LF char; JSON writer emits "\n" (not "\\n").
    $obj["files.eol"] = "`n"
    $obj["files.encoding"] = "utf8"
    $obj["files.insertFinalNewline"] = $true
    $obj["files.trimTrailingWhitespace"] = $true
    $obj["git.autoStash"] = $true
    $obj["git.rebaseWhenSync"] = $true
    $obj["git.path"] = $wantPath
    # git.path leftover for IDE; Cursor 3.15.6+ Source Control still skips hooks.
    # Do not rely on the panel commit for table-build; use terminal git / UGit client.

    $ordered = [ordered]@{}
    foreach ($k in @(
            "files.eol", "files.encoding", "files.insertFinalNewline", "files.trimTrailingWhitespace",
            "git.path", "git.autoStash", "git.rebaseWhenSync"
        )) {
        if ($obj.Contains($k)) { $ordered[$k] = $obj[$k] }
    }
    foreach ($k in ($obj.Keys | Sort-Object)) {
        if (-not $ordered.Contains($k)) { $ordered[$k] = $obj[$k] }
    }

    $newText = ConvertTo-VscodeSettingsJson $ordered
    $oldText = ""
    if (Test-Path -LiteralPath $settingsPath) {
        try { $oldText = [System.IO.File]::ReadAllText($settingsPath) } catch { $oldText = "" }
    }
    if ($oldText -eq $newText) {
        Write-Host "vscode settings content unchanged, skip write"
        return
    }
    [System.IO.File]::WriteAllText($settingsPath, $newText, $utf8)
    Write-Host "vscode settings updated (managed keys only when missing/wrong)"
}

$utf8 = New-Object System.Text.UTF8Encoding $false

if (-not (Test-Path -LiteralPath $repoGitConfig)) {
    if (Test-Path -LiteralPath $repoGitConfigTemplate) {
        Write-Host "note: missing $repoGitConfig; copy from scripts/ugit/repo.gitconfig"
        Copy-Item -LiteralPath $repoGitConfigTemplate -Destination $repoGitConfig -Force
    } else {
        Write-Host "note: missing $repoGitConfig; write default pull.rebase config"
        $defaultGitConfig = @(
            "# Repo Git defaults. Applied after running scripts/ugit/1-安装或更新打表钩子.bat"
            "# (.git/config: include.path = ../.gitconfig)"
            "[pull]"
            "    rebase = true"
            "[rebase]"
            "    autoStash = true"
            ""
        ) -join "`n"
        [System.IO.File]::WriteAllText($repoGitConfig, $defaultGitConfig, $utf8)
    }
}

$hooksDir = Split-Path $preCommitDst -Parent
if (-not (Test-Path -LiteralPath $hooksDir)) {
    throw "missing $hooksDir (is this a git repo?)"
}

$version = "0"
if (Test-Path -LiteralPath $versionSrc) {
    $version = (Get-Content -LiteralPath $versionSrc -Raw).Trim()
    if (-not $version) { $version = "0" }
}

# $utf8 defined above for .gitconfig bootstrap

# --- pre-commit ---
$preCommitBatUnix = ([System.IO.Path]::GetFullPath($preCommitBat)) -replace "\\", "/"
$preCommitLines = @(
    "#!/bin/sh"
    "# Auto-generated by Install-GitHook - do not edit"
    ("# ugit-version: {0}" -f $version)
    ('cmd.exe //c "{0}"' -f $preCommitBatUnix)
    'exit $?'
)
[System.IO.File]::WriteAllText($preCommitDst, (($preCommitLines -join "`n") + "`n"), $utf8)

# --- pre-push (must preserve stdin refs for Git) ---
$prePushBatUnix = ([System.IO.Path]::GetFullPath($prePushBat)) -replace "\\", "/"
$prePushLines = @(
    "#!/bin/sh"
    "# Auto-generated by Install-GitHook - do not edit"
    ("# ugit-version: {0}" -f $version)
    '# Capture push refs from stdin; cmd.exe does not forward hook stdin reliably.'
    'stdin_file="$(git rev-parse --absolute-git-dir)/ugit-prepush-stdin.txt"'
    'cat > "$stdin_file"'
    ('cmd.exe //c "{0}" "$1" "$stdin_file"' -f $prePushBatUnix)
    'ec=$?'
    'rm -f "$stdin_file"'
    'exit $ec'
)
[System.IO.File]::WriteAllText($prePushDst, (($prePushLines -join "`n") + "`n"), $utf8)

# --- pre-merge-commit (block merge commit; guide to rebase) ---
$preMergeCommitBatUnix = ([System.IO.Path]::GetFullPath($preMergeCommitBat)) -replace "\\", "/"
$preMergeCommitLines = @(
    "#!/bin/sh"
    "# Auto-generated by Install-GitHook - do not edit"
    ("# ugit-version: {0}" -f $version)
    ('cmd.exe //c "{0}"' -f $preMergeCommitBatUnix)
    'exit $?'
)
[System.IO.File]::WriteAllText($preMergeCommitDst, (($preMergeCommitLines -join "`n") + "`n"), $utf8)

# --- prepare-commit-msg (prefix 配置表提交 after confirm) ---
$prepareCommitMsgBatUnix = ([System.IO.Path]::GetFullPath($prepareCommitMsgBat)) -replace "\\", "/"
$prepareCommitMsgLines = @(
    "#!/bin/sh"
    "# Auto-generated by Install-GitHook - do not edit"
    ("# ugit-version: {0}" -f $version)
    ('cmd.exe //c "{0}" "$1"' -f $prepareCommitMsgBatUnix)
    'exit $?'
)
[System.IO.File]::WriteAllText($prepareCommitMsgDst, (($prepareCommitMsgLines -join "`n") + "`n"), $utf8)

[System.IO.File]::WriteAllText($versionDst, ($version + "`n"), $utf8)

$realGitPath = Resolve-RealGitPath
[System.IO.File]::WriteAllText($realGitMarker, ($realGitPath + "`n"), $utf8)
Write-Host "real git: $realGitPath"
Write-Host "git wrapper: $gitWrapperCmd"

Update-VscodeSettings $RepoRoot
Write-Host "vscode git.path -> scripts/ugit/UGit-Git.cmd"

Push-Location -LiteralPath $RepoRoot
try {
    $currentInclude = ""
    $includeGet = Invoke-GitLocal @("config", "--local", "--get", "include.path")
    if ($includeGet.Code -eq 0) {
        $currentInclude = (($includeGet.Output -split "[\r\n]+") | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
        if ($null -ne $currentInclude) { $currentInclude = $currentInclude.Trim() }
    }
    if ($currentInclude -ne $includePath) {
        $setInclude = Invoke-GitLocal @("config", "--local", "include.path", $includePath)
        if ($setInclude.Code -ne 0) {
            throw ("failed to set include.path: " + $setInclude.Output)
        }
    }

    $legacyAliasKeys = @("alias.checkout", "alias.switch", "alias.co", "alias.sw")
    foreach ($key in $legacyAliasKeys) {
        $unset = Invoke-GitLocal @("config", "--local", "--unset-all", $key)
        if ($unset.Code -eq 0) {
            Write-Host "removed legacy: $key"
        }
    }

    $safeSyncPs1Win = ([System.IO.Path]::GetFullPath($safeSyncPs1)) -replace "\\", "/"
    $aliasSafeSync = ('!powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $safeSyncPs1Win)
    $setAlias = Invoke-GitLocal @("config", "--local", "alias.ugit-sync", $aliasSafeSync)
    if ($setAlias.Code -ne 0) {
        throw ("failed to set alias.ugit-sync: " + $setAlias.Output)
    }
} finally {
    Pop-Location
}

Write-Host "installed: $preCommitDst"
Write-Host "installed: $prePushDst"
Write-Host "installed: $preMergeCommitDst"
Write-Host "ugit-version: $version ($versionDst)"
Write-Host "include.path: $includePath -> $repoGitConfig"
Write-Host "UGit pre-commit: $preCommitBat"
Write-Host "UGit prepare-commit-msg: $prepareCommitMsgBat"
Write-Host "UGit pre-push: $prePushBat"
Write-Host "UGit pre-merge-commit: $preMergeCommitBat"
Write-Host "UGit safe-sync alias (git ugit-sync): $safeSyncPs1"
Write-Host "UGit git.path wrapper: $gitWrapperCmd"

Push-Location -LiteralPath $RepoRoot
try {
    Write-Host "--- git pull/rebase config (show-origin) ---"
    $keys = @("pull.rebase", "rebase.autoStash")
    foreach ($key in $keys) {
        $show = Invoke-GitLocal @("config", "--show-origin", "--get", $key)
        if ($show.Code -eq 0) {
            Write-Host $show.Output
        } else {
            Write-Warning ("missing effective config: " + $key)
        }
    }
} finally {
    Pop-Location
}

if (-not $NoPause) {
    # keep double-click friendly when launched from .bat without -NoPause
}
