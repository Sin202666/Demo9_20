#Requires -Version 5.1
<#
.SYNOPSIS
  pre-merge-commit: block merge commit and guide user to rebase workflow.
.DESCRIPTION
  - Always exit 1 so Git does not create the merge commit
  - Never auto merge --abort or pull --rebase
  - Detect pull-style merge from .git/MERGE_MSG when possible
#>
param(
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
    Write-Host ("[UGit-PreMergeCommit] " + $Message)
}

function Invoke-Git([string[]]$GitArgs) {
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

if (-not $RepoRoot) {
    $RepoRoot = Get-GitLine @("rev-parse", "--show-toplevel")
    if (-not $RepoRoot) {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    }
}
$RepoRoot = (($RepoRoot -split "[\r\n]+")[0]).Trim()

Set-Location -LiteralPath $RepoRoot
$script:LogFile = Join-Path $PSScriptRoot "premergecommit-last.log"
$promptPs1 = Join-Path $PSScriptRoot "ShowPreMergeCommitPrompt.ps1"

$gitDir = Get-GitLine @("rev-parse", "--git-dir")
if (-not $gitDir) {
    Write-Log "cannot resolve git dir"
    exit 1
}
if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
    $gitDir = Join-Path $RepoRoot $gitDir
}
$gitDir = [System.IO.Path]::GetFullPath($gitDir)

$mergeHead = Join-Path $gitDir "MERGE_HEAD"
if (-not (Test-Path -LiteralPath $mergeHead)) {
    Write-Log "MERGE_HEAD missing; allow (unexpected hook call)"
    exit 0
}

$kind = "Generic"
$mergeMsgPath = Join-Path $gitDir "MERGE_MSG"
if (Test-Path -LiteralPath $mergeMsgPath) {
    try {
        $mergeMsg = (Get-Content -LiteralPath $mergeMsgPath -Raw -ErrorAction Stop)
        if ($mergeMsg -match "Merge branch '.+' of ") {
            $kind = "PullMerge"
        } elseif ($mergeMsg -match "^Merge ") {
            $kind = "LocalMerge"
        }
    } catch {
        Write-Log ("read MERGE_MSG failed: " + $_.Exception.Message)
    }
}

$branch = Get-GitLine @("rev-parse", "--abbrev-ref", "HEAD")
if (-not $branch) { $branch = "" }

$upstream = Get-GitLine @("rev-parse", "--abbrev-ref", "@{u}")
if (-not $upstream) { $upstream = "" }

Write-Log ("blocked merge kind={0} branch={1} upstream={2}" -f $kind, $branch, $upstream)

if (Test-Path -LiteralPath $promptPs1) {
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $promptPs1,
        "-RepoRoot", $RepoRoot,
        "-Kind", $kind,
        "-Branch", $branch,
        "-Upstream", $upstream
    ) -Wait -PassThru -WindowStyle Normal
    Write-Log ("prompt exit={0}" -f $p.ExitCode)
} else {
    Write-Log "prompt script missing: $promptPs1"
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [void][System.Windows.Forms.MessageBox]::Show(
        (Decode-Utf8B64 "5pys5LuT5bqT5LiN5L2/55SoIG1lcmdlIGNvbW1pdCDlkIzmraXliIbmlK/vvIzpg73mi6kgZ2l0IG1lcmdlIC0tYWJvcnTigKYgZ2l0IHB1bGwgLS1yZWJhc2XigJM="),
        (Decode-Utf8B64 "5o6o6YCB5YmN5qOA5rWL"),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
}

exit 1
