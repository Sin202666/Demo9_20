#Requires -Version 5.1
<#
.SYNOPSIS
  Safe sync for single-branch workflow: pull --rebase with dirty-tree popup.
.DESCRIPTION
  Installed as git alias ugit-sync. Clean tree: pull --rebase directly.
  Dirty tree: ShowSyncDirtyPrompt.ps1 (stash -> pull --rebase -> pop).
#>
param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Continue"

function Invoke-Git {
    param([string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & git @GitArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return @{
        Code = $code
        Output = [string]::Join([Environment]::NewLine, @($output))
    }
}

function Get-ChangeCount {
    $r = Invoke-Git @("status", "--porcelain")
    if ($r.Code -ne 0) { return 0 }
    $count = 0
    foreach ($line in ($r.Output -split "[\r\n]+")) {
        if ($line -and $line.Trim()) { $count++ }
    }
    return $count
}

function Test-WorkingTreeDirty {
    return (Get-ChangeCount -gt 0)
}

if (-not $RepoRoot) {
    $top = Invoke-Git @("rev-parse", "--show-toplevel")
    if ($top.Code -eq 0 -and $top.Output.Trim()) {
        $RepoRoot = $top.Output.Trim()
    } else {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    }
}
$RepoRoot = (($RepoRoot -split "[\r\n]+")[0]).Trim()
Set-Location -LiteralPath $RepoRoot

if (-not (Test-WorkingTreeDirty)) {
    $pull = Invoke-Git @("pull", "--rebase")
    if ($pull.Code -ne 0 -and $pull.Output) {
        Write-Host $pull.Output
    }
    exit $pull.Code
}

$currentBranch = ""
$head = Invoke-Git @("rev-parse", "--abbrev-ref", "HEAD")
if ($head.Code -eq 0 -and $head.Output.Trim()) {
    $currentBranch = $head.Output.Trim()
}

$changeCount = Get-ChangeCount
$promptPs1 = Join-Path $PSScriptRoot "ShowSyncDirtyPrompt.ps1"
if (-not (Test-Path -LiteralPath $promptPs1)) {
    Write-Host "missing: $promptPs1"
    exit 1
}

$p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", $promptPs1,
    "-RepoRoot", $RepoRoot,
    "-CurrentBranch", $currentBranch,
    "-ChangeCount", ([string]$changeCount)
) -Wait -PassThru -WindowStyle Normal

if ($null -eq $p) { exit 1 }
exit $p.ExitCode
