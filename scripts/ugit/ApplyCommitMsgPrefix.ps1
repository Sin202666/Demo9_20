#Requires -Version 5.1
<#
.SYNOPSIS
  Prepend config-commit prefix onto COMMIT_EDITMSG.
.DESCRIPTION
  Called from prepare-commit-msg. Reads scripts/ugit/precommit-last-msg-kind
  written by pre-commit (build = 打表并提交, nbuild = 不打表并提交).
  Prefixes the first subject line; skips if already prefixed. Deletes the kind file.
.NOTES
  Module: ApplyCommitMsgPrefix
  Author: 林奥宇
  Created: 2026-09-03
  Last Modified: 2026-09-03
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$MessageFile
)

$ErrorActionPreference = "Continue"

function Decode-Utf8B64([string]$Text) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Get-PrefixForKind([string]$Kind) {
    if ($Kind -eq "nbuild") {
        return (Decode-Utf8B64 "44CQ5pyq5omT6KGo44CR")
    }
    if ($Kind -eq "build") {
        return (Decode-Utf8B64 "44CQ5bey5omT6KGo44CR")
    }
    return ""
}

function Test-HasKnownPrefix([string]$Line) {
    $known = @(
        (Get-PrefixForKind "build"),
        (Get-PrefixForKind "nbuild"),
        (Decode-Utf8B64 "6YWN572u6KGo5o+Q5Lqk77yI5omT6KGo77yJ"),
        (Decode-Utf8B64 "6YWN572u6KGo5o+Q5Lqk77yI5LiN5omT6KGo77yJ")
    )
    foreach ($p in $known) {
        if ($p -and $Line.StartsWith($p)) { return $true }
    }
    return $false
}

$kindPath = Join-Path $PSScriptRoot "precommit-last-msg-kind"
if (-not (Test-Path -LiteralPath $kindPath)) { exit 0 }
if (-not $MessageFile -or -not (Test-Path -LiteralPath $MessageFile)) { exit 0 }

$kind = ((Get-Content -LiteralPath $kindPath -Raw -ErrorAction SilentlyContinue) + "").Trim()
$prefix = Get-PrefixForKind $kind
Remove-Item -LiteralPath $kindPath -Force -ErrorAction SilentlyContinue
if (-not $prefix) { exit 0 }

$utf8 = New-Object System.Text.UTF8Encoding $false
$msgPath = [System.IO.Path]::GetFullPath($MessageFile)
$raw = [System.IO.File]::ReadAllText($msgPath, $utf8)
$nl = "`n"
if ($raw.Contains("`r`n")) { $nl = "`r`n" }

$lines = New-Object System.Collections.Generic.List[string]
foreach ($line in ($raw -split "`r?`n", -1)) {
    [void]$lines.Add($line)
}
if ($lines.Count -eq 0) { [void]$lines.Add("") }

$idx = 0
while ($idx -lt $lines.Count) {
    $t = [string]$lines[$idx]
    if ($t.Trim() -eq "" -or $t.StartsWith("#")) {
        $idx++
        continue
    }
    break
}

if ($idx -ge $lines.Count) {
    [void]$lines.Insert(0, $prefix)
} else {
    $cur = [string]$lines[$idx]
    if (Test-HasKnownPrefix $cur) {
        exit 0
    }
    $rest = $cur.TrimStart()
    if ($rest) {
        $lines[$idx] = $prefix + " " + $rest
    } else {
        $lines[$idx] = $prefix
    }
}

$text = [string]::Join($nl, $lines.ToArray())
if (-not $text.EndsWith($nl)) { $text += $nl }
[System.IO.File]::WriteAllText($msgPath, $text, $utf8)
exit 0
