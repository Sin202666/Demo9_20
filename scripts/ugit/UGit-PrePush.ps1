#Requires -Version 5.1
<#
.SYNOPSIS
  pre-push: fetch, detect diverge/behind, prompt, rebase, then abort this push.
.DESCRIPTION
  Safety:
  - After successful rebase always exit 1 (caller must push again; same push keeps old SHAs)
  - On conflict: stop and instruct manual continue/abort; never auto --continue
  - Never force push
  - Git for Windows may give empty pre-push stdin (esp. local remotes); fallback to HEAD vs remote/branch
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$RemoteName,

    [string]$StdinFile = "",

    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

function Decode-Utf8B64([string]$Text) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Write-Log([string]$Message) {
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch {}
    Write-Host ("[UGit-PrePush] " + $Message)
}

function Show-InfoBox([string]$Message) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        (Decode-Utf8B64 "5o6o6YCB5YmN5qOA5rWL"),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function Show-ErrorBox([string]$Message) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        (Decode-Utf8B64 "5o6o6YCB5YmN5qOA5rWL"),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
}

function Invoke-Git([string[]]$GitArgs) {
    # Git writes progress to stderr; under ErrorAction Stop that becomes terminating. Capture as text.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & git @GitArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return @{ Code = $code; Output = [string]::Join([Environment]::NewLine, @($output)) }
}

function Get-GitLine([string[]]$GitArgs) {
    $r = Invoke-Git $GitArgs
    if ($r.Code -ne 0) { return $null }
    $line = (($r.Output -split "[\r\n]+") | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if ($null -eq $line) { return $null }
    return $line.Trim()
}

function Test-IsZeroSha([string]$Sha) {
    return ($Sha -match '^0+$')
}

function Get-Relation([string]$LocalSha, [string]$RemoteSha) {
    if (Test-IsZeroSha $LocalSha) { return "Delete" }
    if (Test-IsZeroSha $RemoteSha) { return "NewBranch" }
    if ($LocalSha -eq $RemoteSha) { return "Same" }

    $r1 = Invoke-Git @("merge-base", "--is-ancestor", $RemoteSha, $LocalSha)
    if ($r1.Code -eq 0) { return "FastForward" }

    $r2 = Invoke-Git @("merge-base", "--is-ancestor", $LocalSha, $RemoteSha)
    if ($r2.Code -eq 0) { return "Behind" }

    return "Diverged"
}

if (-not $RepoRoot) {
    $RepoRoot = Get-GitLine @("rev-parse", "--show-toplevel")
    if (-not $RepoRoot) {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    }
}
$RepoRoot = (($RepoRoot -split "[\r\n]+")[0]).Trim()

Set-Location -LiteralPath $RepoRoot
$script:LogFile = Join-Path $PSScriptRoot "prepush-last.log"
$promptPs1 = Join-Path $PSScriptRoot "ShowPrePushRebasePrompt.ps1"
$checkPs1 = Join-Path $PSScriptRoot "Check-HookVersion.ps1"
$alertPs1 = Join-Path $PSScriptRoot "ShowHookAlert.ps1"
$msgRebaseDone = Decode-Utf8B64 "5bey5a6M5oiQIHJlYmFzZe+8jOacrOasoeaOqOmAgeW3suS4reatouOAguivt+mHjeaWsOaJp+ihjCBwdXNo44CC"
$msgRebaseConflict = Decode-Utf8B64 "5Y+R55Sf5Yay56qB77yM5o6o6YCB5bey5Lit5q2i44CC6K+36Kej5Yaz5Yay56qB5ZCO5omn6KGMIGdpdCByZWJhc2UgLS1jb250aW51Ze+8jOWGjemHjeaWsOaOqOmAgeOAguiLpeimgeaUvuW8g++8mmdpdCByZWJhc2UgLS1hYm9ydA=="

# Block push when scripts/ugit/VERSION is newer than installed hooks (same as pre-commit).
if (Test-Path -LiteralPath $checkPs1) {
    $check1 = Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $checkPs1, "-RepoRoot", $RepoRoot
    ) -Wait -PassThru -WindowStyle Hidden
    if ($check1.ExitCode -ne 0) {
        Write-Log "hook version outdated; show alert"
        if (Test-Path -LiteralPath $alertPs1) {
            Start-Process -FilePath "powershell.exe" -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", $alertPs1, "-Reason", "HookOutdated", "-Level", "Warning"
            ) -Wait -PassThru -WindowStyle Normal | Out-Null
        }
        $check2 = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", $checkPs1, "-RepoRoot", $RepoRoot
        ) -Wait -PassThru -WindowStyle Hidden
        if ($check2.ExitCode -ne 0) {
            Write-Log "hook version still outdated; block push"
            exit 1
        }
        Write-Log "hook version updated after alert; continue push checks"
    }
}

$targets = @()
if ($StdinFile) {
    if (-not [System.IO.Path]::IsPathRooted($StdinFile)) {
        $StdinFile = Join-Path $RepoRoot $StdinFile
    }
    $StdinFile = [System.IO.Path]::GetFullPath($StdinFile)
    if (Test-Path -LiteralPath $StdinFile) {
        $lines = @(
            Get-Content -LiteralPath $StdinFile -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.Trim() }
        )
        foreach ($line in $lines) {
            $parts = $line.Trim() -split '\s+'
            if ($parts.Count -lt 4) { continue }
            $localRef = $parts[0]
            $localSha = $parts[1]
            $remoteRef = $parts[2]
            $remoteSha = $parts[3]
            if ($localRef -notlike "refs/heads/*") { continue }
            if (Test-IsZeroSha $localSha) { continue }
            $branch = $localRef.Substring("refs/heads/".Length)
            $targets += [pscustomobject]@{
                Branch = $branch
                LocalSha = $localSha
                RemoteShaHint = $remoteSha
            }
        }
    } else {
        Write-Log "stdin file missing: $StdinFile (will try HEAD fallback)"
    }
}

if ($targets.Count -eq 0) {
    # Git for Windows often feeds empty stdin to pre-push (seen with file:// and local path remotes).
    $branch = Get-GitLine @("rev-parse", "--abbrev-ref", "HEAD")
    $localSha = Get-GitLine @("rev-parse", "HEAD")
    if (-not $branch -or $branch -eq "HEAD" -or -not $localSha) {
        Write-Log "no push targets and cannot resolve HEAD; allow"
        exit 0
    }
    Write-Log ("stdin empty/missing; fallback HEAD branch={0} sha={1}" -f $branch, $localSha.Substring(0, [Math]::Min(7, $localSha.Length)))
    $targets += [pscustomobject]@{
        Branch = $branch
        LocalSha = $localSha
        RemoteShaHint = ("0" * 40)
    }
}

$fetch = Invoke-Git @("fetch", $RemoteName, "--prune")
$fetchOk = ($fetch.Code -eq 0)
if (-not $fetchOk) {
    Write-Log ("fetch failed: " + $fetch.Output.Trim())
    if (Test-Path -LiteralPath $promptPs1) {
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", $promptPs1,
            "-Kind", "FetchFailed",
            "-Remote", $RemoteName,
            "-Branch", $targets[0].Branch
        ) -Wait -PassThru -WindowStyle Normal
        if ($p.ExitCode -eq 0) {
            Write-Log "user chose push anyway after fetch failure"
            exit 0
        }
    }
    Write-Log "push cancelled (fetch failed)"
    exit 1
}

$needKind = $null
$needBranch = $null
$needUpstream = $null
$detailLines = New-Object System.Collections.Generic.List[string]

foreach ($t in $targets) {
    $upstream = "{0}/{1}" -f $RemoteName, $t.Branch
    $remoteSha = Get-GitLine @("rev-parse", "--verify", $upstream)
    if (-not $remoteSha) {
        if (Test-IsZeroSha $t.RemoteShaHint) {
            Write-Log ("new remote branch: " + $t.Branch)
            continue
        }
        $remoteSha = $t.RemoteShaHint
    }

    $rel = Get-Relation $t.LocalSha $remoteSha
    $localShort = $t.LocalSha.Substring(0, [Math]::Min(7, $t.LocalSha.Length))
    $remoteShort = $remoteSha.Substring(0, [Math]::Min(7, $remoteSha.Length))
    Write-Log ("ref={0} local={1} remote={2} relation={3}" -f $t.Branch, $localShort, $remoteShort, $rel)

    if ($rel -eq "FastForward" -or $rel -eq "Same" -or $rel -eq "NewBranch" -or $rel -eq "Delete") {
        continue
    }

    [void]$detailLines.Add(("{0}: {1}" -f $t.Branch, $rel))
    if ($null -eq $needKind) {
        $needKind = $rel
        $needBranch = $t.Branch
        $needUpstream = $upstream
    } elseif ($rel -eq "Diverged") {
        $needKind = "Diverged"
        $needBranch = $t.Branch
        $needUpstream = $upstream
    }
}

if (-not $needKind) {
    Write-Log "all branch refs fast-forwardable, allow"
    exit 0
}

$kind = if ($needKind -eq "Behind") { "Behind" } else { "Diverged" }
$detail = [string]::Join(" ; ", $detailLines.ToArray())

$choice = 1
if (Test-Path -LiteralPath $promptPs1) {
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $promptPs1,
        "-Kind", $kind,
        "-Remote", $RemoteName,
        "-Branch", $needBranch,
        "-Detail", $detail
    ) -Wait -PassThru -WindowStyle Normal
    $choice = $p.ExitCode
} else {
    Write-Log "prompt script missing, cancel push"
    exit 1
}

if ($choice -ne 0) {
    Write-Log "user cancelled push"
    exit 1
}

$head = Get-GitLine @("rev-parse", "--abbrev-ref", "HEAD")
if ($head -ne $needBranch) {
    Write-Log ("HEAD is {0}, push target {1}; refuse auto-rebase" -f $head, $needBranch)
    Show-ErrorBox ("HEAD=$head / push=$needBranch`nRefuse auto rebase. Checkout the branch, then: git pull --rebase")
    exit 1
}

$rebaseInProgress = (Test-Path -LiteralPath (Join-Path $RepoRoot ".git\rebase-merge")) -or
    (Test-Path -LiteralPath (Join-Path $RepoRoot ".git\rebase-apply"))
if ($rebaseInProgress) {
    Show-ErrorBox "rebase already in progress"
    exit 1
}
if (Test-Path -LiteralPath (Join-Path $RepoRoot ".git\MERGE_HEAD")) {
    Show-ErrorBox "merge in progress; refuse auto rebase"
    exit 1
}

Write-Log ("user confirmed; rebasing onto " + $needUpstream)
$rebase = Invoke-Git @("rebase", "--autostash", $needUpstream)
if ($rebase.Code -ne 0) {
    Write-Log ("rebase failed:`n" + $rebase.Output)
    Show-ErrorBox $msgRebaseConflict
    exit 1
}

Write-Log "rebase ok; abort this push so user retries"
Show-InfoBox $msgRebaseDone
exit 1
