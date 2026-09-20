#Requires -Version 5.1
<#
.SYNOPSIS
  git.path wrapper for Cursor/VS Code: popup when dirty tree blocks pull/checkout.
.DESCRIPTION
  Installed via .vscode/settings.json git.path by Install-GitHook.ps1.
  Terminal git (PATH) is unchanged; only IDE-invoked git uses this wrapper.

  Cursor Source Control (3.15.6+) injects -c core.hooksPath=/dev/null (and
  sometimes GIT_CONFIG_* env), which silently skips pre-commit / pre-push.
  This wrapper strips that disable so UGit pre-commit / pre-push hooks still run on IDE commit/push.
  Git argv is read from $args (no param block): powershell would otherwise bind git's -c as a switch.
#>
$ErrorActionPreference = "Continue"
$GitArgs = @($args)

function Decode-Utf8B64([string]$Text) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Get-RealGitPath {
    $marker = Join-Path $PSScriptRoot "ugit-real-git.txt"
    if (Test-Path -LiteralPath $marker) {
        $p = (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue)
        if ($p) {
            $p = $p.Trim()
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
    }
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch 'UGit-Git') { return $cmd.Source }
    return "git.exe"
}

function Invoke-RealGit {
    param(
        [string[]]$GitCmdArgs,
        [switch]$Quiet
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $lines = New-Object System.Collections.Generic.List[string]
    & $script:RealGit @GitCmdArgs 2>&1 | ForEach-Object {
        $t = "$_"
        [void]$lines.Add($t)
        if (-not $Quiet) {
            Write-Host $t
        }
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return @{
        Code = $code
        Output = [string]::Join([Environment]::NewLine, $lines.ToArray())
    }
}

function Get-RepoRoot {
    $r = Invoke-RealGit @("rev-parse", "--show-toplevel") -Quiet
    if ($r.Code -ne 0) { return "" }
    $line = (($r.Output -split "[\r\n]+") | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if (-not $line) { return "" }
    return $line.Trim()
}

function Test-IsDisabledHooksPathValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim().Trim("'").Trim('"')
    $n = ($v.ToLowerInvariant() -replace '\\', '/')
    if ($n -eq '/dev/null') { return $true }
    if ($n -eq 'nul' -or $n -eq 'nul:') { return $true }
    if ($n -eq '//./nul') { return $true }
    return $false
}

function Test-IsDisabledHooksPathAssignment {
    param([string]$Assignment)
    if ([string]::IsNullOrWhiteSpace($Assignment)) { return $false }
    $a = $Assignment.Trim().Trim("'").Trim('"')
    $eq = $a.IndexOf('=')
    if ($eq -lt 1) { return $false }
    $key = $a.Substring(0, $eq).Trim()
    $val = $a.Substring($eq + 1)
    if ($key -notmatch '^(?i)core\.hooksPath$') { return $false }
    return (Test-IsDisabledHooksPathValue $val)
}

function Remove-DisabledHooksPathFromGitConfigParameters {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $parts = [regex]::Matches($Text, "(?:'[^']*'|""[^""]*""|[^\s]+)")
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($m in $parts) {
        $tok = $m.Value
        $inner = $tok.Trim().Trim("'").Trim('"')
        if (Test-IsDisabledHooksPathAssignment $inner) { continue }
        [void]$kept.Add($tok)
    }
    return ($kept -join ' ')
}

function Clear-DisabledHooksPathFromProcessEnv {
    $params = [Environment]::GetEnvironmentVariable("GIT_CONFIG_PARAMETERS")
    if ($params) {
        $filtered = Remove-DisabledHooksPathFromGitConfigParameters $params
        if ([string]::IsNullOrWhiteSpace($filtered)) {
            Remove-Item Env:GIT_CONFIG_PARAMETERS -ErrorAction SilentlyContinue
        } elseif ($filtered -ne $params) {
            $env:GIT_CONFIG_PARAMETERS = $filtered
        }
    }

    $countRaw = [Environment]::GetEnvironmentVariable("GIT_CONFIG_COUNT")
    $count = 0
    if (-not [string]::IsNullOrWhiteSpace($countRaw)) {
        [void][int]::TryParse($countRaw, [ref]$count)
    }
    if ($count -le 0) { return }

    $kept = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $count; $i++) {
        $k = [Environment]::GetEnvironmentVariable("GIT_CONFIG_KEY_$i")
        $v = [Environment]::GetEnvironmentVariable("GIT_CONFIG_VALUE_$i")
        $assign = ""
        if ($null -ne $k) { $assign = ("{0}={1}" -f $k, $v) }
        if (Test-IsDisabledHooksPathAssignment $assign) { continue }
        [void]$kept.Add(@{ Key = $k; Value = $v })
    }
    if ($kept.Count -eq $count) { return }

    for ($i = 0; $i -lt $count; $i++) {
        Remove-Item "Env:GIT_CONFIG_KEY_$i" -ErrorAction SilentlyContinue
        Remove-Item "Env:GIT_CONFIG_VALUE_$i" -ErrorAction SilentlyContinue
    }
    if ($kept.Count -eq 0) {
        Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue
        return
    }
    $env:GIT_CONFIG_COUNT = [string]$kept.Count
    for ($i = 0; $i -lt $kept.Count; $i++) {
        Set-Item "Env:GIT_CONFIG_KEY_$i" -Value $kept[$i].Key
        Set-Item "Env:GIT_CONFIG_VALUE_$i" -Value $kept[$i].Value
    }
}

function Get-SanitizedGitInvocation {
    param([string[]]$RawGitArgs)
    $clean = New-Object System.Collections.Generic.List[string]
    $n = @($RawGitArgs).Count
    $i = 0
    $valueGlobals = @(
        '--git-dir', '--work-tree', '--namespace', '--super-prefix',
        '--config-env', '--exec-path', '--attr-source'
    )
    while ($i -lt $n) {
        $a = [string]$RawGitArgs[$i]
        if ($a -eq '--') {
            $i++
            break
        }
        if ($a -eq '-c') {
            if (($i + 1) -ge $n) {
                [void]$clean.Add($a)
                $i++
                break
            }
            $spec = [string]$RawGitArgs[$i + 1]
            if (-not (Test-IsDisabledHooksPathAssignment $spec)) {
                [void]$clean.Add('-c')
                [void]$clean.Add($spec)
            }
            $i += 2
            continue
        }
        if ($a.Length -gt 2 -and $a.StartsWith('-c') -and -not $a.StartsWith('--')) {
            $spec = $a.Substring(2)
            if (-not (Test-IsDisabledHooksPathAssignment $spec)) {
                [void]$clean.Add($a)
            }
            $i++
            continue
        }
        if ($a -eq '-C') {
            [void]$clean.Add($a)
            $i++
            if ($i -lt $n) {
                [void]$clean.Add([string]$RawGitArgs[$i])
                $i++
            }
            continue
        }
        if ($a.StartsWith('--') -and ($a.IndexOf('=') -gt 2)) {
            [void]$clean.Add($a)
            $i++
            continue
        }
        if ($valueGlobals -contains $a) {
            [void]$clean.Add($a)
            $i++
            if ($i -lt $n) {
                [void]$clean.Add([string]$RawGitArgs[$i])
                $i++
            }
            continue
        }
        if ($a.StartsWith('-') -and $a -ne '-') {
            [void]$clean.Add($a)
            $i++
            continue
        }
        break
    }

    $sub = ""
    $rest = @()
    if ($i -lt $n) {
        $sub = ([string]$RawGitArgs[$i]).ToLowerInvariant()
        if (($i + 1) -lt $n) {
            $rest = @($RawGitArgs[($i + 1)..($n - 1)])
        }
        while ($i -lt $n) {
            [void]$clean.Add([string]$RawGitArgs[$i])
            $i++
        }
    }

    return @{
        Args = $clean.ToArray()
        SubCommand = $sub
        Rest = $rest
    }
}

function Test-WorkingTreeDirty {
    $r = Invoke-RealGit @("status", "--porcelain") -Quiet
    if ($r.Code -ne 0) { return $false }
    return [bool]($r.Output.Trim())
}

function Test-IsDirtyTreeMessage([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $patterns = @(
        'working tree',
        'work tree',
        (Decode-Utf8B64 "5bel5L2c5qCR"),
        (Decode-Utf8B64 "5riF55CG"),
        'would be overwritten',
        'commit your changes',
        'local changes',
        'uncommitted',
        'checkout.*failed',
        'cannot pull'
    )
    foreach ($p in $patterns) {
        if ($Text -imatch $p) { return $true }
    }
    return $false
}

function Test-IsBranchSwitch([string]$SubCommand, [string[]]$Args) {
    if ($SubCommand -eq "switch") {
        if ($Args -contains "-h" -or $Args -contains "--help") { return $false }
        return $true
    }
    if ($SubCommand -ne "checkout") { return $false }
    if ($Args.Count -eq 0) { return $false }
    if ($Args -contains "-h" -or $Args -contains "--help") { return $false }
    if ($Args -contains "-p" -or $Args -contains "--patch") { return $false }
    if ($Args -contains "--ours" -or $Args -contains "--theirs") { return $false }
    if ($Args -contains "-f" -or $Args -contains "--force") { return $false }
    $dashIdx = [Array]::IndexOf($Args, "--")
    if ($dashIdx -ge 0) {
        $before = @()
        if ($dashIdx -gt 0) { $before = $Args[0..($dashIdx - 1)] }
        foreach ($a in $before) {
            if ($a -in @("-b", "-B", "-c", "-C", "-d", "-D", "-t")) { return $true }
        }
        return ($before.Count -gt 0)
    }
    foreach ($a in $Args) {
        if ($a -eq "-") { return $true }
        if ($a -in @("-b", "-B", "-c", "-C", "-d", "-D", "-t")) { return $true }
        if ($a.StartsWith("-")) { continue }
        return $true
    }
    return $false
}

function Start-SyncPromptAsync([string]$RepoRoot) {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return }
    $safeName = ($RepoRoot -replace '[\\/:*?"<>|]', '_')
    $lock = Join-Path $env:TEMP ("ugit-sync-prompt-{0}.lock" -f $safeName)
    try {
        if (Test-Path -LiteralPath $lock) {
            $age = (Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime
            if ($age.TotalSeconds -lt 4) { return }
        }
        [System.IO.File]::WriteAllText($lock, (Get-Date).ToString("o"))
    } catch {
        return
    }

    $promptPs1 = Join-Path $PSScriptRoot "ShowSyncDirtyPrompt.ps1"
    if (-not (Test-Path -LiteralPath $promptPs1)) { return }

    $branch = ""
    $head = Invoke-RealGit @("rev-parse", "--abbrev-ref", "HEAD") -Quiet
    if ($head.Code -eq 0 -and $head.Output.Trim()) { $branch = $head.Output.Trim() }

    $count = 0
    $st = Invoke-RealGit @("status", "--porcelain") -Quiet
    if ($st.Code -eq 0) {
        foreach ($line in ($st.Output -split "[\r\n]+")) {
            if ($line -and $line.Trim()) { $count++ }
        }
    }

    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $promptPs1,
        "-RepoRoot", $RepoRoot,
        "-CurrentBranch", $branch,
        "-ChangeCount", ([string]$count)
    ) -WindowStyle Normal | Out-Null
}

$script:RealGit = Get-RealGitPath
Clear-DisabledHooksPathFromProcessEnv

if ($null -eq $GitArgs -or $GitArgs.Count -eq 0) {
    $r = Invoke-RealGit @("--version")
    exit $r.Code
}

$invocation = Get-SanitizedGitInvocation $GitArgs
$GitArgs = @($invocation.Args)
$sub = [string]$invocation.SubCommand
$rest = @($invocation.Rest)
$repoRoot = Get-RepoRoot
$dirty = Test-WorkingTreeDirty

if ($dirty -and $sub -eq "pull") {
    $safeSync = Join-Path $PSScriptRoot "UGit-SafeSync.ps1"
    if (Test-Path -LiteralPath $safeSync) {
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", $safeSync,
            "-RepoRoot", $repoRoot
        ) -Wait -PassThru -WindowStyle Normal
        if ($null -eq $p) { exit 1 }
        exit $p.ExitCode
    }
}

if ($dirty -and ($sub -eq "switch" -or ($sub -eq "checkout" -and (Test-IsBranchSwitch $sub $rest)))) {
    Start-SyncPromptAsync $repoRoot
}

$result = Invoke-RealGit $GitArgs

if ($result.Code -ne 0 -and (Test-IsDirtyTreeMessage $result.Output)) {
    Start-SyncPromptAsync $repoRoot
}

exit $result.Code
