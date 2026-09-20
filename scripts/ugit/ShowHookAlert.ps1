#Requires -Version 5.1
param(
    [ValidateSet("BuildFailed", "GitAddFailed", "RepoCdFailed", "HookOutdated", "Custom")]
    [string]$Reason = "Custom",

    [string]$Message = "",

    [ValidateSet("Error", "Warning", "Info")]
    [string]$Level = "Error"
)

$ErrorActionPreference = "Continue"

function Decode-Utf8B64([string]$Text) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Read-Utf8File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($null -eq $bytes -or $bytes.Length -eq 0) { return "" }
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $offset = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $offset = 3
        }
        $text = $utf8.GetString($bytes, $offset, $bytes.Length - $offset)
        return ($text -replace "^\uFEFF", "").Trim()
    } catch {
        return ""
    }
}

function Normalize-WinNewlines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $t = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    return ($t -replace "`n", "`r`n")
}

function Parse-ErrorFields([string]$Text, [string]$FieldPattern) {
    $map = @{}
    $summaryLines = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -eq "") { continue }
        if ($line -match $FieldPattern) {
            $map[$matches[1]] = $matches[2].Trim()
        } else {
            [void]$summaryLines.Add($line)
        }
    }
    return @{
        Map = $map
        Summary = [string]::Join("`r`n", $summaryLines.ToArray())
    }
}

function New-Color([int]$R, [int]$G, [int]$B) {
    return [System.Drawing.Color]::FromArgb($R, $G, $B)
}

function Show-OwnedMessage([System.Windows.Forms.Form]$Owner, [string]$Text, [string]$Caption) {
    # Owner + temporarily clear TopMost so MessageBox is not buried under the alert.
    $wasTop = $false
    if ($Owner -ne $null) {
        $wasTop = $Owner.TopMost
        $Owner.TopMost = $false
        $Owner.BringToFront() | Out-Null
        [void][System.Windows.Forms.MessageBox]::Show($Owner, $Text, $Caption)
        $Owner.TopMost = $wasTop
        $Owner.Activate() | Out-Null
    } else {
        [void][System.Windows.Forms.MessageBox]::Show($Text, $Caption)
    }
}

function Add-MetaRow(
    [System.Windows.Forms.TableLayoutPanel]$Table,
    [int]$Row,
    [string]$Label,
    [string]$Value,
    [System.Drawing.Font]$LabelFont,
    [System.Drawing.Font]$ValueFont,
    $Muted,
    $Ink
) {
    $lab = New-Object System.Windows.Forms.Label
    $lab.Text = $Label
    $lab.Dock = "Fill"
    $lab.TextAlign = "MiddleLeft"
    $lab.Font = $LabelFont
    $lab.ForeColor = $Muted
    $lab.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)

    $val = New-Object System.Windows.Forms.Label
    $val.Text = $Value
    $val.Dock = "Fill"
    $val.TextAlign = "MiddleLeft"
    $val.Font = $ValueFont
    $val.ForeColor = $Ink
    $val.AutoEllipsis = $true
    $val.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)

    $Table.Controls.Add($lab, 0, $Row)
    $Table.Controls.Add($val, 1, $Row)
}

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

$title = Decode-Utf8B64 "6YWN572u5omT6KGo5aSx6LSlIC0g5bey5Lit5q2i5o+Q5Lqk"
$subtitle = Decode-Utf8B64 "6K+35L+u5q2j6YWN572u6KGo5ZCO6YeN5paw5o+Q5Lqk"
$okText = Decode-Utf8B64 "56Gu5a6a"
$copyText = Decode-Utf8B64 "5aSN5Yi26ZSZ6K+v5L+h5oGv"
$copiedText = Decode-Utf8B64 "5bey5aSN5Yi25Yiw5Ymq6LS05p2/"
$detailTitle = Decode-Utf8B64 "6K+m57uG5L+h5oGv"
$reasonTitle = Decode-Utf8B64 "5Y6f5Zug"
$lblFile = Decode-Utf8B64 "5paH5Lu2"
$lblRow = Decode-Utf8B64 "6KGM5Y+3"
$lblField = Decode-Utf8B64 "5a2X5q61"
$lblType = Decode-Utf8B64 "57G75Z6L"
$lblValue = Decode-Utf8B64 "5b2T5YmN5YC8"
$kFile = Decode-Utf8B64 "5paH5Lu2"
$kRow = Decode-Utf8B64 "6KGM5Y+3"
$kField = Decode-Utf8B64 "5a2X5q61"
$kType = Decode-Utf8B64 "57G75Z6L"
$kValue = Decode-Utf8B64 "5b2T5YmN5YC8"
$kReason = Decode-Utf8B64 "5Y6f5Zug"
$fieldPattern = Decode-Utf8B64 "Xijmlofku7Z86KGM5Y+3fOWtl+autXznsbvlnot85b2T5YmN5YC8fOWOn+WboClccypbOu+8ml1ccyooLiopJA=="
$summaryDefault = Decode-Utf8B64 "6YWN572u5qCh6aqM5aSx6LSl77yM5o+Q5Lqk5bey5Lit5q2i44CC"
$btnInstallPyText = Decode-Utf8B64 "5LiA6ZSu5a6J6KOFIFB5dGhvbg=="
$btnInstallXlText = Decode-Utf8B64 "5LiA6ZSu5a6J6KOFIG9wZW5weXhs"
$btnInstallingText = Decode-Utf8B64 "5q2j5Zyo5a6J6KOF77yM6K+356iN5YCZ4oCm"
$installOkText = Decode-Utf8B64 "5a6J6KOF5a6M5oiQ77yB6K+35YWz6Zet5pys56qX5Y+j5ZCO6YeN5paw5o+Q5Lqk44CC"
$installFailText = Decode-Utf8B64 "5a6J6KOF5pyq5a6M5oiQ44CC6K+35p+l55yL5a6J6KOF56qX5Y+j5Lit55qE6K+05piO77yM5oiW5omT5byA5a6Y572R5omL5Yqo5a6J6KOF77yI5Yu+6YCJIEFkZCBweXRob24uZXhlIHRvIFBBVEjvvInjgII="
$openDownloadText = Decode-Utf8B64 "5omT5byA5a6Y572R5LiL6L29"


$fallbackBuild = Decode-Utf8B64 "RXhjZWwg6YWN572u5omT6KGo5aSx6LSl77yM5pys5qyh5o+Q5Lqk5bey5Y+W5raI44CCCgror7fmn6XnnIvmjqfliLblj7AgW0V4Y2VsVG9MdWFdW0VSUk9SXSDooYzvvIzmiJYgc2NyaXB0c1x1Z2l0XHByZWNvbW1pdC1sYXN0LWVycm9yLnR4dArmiYvliqjpqozor4HvvJpzY3JpcHRzXHVnaXRcQnVpbGRDb25maWcuYmF0"
$fallbackGitAdd = Decode-Utf8B64 "5omT6KGo5bey5oiQ5Yqf77yM5L2G5pqC5a2Y5Lqn54mp5aSx6LSl77yIQ29uZmlnSW5zdGFuY2UubHVhdSAvIExhbmd1YWdlLmx1YXXvvInjgIIKCuivt+ajgOafpeaWh+S7tuaYr+WQpuiiq+WNoOeUqOaIluadg+mZkOS4jei2s++8jOeEtuWQjumHjeivleaPkOS6pOOAgg=="
$fallbackRepoCd = Decode-Utf8B64 "5peg5rOV6L+b5YWl5LuT5bqT5qC555uu5b2V77yM6ZKp5a2Q5peg5rOV57un57ut44CCCgror7fnoa7orqQgVUdpdCDmiZPlvIDnmoTmmK/mraPnoa7ku5PlupPvvIzmiJbph43mlrDphY3nva4gcHJlLWNvbW1pdCDohJrmnKzot6/lvoTjgII="
$fallbackCustom = Decode-Utf8B64 "6YWN572u6ZKp5a2Q5omn6KGM5aSx6LSl77yM5pys5qyh5o+Q5Lqk5bey5Y+W5raI44CC6K+35p+l55yL5o6n5Yi25Y+w5pel5b+X44CC"
$fallbackHookOutdated = Decode-Utf8B64 "6YWN572u5omT6KGo6ZKp5a2Q54mI5pys6L+H5pyf77yM6K+35pu05paw5ZCO5YaN5o+Q5Lqk44CC"
$btnUpdateHookText = Decode-Utf8B64 "5LiA6ZSu5pu05paw6ZKp5a2Q"
$updateHookOkText = Decode-Utf8B64 "6ZKp5a2Q5bey5pu05paw5Yiw5pyA5paw54mI5pys44CC6K+35YWz6Zet5pys56qX5Y+j5ZCO6YeN5paw5o+Q5Lqk44CC"
$updateHookFailText = Decode-Utf8B64 "6ZKp5a2Q5pu05paw5aSx6LSl77yM6K+35Y+M5Ye76L+Q6KGMIHNjcmlwdHNcdWdpdFwxLeWuieijheaIluabtOaWsOaJk+ihqOmSqeWtkC5iYXQ="
$hookOutdatedSubtitle = Decode-Utf8B64 "6K+35YWI5pu05paw5pys5Zyw6ZKp5a2Q77yM5YaN5o+Q5Lqk6YWN572u6KGo"


$errFile = Join-Path $PSScriptRoot "precommit-last-error.txt"
$errKindFile = Join-Path $PSScriptRoot "precommit-last-error.kind"
$errKind = ""
if (Test-Path -LiteralPath $errKindFile) {
    try { $errKind = ([System.IO.File]::ReadAllText($errKindFile)).Trim() } catch { $errKind = "" }
}
if ($Reason -eq "HookOutdated" -and -not $errKind) { $errKind = "HookOutdated" }
if ($Reason -eq "HookOutdated") { $subtitle = $hookOutdatedSubtitle }

$fromParam = if ($null -ne $Message) { $Message.Trim() } else { "" }
$fromFile = Read-Utf8File $errFile

$body = ""
if (-not [string]::IsNullOrWhiteSpace($fromParam)) { $body = $fromParam }
elseif (-not [string]::IsNullOrWhiteSpace($fromFile)) { $body = $fromFile }
else {
    $body = switch ($Reason) {
        "BuildFailed" { $fallbackBuild }
        "GitAddFailed" { $fallbackGitAdd }
        "RepoCdFailed" { $fallbackRepoCd }
        "HookOutdated" { $fallbackHookOutdated }
        default { $fallbackCustom }
    }
}
if ([string]::IsNullOrWhiteSpace($body)) { $body = $fallbackBuild }
$body = Normalize-WinNewlines $body
$parsed = Parse-ErrorFields $body $fieldPattern
$fields = $parsed.Map
$summary = $parsed.Summary
if ([string]::IsNullOrWhiteSpace($summary)) { $summary = $summaryDefault }

try {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ("[UGit-PreCommit] " + $title) -ForegroundColor Red
    Write-Host $body -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
} catch {}

$cPage = New-Color 248 250 252
$cHeader = New-Color 15 23 42
$cAccent = switch ($Level) {
    "Warning" { New-Color 217 119 6 }
    "Info" { New-Color 2 132 199 }
    default { New-Color 220 38 38 }
}
$cCard = [System.Drawing.Color]::White
$cBorder = New-Color 226 232 240
$cMuted = New-Color 100 116 139
$cInk = New-Color 15 23 42
$cReasonBg = New-Color 255 241 242
$cReasonBorder = New-Color 254 202 202

$fontUi = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$fontTitle = New-Object System.Drawing.Font("Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold)
$fontSub = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$fontSection = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$fontMetaLabel = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$fontMetaValue = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$fontReason = New-Object System.Drawing.Font("Microsoft YaHei UI", 11, [System.Drawing.FontStyle]::Bold)
$fontBody = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

$form = New-Object System.Windows.Forms.Form
$form.Text = $title
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size(760, 560)
$form.MinimumSize = New-Object System.Drawing.Size(640, 480)
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.Font = $fontUi
$form.BackColor = $cPage
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$accent = New-Object System.Windows.Forms.Panel
$accent.Dock = "Left"
$accent.Width = 6
$accent.BackColor = $cAccent
$form.Controls.Add($accent)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 92
$header.BackColor = $cHeader

$iconBox = New-Object System.Windows.Forms.PictureBox
$iconBox.Size = New-Object System.Drawing.Size(40, 40)
$iconBox.Location = New-Object System.Drawing.Point(22, 24)
$iconBox.SizeMode = "StretchImage"
$iconKind = switch ($Level) {
    "Warning" { [System.Drawing.SystemIcons]::Warning }
    "Info" { [System.Drawing.SystemIcons]::Information }
    default { [System.Drawing.SystemIcons]::Error }
}
$iconBox.Image = $iconKind.ToBitmap()
$header.Controls.Add($iconBox)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.AutoSize = $false
$titleLabel.Location = New-Object System.Drawing.Point(76, 18)
$titleLabel.Size = New-Object System.Drawing.Size(640, 32)
$titleLabel.Font = $fontTitle
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Text = $title
$titleLabel.BackColor = $cHeader
$header.Controls.Add($titleLabel)

$subLabel = New-Object System.Windows.Forms.Label
$subLabel.AutoSize = $false
$subLabel.Location = New-Object System.Drawing.Point(76, 52)
$subLabel.Size = New-Object System.Drawing.Size(640, 24)
$subLabel.Font = $fontSub
$subLabel.ForeColor = New-Color 148 163 184
$subLabel.Text = $subtitle
$subLabel.BackColor = $cHeader
$header.Controls.Add($subLabel)

$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = "Bottom"
$footer.Height = 72
$footer.BackColor = $cPage

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = $copyText
$btnCopy.Size = New-Object System.Drawing.Size(140, 38)
$btnCopy.Location = New-Object System.Drawing.Point(24, 16)
$btnCopy.FlatStyle = "Flat"
$btnCopy.BackColor = [System.Drawing.Color]::White
$btnCopy.ForeColor = $cInk
$btnCopy.FlatAppearance.BorderColor = $cBorder
$btnCopy.FlatAppearance.BorderSize = 1
$btnCopy.Cursor = [System.Windows.Forms.Cursors]::Hand
$footer.Controls.Add($btnCopy)

$btnOk = New-Object System.Windows.Forms.Button
$btnOk.Text = $okText
$btnOk.Size = New-Object System.Drawing.Size(128, 38)
$btnOk.FlatStyle = "Flat"
$btnOk.BackColor = $cAccent
$btnOk.ForeColor = [System.Drawing.Color]::White
$btnOk.FlatAppearance.BorderSize = 0
$btnOk.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
$btnOk.Location = New-Object System.Drawing.Point(596, 16)
$footer.Controls.Add($btnOk)

$btnInstall = $null
$btnDownload = $null
$needPyInstall = ($errKind -eq "NoPython" -or $errKind -eq "NoOpenpyxl" -or $errKind -eq "PythonTooOld")
$showInstall = ($needPyInstall -or $errKind -eq "HookOutdated")
if ($showInstall) {
    $btnInstall = New-Object System.Windows.Forms.Button
    if ($errKind -eq "NoPython" -or $errKind -eq "PythonTooOld") {
        $btnInstall.Text = $btnInstallPyText
    } elseif ($errKind -eq "NoOpenpyxl") {
        $btnInstall.Text = $btnInstallXlText
    } else {
        $btnInstall.Text = $btnUpdateHookText
    }
    $btnInstall.Size = New-Object System.Drawing.Size(168, 38)
    $btnInstall.Location = New-Object System.Drawing.Point(176, 16)
    $btnInstall.FlatStyle = "Flat"
    $btnInstall.BackColor = New-Color 22 163 74
    $btnInstall.ForeColor = [System.Drawing.Color]::White
    $btnInstall.FlatAppearance.BorderSize = 0
    $btnInstall.Cursor = [System.Windows.Forms.Cursors]::Hand
    $footer.Controls.Add($btnInstall)

    if ($needPyInstall) {
        $btnDownload = New-Object System.Windows.Forms.Button
        $btnDownload.Text = $openDownloadText
        $btnDownload.Size = New-Object System.Drawing.Size(120, 38)
        $btnDownload.Location = New-Object System.Drawing.Point(356, 16)
        $btnDownload.FlatStyle = "Flat"
        $btnDownload.BackColor = [System.Drawing.Color]::White
        $btnDownload.ForeColor = $cInk
        $btnDownload.FlatAppearance.BorderColor = $cBorder
        $btnDownload.FlatAppearance.BorderSize = 1
        $btnDownload.Cursor = [System.Windows.Forms.Cursors]::Hand
        $footer.Controls.Add($btnDownload)
        $btnDownload.Add_Click({
            Start-Process "https://www.python.org/downloads/windows/"
        }.GetNewClosure())
    }
}


$hostPanel = New-Object System.Windows.Forms.Panel
$hostPanel.Dock = "Fill"
$hostPanel.BackColor = $cPage
$hostPanel.Padding = New-Object System.Windows.Forms.Padding(24, 18, 24, 8)
$hostPanel.AutoScroll = $true

$sumCard = New-Object System.Windows.Forms.Panel
$sumCard.Height = 56
$sumCard.Dock = "Top"
$sumCard.BackColor = $cCard
$sumCard.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)

$sumText = New-Object System.Windows.Forms.Label
$sumText.Dock = "Fill"
$sumText.Font = $fontBody
$sumText.ForeColor = $cInk
$sumText.Text = $summary
$sumText.TextAlign = "MiddleLeft"
$sumCard.Controls.Add($sumText)

$metaWrap = New-Object System.Windows.Forms.Panel
$metaWrap.Dock = "Top"
$metaWrap.Height = 236
$metaWrap.Padding = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
$metaWrap.BackColor = $cPage

$metaCard = New-Object System.Windows.Forms.Panel
$metaCard.Dock = "Fill"
$metaCard.BackColor = $cCard
$metaCard.Padding = New-Object System.Windows.Forms.Padding(16, 10, 16, 10)

$metaHead = New-Object System.Windows.Forms.Label
$metaHead.Text = $detailTitle
$metaHead.Dock = "Top"
$metaHead.Height = 28
$metaHead.Font = $fontSection
$metaHead.ForeColor = $cMuted

$hasStructured = ($fields.Count -gt 0)
if ($hasStructured) {
    $table = New-Object System.Windows.Forms.TableLayoutPanel
    $table.Dock = "Fill"
    $table.ColumnCount = 2
    $table.RowCount = 5
    $table.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 80)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    for ($i = 0; $i -lt 5; $i++) {
        [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
    }

    $rows = @(
        @{ L = $lblFile; K = $kFile },
        @{ L = $lblRow; K = $kRow },
        @{ L = $lblField; K = $kField },
        @{ L = $lblType; K = $kType },
        @{ L = $lblValue; K = $kValue }
    )
    $r = 0
    foreach ($item in $rows) {
        $v = ""
        if ($fields.ContainsKey($item.K)) { $v = [string]$fields[$item.K] }
        if ([string]::IsNullOrWhiteSpace($v)) { $v = "-" }
        Add-MetaRow $table $r $item.L $v $fontMetaLabel $fontMetaValue $cMuted $cInk
        $r++
    }
    # Dock order: Fill first, then Top — otherwise Top header covers first row (file name).
    $metaCard.Controls.Add($table)
    $metaCard.Controls.Add($metaHead)
} else {
    $rawBox = New-Object System.Windows.Forms.RichTextBox
    $rawBox.Dock = "Fill"
    $rawBox.ReadOnly = $true
    $rawBox.BorderStyle = "None"
    $rawBox.BackColor = $cCard
    $rawBox.ForeColor = $cInk
    $rawBox.Font = $fontBody
    $rawBox.Text = $body
    $rawBox.DetectUrls = $false
    $metaCard.Controls.Add($rawBox)
    $metaCard.Controls.Add($metaHead)
    $metaWrap.Height = 280
}

$metaWrap.Controls.Add($metaCard)

$reasonWrap = New-Object System.Windows.Forms.Panel
$reasonWrap.Dock = "Top"
$reasonWrap.Height = 120
$reasonWrap.Padding = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
$reasonWrap.BackColor = $cPage

$reasonCard = New-Object System.Windows.Forms.Panel
$reasonCard.Dock = "Fill"
$reasonCard.BackColor = $cReasonBg
$reasonCard.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)

$reasonHead = New-Object System.Windows.Forms.Label
$reasonHead.Text = $reasonTitle
$reasonHead.Dock = "Top"
$reasonHead.Height = 24
$reasonHead.Font = $fontSection
$reasonHead.ForeColor = $cAccent

$reasonText = New-Object System.Windows.Forms.Label
$reasonText.Dock = "Fill"
$reasonText.Font = $fontReason
$reasonText.ForeColor = $cInk
$reasonVal = ""
if ($fields.ContainsKey($kReason)) { $reasonVal = [string]$fields[$kReason] }
if ([string]::IsNullOrWhiteSpace($reasonVal)) { $reasonVal = $summary }
$reasonText.Text = $reasonVal

# Same dock order: Fill then Top
$reasonCard.Controls.Add($reasonText)
$reasonCard.Controls.Add($reasonHead)
$reasonWrap.Controls.Add($reasonCard)

# Dock Top: first added sits nearest the top.
$hostPanel.Controls.Add($sumCard)
$hostPanel.Controls.Add($metaWrap)
$hostPanel.Controls.Add($reasonWrap)

$sumCard.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen $cBorder
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
    $pen.Dispose()
})
$metaCard.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen $cBorder
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
    $pen.Dispose()
})
$reasonCard.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen $cReasonBorder
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
    $pen.Dispose()
})

$form.Controls.Add($hostPanel)
$form.Controls.Add($footer)
$form.Controls.Add($header)

if ($btnInstall -ne $null) {
    $installPs1 = Join-Path $PSScriptRoot "Install-Python.ps1"
    $hookInstallPs1 = Join-Path $PSScriptRoot "Install-GitHook.ps1"
    $btnInstall.Add_Click({
        try {
            $btnInstall.Enabled = $false
            if ($btnDownload) { $btnDownload.Enabled = $false }
            $btnCopy.Enabled = $false
            $btnInstall.Text = $btnInstallingText
            $form.UseWaitCursor = $true
            $form.Refresh()
            [System.Windows.Forms.Application]::DoEvents()

            if ($errKind -eq "HookOutdated") {
                if (-not (Test-Path -LiteralPath $hookInstallPs1)) {
                    Show-OwnedMessage $form $updateHookFailText $title
                    return
                }
                $p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", $hookInstallPs1, "-NoPause"
                ) -Wait -PassThru -WindowStyle Normal
                if ($p.ExitCode -eq 0) {
                    Show-OwnedMessage $form $updateHookOkText $title
                } else {
                    Show-OwnedMessage $form $updateHookFailText $title
                }
            } else {
                if (-not (Test-Path -LiteralPath $installPs1)) {
                    Show-OwnedMessage $form $installFailText $title
                    return
                }
                $p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", $installPs1, "-NoPause"
                ) -Wait -PassThru -WindowStyle Normal

                if ($p.ExitCode -eq 0) {
                    Show-OwnedMessage $form $installOkText $title
                } else {
                    Show-OwnedMessage $form $installFailText $title
                }
            }
        } catch {
            Show-OwnedMessage $form ($_.Exception.Message) $title
        } finally {
            $form.UseWaitCursor = $false
            $btnInstall.Enabled = $true
            if ($btnDownload) { $btnDownload.Enabled = $true }
            $btnCopy.Enabled = $true
            if ($errKind -eq "NoPython" -or $errKind -eq "PythonTooOld") { $btnInstall.Text = $btnInstallPyText }
            elseif ($errKind -eq "NoOpenpyxl") { $btnInstall.Text = $btnInstallXlText }
            else { $btnInstall.Text = $btnUpdateHookText }
        }
    }.GetNewClosure())
}

$form.AcceptButton = $btnOk

$btnCopy.Add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText($body)
        $btnCopy.Text = $copiedText
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1500
        $timer.Add_Tick({
            $btnCopy.Text = $copyText
            $timer.Stop()
            $timer.Dispose()
        }.GetNewClosure())
        $timer.Start()
    } catch {}
})

$form.Add_Shown({
    $btnOk.Focus() | Out-Null
})
$form.Add_Resize({
    $btnOk.Left = [Math]::Max(20, $footer.ClientSize.Width - $btnOk.Width - 24)
})
$btnOk.Left = [Math]::Max(20, $footer.ClientSize.Width - $btnOk.Width - 24)

[void]$form.ShowDialog()
$form.Dispose()
exit 0
