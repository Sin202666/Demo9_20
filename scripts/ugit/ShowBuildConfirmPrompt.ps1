#Requires -Version 5.1
<#
.SYNOPSIS
  Confirm whether to run config table-build when workspace config Excel changed.
.DESCRIPTION
  -DetectOnly (no UI):
    Exit 0: no config xlsx changes (skip prompt)
    Exit 3: has staged / unstaged / untracked config xlsx (show prompt)
    Any other non-zero: detect failed
  Dialog (no -DetectOnly):
    Exit 0: 打表并提交, staged only (caller: isolate+build+git add luau)
    Exit 5: git-add extras, then 打表并提交 (caller: disk build+git add luau)
    Exit 10: 不打表并提交 — full-disk validate, do not git add luau
    Exit 20: cancel
  不打表 never git-adds extras (checkbox ignored).
  -RunStagedBuild: full-disk BuildConfig; -ValidateOnly skips copy to src and restores luau from index.
    Without -ValidateOnly: second BuildConfig copies luau to src (no isolate).
  CI / UGIT_SKIP_BUILD_CONFIRM: add extras, exit 5 (full 打表).
#>
param(
    [string]$RepoRoot = "",
    [switch]$DetectOnly,
    [switch]$RunStagedBuild,
    [switch]$ValidateOnly,
    [switch]$IsolateOnly,
    [switch]$RestoreOnly
)

$ErrorActionPreference = "Continue"

function Decode-Utf8B64([string]$Text) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Invoke-Git([string[]]$GitCmdArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & git @GitCmdArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return @{
        Code = $code
        Output = [string]::Join([Environment]::NewLine, @($output))
    }
}

function Invoke-GitWithIndex {
    param(
        [string]$IndexPath,
        [string[]]$GitCmdArgs
    )
    $prev = [Environment]::GetEnvironmentVariable("GIT_INDEX_FILE")
    try {
        if ($IndexPath) {
            $env:GIT_INDEX_FILE = $IndexPath
        }
        return Invoke-Git $GitCmdArgs
    } finally {
        if ($null -eq $prev -or $prev -eq "") {
            Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        } else {
            $env:GIT_INDEX_FILE = $prev
        }
    }
}

function Get-DefaultGitIndexPath {
    $r = Invoke-Git @("rev-parse", "--absolute-git-dir")
    if ($r.Code -ne 0) { return "" }
    $gd = (($r.Output -split "[\r\n]+") | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if (-not $gd) { return "" }
    return [System.IO.Path]::GetFullPath((Join-Path $gd.Trim() "index"))
}

function Protect-StagedOnlyCommitIndex {
    $orig = Get-DefaultGitIndexPath
    if (-not $orig -or -not (Test-Path -LiteralPath $orig)) { return $true }

    $rOrig = Invoke-GitWithIndex $orig @(
        "-c", "core.quotepath=false",
        "diff", "--cached", "--name-only", "--", "config"
    )
    $origSet = @{}
    if ($rOrig.Code -eq 0) {
        foreach ($line in ($rOrig.Output -split "[\r\n]+")) {
            $p = Unquote-GitPath $line
            if (Test-IsConfigXlsx $p) { $origSet[$p] = $true }
        }
    }

    $rCur = Invoke-Git @(
        "-c", "core.quotepath=false",
        "diff", "--cached", "--name-only", "--", "config"
    )
    $curCached = @()
    if ($rCur.Code -eq 0) {
        foreach ($line in ($rCur.Output -split "[\r\n]+")) {
            $p = Unquote-GitPath $line
            if (Test-IsConfigXlsx $p) { $curCached += $p }
        }
    }

    foreach ($p in $curCached) {
        if ($origSet.ContainsKey($p)) {
            $ls = Invoke-GitWithIndex $orig @(
                "-c", "core.quotepath=false",
                "ls-files", "-s", "--", $p
            )
            $line = (($ls.Output -split "[\r\n]+") | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
            if ($ls.Code -eq 0 -and $line -match '^(?<mode>\d+) (?<sha>[0-9a-f]+) \d+\t(?<path>.*)$') {
                $up = Invoke-Git @(
                    "update-index", "--cacheinfo",
                    $Matches["mode"], $Matches["sha"], $p
                )
                if ($up.Code -ne 0) { return $false }
            }
        } else {
            $rm = Invoke-Git @("rm", "--cached", "-f", "--ignore-unmatch", "--", $p)
            if ($rm.Code -ne 0) { return $false }
        }
    }

    $statusWork = Invoke-GitWithIndex $orig @(
        "-c", "core.quotepath=false",
        "status", "--porcelain=v1", "-u", "--untracked-files=all", "--", "config"
    )
    if ($statusWork.Code -ne 0) { return $true }
    foreach ($line in ($statusWork.Output -split "[\r\n]+")) {
        if ($line -notmatch '^(?<xy>..) (?<rest>.*)$') { continue }
        $xy = $Matches["xy"]
        $rest = $Matches["rest"]
        $x = $xy[0]
        $y = $xy[1]
        $path = Unquote-GitPath $rest
        $arrow = " -> "
        $idx = $rest.IndexOf($arrow)
        if ($idx -ge 0) { $path = Unquote-GitPath $rest.Substring($idx + $arrow.Length) }
        if (-not (Test-IsConfigXlsx $path)) { continue }
        $onlyWorktree = ($x -eq ' ' -or $x -eq '?') -and ($y -ne ' ')
        if ($onlyWorktree -or ($x -eq '?' -and $y -eq '?')) {
            [void](Invoke-Git @("rm", "--cached", "-f", "--ignore-unmatch", "--", $path))
        }
    }
    return $true
}

function Unquote-GitPath([string]$Raw) {
    $t = [string]$Raw
    if ([string]::IsNullOrWhiteSpace($t)) { return "" }
    $t = $t.Trim()
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) {
        $inner = $t.Substring(1, $t.Length - 2)
        $inner = $inner.Replace('\"', '"').Replace('\\', '\')
        $t = $inner
    }
    return $t.Replace('\', '/')
}

function Test-IsConfigXlsx([string]$PathNorm) {
    if (-not $PathNorm) { return $false }
    return [bool]($PathNorm -match '(?i)^config/.+\.xlsx$')
}

function Add-UniquePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [hashtable]$Seen,
        [string]$PathNorm
    )
    if (-not (Test-IsConfigXlsx $PathNorm)) { return }
    if ($Seen.ContainsKey($PathNorm)) { return }
    $Seen[$PathNorm] = $true
    [void]$List.Add($PathNorm)
}

function Add-UnstagedItem {
    param(
        [System.Collections.Generic.List[string]]$Items,
        [System.Collections.Generic.List[string]]$Paths,
        [hashtable]$Seen,
        [string]$PathNorm,
        [string]$Kind
    )
    if (-not (Test-IsConfigXlsx $PathNorm)) { return }
    if ($Seen.ContainsKey($PathNorm)) { return }
    $Seen[$PathNorm] = $true
    [void]$Paths.Add($PathNorm)
    [void]$Items.Add(($Kind + "`t" + $PathNorm))
}

function Get-ConfigXlsxStatus {
    $staged = New-Object System.Collections.Generic.List[string]
    $unstaged = New-Object System.Collections.Generic.List[string]
    $unstagedItems = New-Object System.Collections.Generic.List[string]
    $seenS = @{}
    $seenU = @{}

    $r = Invoke-Git @(
        "-c", "core.quotepath=false",
        "status", "--porcelain=v1", "-u", "--untracked-files=all", "--", "config"
    )
    if ($r.Code -ne 0) { return $null }

    foreach ($line in ($r.Output -split "[\r\n]+")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -lt 3) { continue }
        if ($line -notmatch '^(?<xy>..) (?<rest>.*)$') { continue }

        $xy = $Matches["xy"]
        $rest = $Matches["rest"]
        $x = $xy[0]
        $y = $xy[1]

        $oldPath = $null
        $newPath = $rest
        $arrow = " -> "
        $idx = $rest.IndexOf($arrow)
        if ($idx -ge 0) {
            $oldPath = Unquote-GitPath $rest.Substring(0, $idx)
            $newPath = Unquote-GitPath $rest.Substring($idx + $arrow.Length)
        } else {
            $newPath = Unquote-GitPath $rest
        }

        if ($x -eq '!') { continue }

        if ($x -eq '?' -and $y -eq '?') {
            Add-UnstagedItem $unstagedItems $unstaged $seenU $newPath "untracked"
            continue
        }

        if ($x -ne ' ') {
            if ($oldPath) { Add-UniquePath $staged $seenS $oldPath }
            Add-UniquePath $staged $seenS $newPath
        }
        if ($y -ne ' ' -and $y -ne '?') {
            $kind = "modified"
            if ($y -eq 'D') { $kind = "deleted" }
            if ($oldPath) { Add-UnstagedItem $unstagedItems $unstaged $seenU $oldPath $kind }
            Add-UnstagedItem $unstagedItems $unstaged $seenU $newPath $kind
        }
    }

    return @{
        Staged = $staged.ToArray()
        Unstaged = $unstaged.ToArray()
        UnstagedItems = $unstagedItems.ToArray()
    }
}

function Get-IsolateDir {
    return (Join-Path $PSScriptRoot "precommit-last-isolate")
}

function Restore-IsolatedXlsx {
    $isoDir = Get-IsolateDir
    $manifest = Join-Path $isoDir "manifest.txt"
    $filesRoot = Join-Path $isoDir "files"
    if (-not (Test-Path -LiteralPath $manifest)) {
        if (Test-Path -LiteralPath $isoDir) {
            Remove-Item -LiteralPath $isoDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $true
    }
    $ok = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $lines = [System.IO.File]::ReadAllLines($manifest, $utf8)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $tab = $line.IndexOf("`t")
        if ($tab -lt 1) { continue }
        $kind = $line.Substring(0, $tab)
        $rel = $line.Substring($tab + 1).Replace('\', '/')
        $abs = Join-Path $script:RepoRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $bak = Join-Path $filesRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        try {
            if ($kind -eq "deleted") {
                if (Test-Path -LiteralPath $abs) {
                    Remove-Item -LiteralPath $abs -Force
                }
            } elseif (Test-Path -LiteralPath $bak) {
                $parent = Split-Path $abs -Parent
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                Copy-Item -LiteralPath $bak -Destination $abs -Force
            } else {
                $ok = $false
            }
        } catch {
            $ok = $false
        }
    }
    Remove-Item -LiteralPath $isoDir -Recurse -Force -ErrorAction SilentlyContinue
    return $ok
}

function Isolate-UnstagedXlsx {
    [void](Restore-IsolatedXlsx)
    $status = Get-ConfigXlsxStatus
    if ($null -eq $status) { return $false }
    $items = @($status.UnstagedItems)
    if ($items.Count -eq 0) { return $true }

    $isoDir = Get-IsolateDir
    $filesRoot = Join-Path $isoDir "files"
    $manifest = Join-Path $isoDir "manifest.txt"
    New-Item -ItemType Directory -Path $filesRoot -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $manLines = New-Object System.Collections.Generic.List[string]

    foreach ($item in $items) {
        $raw = [string]$item
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $tab = $raw.IndexOf("`t")
        if ($tab -lt 1) { continue }
        $kind = $raw.Substring(0, $tab)
        $rel = $raw.Substring($tab + 1).Replace('\', '/')
        if (-not $rel) { continue }
        $abs = Join-Path $script:RepoRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $bak = Join-Path $filesRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $bakParent = Split-Path $bak -Parent
        if (-not (Test-Path -LiteralPath $bakParent)) {
            New-Item -ItemType Directory -Path $bakParent -Force | Out-Null
        }

        if ($kind -eq "untracked") {
            if (-not (Test-Path -LiteralPath $abs)) { continue }
            Copy-Item -LiteralPath $abs -Destination $bak -Force
            Remove-Item -LiteralPath $abs -Force
            [void]$manLines.Add("untracked`t$rel")
            [System.IO.File]::WriteAllLines($manifest, $manLines.ToArray(), $utf8)
            continue
        }

        if ($kind -eq "deleted") {
            $co = Invoke-Git @("checkout-index", "-f", "--", $rel)
            if ($co.Code -ne 0) {
                [void](Restore-IsolatedXlsx)
                return $false
            }
            [void]$manLines.Add("deleted`t$rel")
            [System.IO.File]::WriteAllLines($manifest, $manLines.ToArray(), $utf8)
            continue
        }

        if (Test-Path -LiteralPath $abs) {
            Copy-Item -LiteralPath $abs -Destination $bak -Force
        }
        $co = Invoke-Git @("checkout-index", "-f", "--", $rel)
        if ($co.Code -ne 0) {
            [void](Restore-IsolatedXlsx)
            return $false
        }
        [void]$manLines.Add("modified`t$rel")
        [System.IO.File]::WriteAllLines($manifest, $manLines.ToArray(), $utf8)
    }

    return $true
}

function Write-BuildAbortError([string]$Message) {
    $errPath = Join-Path $PSScriptRoot "precommit-last-error.txt"
    $kindPath = Join-Path $PSScriptRoot "precommit-last-error.kind"
    $utf8bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($errPath, ($Message.Trim() + "`r`n"), $utf8bom)
    [System.IO.File]::WriteAllText($kindPath, "StagedWorktreeMismatch`r`n", [System.Text.Encoding]::ASCII)
}

function Get-ExtraMismatchMessage {
    return (Decode-Utf8B64 "6YWN572u5omT6KGo5bey5Lit5q2i44CCCgrljp/lm6A6IOW3peS9nOWMuuS7jeacieacquaaguWtmOeahOmFjee9ruihqO+8jOacquWLvumAieaJk+ihqOaXoOazleS/neivgeagoemqjOeahOWwseaYr+WNs+WwhuaPkOS6pOeahOmCo+S7veOAggoK6K+35Yu+6YCJ44CM5oqK5pqC5a2Y5Yy65aSW55qE6YWN572u5Y+Y5YyW5Yqg5YWl5pqC5a2Y77yM5bm25LiA6LW35omT6KGo5LiK5Lyg44CN5ZCO6YeN6K+V77yb5p+Q5byg6KGo5LiN5oOz5o+Q5Lqk6K+35YWI6L+Y5Y6f5oiWIHN0YXNo44CC")
}

function Get-MmMismatchMessage {
    return (Decode-Utf8B64 "6YWN572u5omT6KGo5bey5Lit5q2i44CCCgrljp/lm6A6IOWQjOS4gOmFjee9ruihqOeahOaaguWtmOWMuuS4juW3peS9nOWMuuWGheWuueS4jeS4gOiHtO+8jOaXoOazleS/neivgeagoemqjOeahOWwseaYr+WNs+WwhuaPkOS6pOeahOmCo+S7veOAggoK6K+35YWIIGdpdCBhZGTjgIHov5jljp/lt6XkvZzljLrvvIzmiJbli77pgInlkI7ngrnjgIzmiZPooajlubbmj5DkuqTjgI3jgII=")
}

function Test-HasStagedWorktreeMismatch {
    $status = Get-ConfigXlsxStatus
    if ($null -eq $status) { return $true }
    $seen = @{}
    foreach ($p in @($status.Staged)) {
        if ($p) { $seen[$p] = $true }
    }
    foreach ($p in @($status.Unstaged)) {
        if ($p -and $seen.ContainsKey($p)) { return $true }
    }
    return $false
}

function Test-HasExtraConfigXlsx {
    $status = Get-ConfigXlsxStatus
    if ($null -eq $status) { return $true }
    return (@($status.Unstaged).Count -gt 0)
}

function Restore-SrcLuauFromIndex {
    $files = @(
        "src/ReplicatedFirst/AllSideCode/ToolBasic/ConfigInstance.luau",
        "src/ReplicatedFirst/AllSideCode/ToolBasic/TranslationHelper/Language.luau"
    )
    $r = Invoke-Git (@("checkout", "--") + $files)
    return ($r.Code -eq 0)
}

function Invoke-BuildConfig {
    param([switch]$NoCopy)
    $buildPs1 = Join-Path $PSScriptRoot "BuildConfig.ps1"
    $invokeArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $buildPs1,
        "-RepoRoot", ([string]$script:RepoRoot),
        "-Mode", "Framework"
    )
    if ($NoCopy) { $invokeArgs += "-NoCopyToSrc" }

    $prevNoCopy = [Environment]::GetEnvironmentVariable("UGIT_NO_COPY_TO_SRC", "Process")
    if ($NoCopy) {
        $env:UGIT_NO_COPY_TO_SRC = "1"
    } else {
        Remove-Item Env:UGIT_NO_COPY_TO_SRC -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable("UGIT_NO_COPY_TO_SRC", $null, "Process")
    }
    $output = $null
    try {
        # Capture child stdout. `& powershell.exe` otherwise mixes log lines into this
        # function's return value; `$ec -ne 0` then skips the second copy and luau is never written.
        $output = & powershell.exe @invokeArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        if ($null -eq $prevNoCopy -or $prevNoCopy -eq "") {
            Remove-Item Env:UGIT_NO_COPY_TO_SRC -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable("UGIT_NO_COPY_TO_SRC", $null, "Process")
        } else {
            $env:UGIT_NO_COPY_TO_SRC = $prevNoCopy
        }
    }
    if ($null -eq $code) { $code = 1 }
    foreach ($line in @($output)) {
        Write-Host ([string]$line)
    }
    $errPath = Join-Path $PSScriptRoot "precommit-last-error.txt"
    if (Test-Path -LiteralPath $errPath) { return 1 }
    return [int]$code
}

function Invoke-StagedOnlyBuild {
    $ec = Invoke-BuildConfig -NoCopy
    if ($null -eq $ec -or $ec -ne 0) {
        if ($null -eq $ec -or $ec -eq 0) { return 1 }
        return $ec
    }

    if (-not (Protect-StagedOnlyCommitIndex)) { return 1 }
    if ([bool]$script:ValidateOnly) {
        [void](Restore-SrcLuauFromIndex)
        return 0
    }

    # 打表: copy src from current disk (same tables as validate). Do not isolate —
    # isolate rebuilt luau from index and skipped uploading Code.xlsx changes.
    $ec = Invoke-BuildConfig
    if ($null -eq $ec -or $ec -ne 0) {
        if ($null -eq $ec -or $ec -eq 0) { return 1 }
        return $ec
    }
    return 0
}

function Add-UnstagedConfigXlsx {
    foreach ($p in @($script:unstaged)) {
        if (-not $p) { continue }
        $add = Invoke-Git @("add", "--", $p)
        if ($add.Code -ne 0) { return $false }
    }
    return $true
}

function Add-FileListSection {
    param(
        [System.Collections.Generic.List[string]]$Parts,
        [string]$Label,
        [string[]]$Items,
        [string]$NoneText,
        [int]$MaxShow
    )
    [void]$Parts.Add($Label)
    $arr = @($Items)
    if ($arr.Count -eq 0) {
        [void]$Parts.Add("  " + $NoneText)
        return
    }
    $n = [Math]::Min($MaxShow, $arr.Count)
    for ($i = 0; $i -lt $n; $i++) {
        [void]$Parts.Add("  " + $arr[$i])
    }
    if ($arr.Count -gt $MaxShow) {
        [void]$Parts.Add(("  ... +" + ($arr.Count - $MaxShow)))
    }
}

if (-not $RepoRoot) {
    $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}
$script:RepoRoot = (($RepoRoot -split "[\r\n]+")[0]).Trim()

if (-not $script:RepoRoot -or -not (Test-Path -LiteralPath $script:RepoRoot)) {
    if ($DetectOnly) { exit 2 }
    exit 1
}

Push-Location -LiteralPath $script:RepoRoot
$script:ValidateOnly = $false
$script:staged = @()
$script:unstaged = @()
$script:confirmResult = $null
$script:doStageExtra = $false
$script:formsLoaded = $false

try {
    if ($RestoreOnly) {
        if (Restore-IsolatedXlsx) { exit 0 } else { exit 1 }
    }
    if ($IsolateOnly) {
        if (Isolate-UnstagedXlsx) { exit 0 } else { exit 1 }
    }
    if ($RunStagedBuild) {
        $script:ValidateOnly = [bool]$ValidateOnly
        $ec = Invoke-StagedOnlyBuild
        if ($null -eq $ec -or $ec -ne 0) {
            if ($null -eq $ec -or $ec -eq 0) { exit 1 }
            exit $ec
        }
        exit 0
    }

    $status = Get-ConfigXlsxStatus
    if ($null -eq $status) {
        if ($DetectOnly) { exit 2 }
        exit 1
    }

    $script:staged = @($status.Staged)
    $script:unstaged = @($status.Unstaged)
    $hasAny = (($script:staged.Count + $script:unstaged.Count) -gt 0)

    if ($DetectOnly) {
        if ($hasAny) { exit 3 } else { exit 0 }
    }

    if (-not $hasAny) { exit 20 }

    if (($env:UGIT_SKIP_BUILD_CONFIRM -eq "1") -or ($env:CI -eq "true")) {
        if (-not (Add-UnstagedConfigXlsx)) { exit 1 }
        exit 5
    }

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:formsLoaded = $true

    $title = Decode-Utf8B64 "5omT6KGo56Gu6K6k"
    $headerSub = Decode-Utf8B64 "5qOA5rWL5Yiw6YWN572u6KGo5Y+Y5pu077yM6K+35LqM5qyh56Gu6K6k"
    $lineIntro = Decode-Utf8B64 "5bel5L2c5Yy677yI5ZCr5pyq5pqC5a2Y77yJ5a2Y5ZyoIGNvbmZpZyBFeGNlbCDlj5jljJbvvIzor7fkuozmrKHnoa7orqTjgII="
    $lineBuild = Decode-Utf8B64 "5omT6KGo5bm25o+Q5Lqk77ya5qCh6aqM6YCa6L+H5ZCO55Sf5oiQ5bm25pqC5a2YIExhbmd1YWdlLmx1YXUgLyBDb25maWdJbnN0YW5jZS5sdWF177yI5Lya5o+Q5Lqk5LiK5Lyg77yJ44CC"
    $lineSkip = Decode-Utf8B64 "5LiN5omT6KGo5bm25o+Q5Lqk77ya5LuN5a+55bel5L2c5Yy65YWo6YOo6YWN572u6KGo5YGa5omT6KGo5qCh6aqM77yI5ZCr5pys5qyh5LiN5o+Q5Lqk55qE5Yy65aSW6KGo77yJ77yM6YCa6L+H5ZCO5omN5YWB6K645o+Q5Lqk77yb5L2G5LiN5oqKIGx1YXUg5Lqn54mp5Yqg5YWl5pys5qyh5o+Q5Lqk77yI5Yu+6YCJ5Lmf5LiN5Lya5Yqg5YWl5Yy65aSW6KGo77yJ44CC"
    $lineClose = Decode-Utf8B64 "5YWz6Zet56qX5Y+j5bCG5Y+W5raI5pys5qyh5o+Q5Lqk44CC"
    $lineWarn = Decode-Utf8B64 "5rOo5oSP77ya6YWN572u6KGo5pyJ6ZSZ5Lya5by55aSx6LSl56qX5bm25Lit5q2i5o+Q5Lqk77yM5LiN5Lya5Y+q5LiK5Lyg5LiN5ZCI5qC8IEV4Y2Vs44CC5Lik56eN5o+Q5Lqk6YO95Lya5oyJ5bel5L2c5Yy65YWo6YOo6YWN572u6KGo5qCh6aqM77yI5ZCr5pys5qyh5LiN5o+Q5Lqk55qE5Yy65aSW6KGo77yJ44CC5pyq5Yu+6YCJ5LiN5Lya5oqK5Yy65aSW6KGo5Yqg5YWl5o+Q5Lqk44CC5Yu+6YCJ5omN5Lya5oqK5Yy65aSW6KGo5Yqg5YWl5bm25omT6KGo5LiK5Lyg44CC"
    $lineNeedCheck = Decode-Utf8B64 "5b2T5YmN5pqC5a2Y5Yy65rKh5pyJ6YWN572u6KGo5pe277yM44CM5omT6KGo5bm25o+Q5Lqk44CN6ZyA5YWI5Yu+6YCJ5LiL5pa56YCJ6aG544CC"
    $lineNeedCheckExtra = Decode-Utf8B64 "5pyJ5Yy65aSW6KGo5pe277ya44CM5omT6KGo5bm25o+Q5Lqk44CN6aG75YWI5Yu+6YCJ44CC5ZCM5LiA5paH5Lu25pqC5a2Y5LiO5bel5L2c5Yy65LiN5LiA6Ie05pe277yM5LiN6IO944CM5LiN5omT6KGo5bm25o+Q5Lqk44CN44CC"
    $btnBuildText = Decode-Utf8B64 "5omT6KGo5bm25o+Q5Lqk"
    $btnSkipText = Decode-Utf8B64 "5LiN5omT6KGo5bm25o+Q5Lqk"
    $lblStaged = Decode-Utf8B64 "5bey5pqC5a2Y55qE6YWN572u6KGo77ya"
    $lblNone = Decode-Utf8B64 "77yI5peg77yJ"
    $chkText = Decode-Utf8B64 "5bCG5pqC5a2Y5Yy65aSW55qE6YWN572u5Y+Y5YyW5Yqg5YWl5pqC5a2Y77yM5bm25LiA6LW35omT6KGo5LiK5Lyg"
    $lblExtraEmpty = Decode-Utf8B64 "5pqC5a2Y5Yy65aSW5rKh5pyJ6YWN572u6KGo77yM5q2k6aG55LiN5Y+v55So44CC"
    $lblExtraHead = Decode-Utf8B64 "5bCG5Yqg5YWl5pqC5a2Y77ya"

    $bodyParts = New-Object System.Collections.Generic.List[string]
    [void]$bodyParts.Add($lineIntro)
    [void]$bodyParts.Add("")
    [void]$bodyParts.Add($lineBuild)
    [void]$bodyParts.Add($lineSkip)
    [void]$bodyParts.Add("")
    [void]$bodyParts.Add($lineWarn)
    [void]$bodyParts.Add($lineClose)
    if ($script:unstaged.Count -gt 0) {
        [void]$bodyParts.Add("")
        [void]$bodyParts.Add($lineNeedCheckExtra)
    } elseif ($script:staged.Count -eq 0) {
        [void]$bodyParts.Add("")
        [void]$bodyParts.Add($lineNeedCheck)
    }
    [void]$bodyParts.Add("")
    Add-FileListSection $bodyParts $lblStaged $script:staged $lblNone 8
    $bodyText = [string]::Join("`r`n", $bodyParts.ToArray())

    $extraParts = New-Object System.Collections.Generic.List[string]
    $extraArr = @($script:unstaged)
    if ($extraArr.Count -eq 0) {
        [void]$extraParts.Add($lblExtraEmpty)
    } else {
        [void]$extraParts.Add($lblExtraHead)
        $maxExtra = 6
        $nExtra = [Math]::Min($maxExtra, $extraArr.Count)
        for ($i = 0; $i -lt $nExtra; $i++) {
            [void]$extraParts.Add("  " + $extraArr[$i])
        }
        if ($extraArr.Count -gt $maxExtra) {
            [void]$extraParts.Add(("  ... +" + ($extraArr.Count - $maxExtra)))
        }
    }
    $extraText = [string]::Join("`r`n", $extraParts.ToArray())

    $cPage = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $cHeader = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $cAccent = [System.Drawing.Color]::FromArgb(217, 119, 6)
    $cInk = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $cBorder = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $cCard = [System.Drawing.Color]::White

    $fontUi = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
    $fontTitle = New-Object System.Drawing.Font("Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold)
    $fontSub = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $fontBody = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
    $fontPrimary = New-Object System.Drawing.Font("Microsoft YaHei UI", 10.5, [System.Drawing.FontStyle]::Bold)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $title
    $form.StartPosition = "CenterScreen"
    $form.ClientSize = New-Object System.Drawing.Size(580, 580)
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.Font = $fontUi
    $form.BackColor = $cPage
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.KeyPreview = $true

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Dock = "Left"
    $accent.Width = 6
    $accent.BackColor = $cAccent

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = "Top"
    $header.Height = 72
    $header.BackColor = $cHeader

    $iconBox = New-Object System.Windows.Forms.PictureBox
    $iconBox.Size = New-Object System.Drawing.Size(32, 32)
    $iconBox.Location = New-Object System.Drawing.Point(20, 20)
    $iconBox.SizeMode = "StretchImage"
    $iconBox.Image = [System.Drawing.SystemIcons]::Warning.ToBitmap()
    $header.Controls.Add($iconBox)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Location = New-Object System.Drawing.Point(64, 14)
    $titleLabel.Size = New-Object System.Drawing.Size(480, 28)
    $titleLabel.Font = $fontTitle
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $titleLabel.Text = $title
    $titleLabel.BackColor = $cHeader
    $header.Controls.Add($titleLabel)

    $subLabel = New-Object System.Windows.Forms.Label
    $subLabel.Location = New-Object System.Drawing.Point(64, 42)
    $subLabel.Size = New-Object System.Drawing.Size(480, 22)
    $subLabel.Font = $fontSub
    $subLabel.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $subLabel.Text = $headerSub
    $subLabel.BackColor = $cHeader
    $header.Controls.Add($subLabel)

    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = "Bottom"
    $footer.Height = 72
    $footer.BackColor = $cPage

    $btnSkip = New-Object System.Windows.Forms.Button
    $btnSkip.Text = $btnSkipText
    $btnSkip.Size = New-Object System.Drawing.Size(168, 38)
    $btnSkip.Location = New-Object System.Drawing.Point(24, 16)
    $btnSkip.FlatStyle = "Flat"
    $btnSkip.BackColor = $cCard
    $btnSkip.ForeColor = $cInk
    $btnSkip.FlatAppearance.BorderColor = $cBorder
    $btnSkip.DialogResult = [System.Windows.Forms.DialogResult]::No
    $footer.Controls.Add($btnSkip)

    $btnBuild = New-Object System.Windows.Forms.Button
    $btnBuild.Text = $btnBuildText
    $btnBuild.Size = New-Object System.Drawing.Size(152, 38)
    $btnBuild.Location = New-Object System.Drawing.Point(400, 16)
    $btnBuild.FlatStyle = "Flat"
    $btnBuild.Font = $fontPrimary
    $btnBuild.BackColor = $cAccent
    $btnBuild.ForeColor = [System.Drawing.Color]::White
    $btnBuild.FlatAppearance.BorderSize = 0
    $btnBuild.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $footer.Controls.Add($btnBuild)

    $optPanel = New-Object System.Windows.Forms.Panel
    $optPanel.Dock = "Bottom"
    $optPanel.Height = 118
    $optPanel.BackColor = $cPage

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = $chkText
    $chk.Font = $fontSub
    $chk.ForeColor = $cInk
    $chk.Location = New-Object System.Drawing.Point(24, 8)
    $chk.Size = New-Object System.Drawing.Size(532, 28)
    $chk.Checked = $false
    $chk.Enabled = ($script:unstaged.Count -gt 0)
    $optPanel.Controls.Add($chk)

    $extraList = New-Object System.Windows.Forms.TextBox
    $extraList.Location = New-Object System.Drawing.Point(48, 38)
    $extraList.Size = New-Object System.Drawing.Size(508, 70)
    $extraList.Font = $fontSub
    $extraList.ForeColor = $cInk
    $extraList.BackColor = $cCard
    $extraList.BorderStyle = "FixedSingle"
    $extraList.Multiline = $true
    $extraList.ReadOnly = $true
    $extraList.ScrollBars = "Vertical"
    $extraList.Text = $extraText
    $extraList.TabStop = $false
    $optPanel.Controls.Add($extraList)

    $hostPanel = New-Object System.Windows.Forms.Panel
    $hostPanel.Dock = "Fill"
    $hostPanel.Padding = New-Object System.Windows.Forms.Padding(24, 12, 24, 8)
    $hostPanel.BackColor = $cPage

    $body = New-Object System.Windows.Forms.TextBox
    $body.Dock = "Fill"
    $body.Font = $fontBody
    $body.ForeColor = $cInk
    $body.BackColor = $cCard
    $body.BorderStyle = "FixedSingle"
    $body.Multiline = $true
    $body.ReadOnly = $true
    $body.ScrollBars = "Vertical"
    $body.Text = $bodyText
    $body.TabStop = $false

    $hostPanel.Controls.Add($body)

    $form.Controls.Add($hostPanel)
    $form.Controls.Add($optPanel)
    $form.Controls.Add($footer)
    $form.Controls.Add($header)
    $form.Controls.Add($accent)

    $script:chk = $chk
    $script:btnBuild = $btnBuild
    $script:btnSkip = $btnSkip
    $script:formRef = $form
    $script:extraList = $extraList
    $script:cCard = $cCard
    $script:cInk = $cInk
    $script:cMuted = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $script:cExtraOn = [System.Drawing.Color]::FromArgb(255, 247, 237)
    $script:cExtraOnInk = [System.Drawing.Color]::FromArgb(154, 52, 18)
    $script:hasExtraFiles = ($script:unstaged.Count -gt 0)
    $script:UpdateBuildEnabled = {
        $hasStaged = ($script:staged.Count -gt 0)
        $wantExtra = ($script:chk.Enabled -and $script:chk.Checked)
        $script:btnBuild.Enabled = ($hasStaged -or $wantExtra)
        $script:btnSkip.Enabled = $true
        if ($script:btnBuild.Enabled) {
            $script:formRef.AcceptButton = $script:btnBuild
        } else {
            $script:formRef.AcceptButton = $null
        }
        if ($script:hasExtraFiles -and $script:chk.Checked) {
            $script:extraList.BackColor = $script:cExtraOn
            $script:extraList.ForeColor = $script:cExtraOnInk
        } elseif ($script:hasExtraFiles) {
            $script:extraList.BackColor = $script:cCard
            $script:extraList.ForeColor = $script:cInk
        } else {
            $script:extraList.BackColor = $script:cCard
            $script:extraList.ForeColor = $script:cMuted
        }
    }
    $chk.Add_CheckedChanged($script:UpdateBuildEnabled)
    & $script:UpdateBuildEnabled

    $form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        }
    })
    $form.Add_Shown({
        if ($script:btnBuild.Enabled) {
            $script:btnBuild.Focus() | Out-Null
        } else {
            $script:btnSkip.Focus() | Out-Null
        }
    })
    $form.Add_Resize({
        $btnBuild.Left = [Math]::Max(20, $footer.ClientSize.Width - $btnBuild.Width - 24)
    })
    $btnBuild.Left = [Math]::Max(20, $footer.ClientSize.Width - $btnBuild.Width - 24)

    try {
        $script:confirmResult = $form.ShowDialog()
        if ($script:confirmResult -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:doStageExtra = ($chk.Checked -eq $true) -and ($script:unstaged.Count -gt 0)
        }
    } finally {
        $form.Dispose()
    }
} finally {
    Pop-Location
}

if (-not $script:formsLoaded) {
    # DetectOnly / skip / CI already exited inside try.
    exit 1
}

if ($script:confirmResult -eq [System.Windows.Forms.DialogResult]::Yes) {
    if ($script:doStageExtra) {
        Push-Location -LiteralPath $script:RepoRoot
        try {
            if (-not (Add-UnstagedConfigXlsx)) { exit 1 }
        } finally {
            Pop-Location
        }
        exit 5
    }
    if ($script:staged.Count -eq 0) { exit 1 }
    exit 0
}
if ($script:confirmResult -eq [System.Windows.Forms.DialogResult]::No) {
    exit 10
}
exit 20
