#Requires -Version 5.1
<#
.SYNOPSIS
  Push 前分叉确认弹窗。
.DESCRIPTION
  Diverged/Behind: Yes=执行对齐(Exit 0), Cancel=取消推送(Exit 1)
  FetchFailed: Yes=仍要推送跳过检测(Exit 0), Cancel=取消推送(Exit 1)
#>
param(
    [string]$Branch = "",
    [string]$Remote = "",
    [string]$Detail = "",

    [ValidateSet("Diverged", "Behind", "FetchFailed")]
    [string]$Kind = "Diverged"
)

$ErrorActionPreference = "Continue"

function Decode-Utf8B64([string]$Text) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

$title = Decode-Utf8B64 "5o6o6YCB5YmN5qOA5rWL"
$btnCancelText = Decode-Utf8B64 "5Y+W5raI5o6o6YCB"
$lblBranch = Decode-Utf8B64 "5YiG5pSv77ya"
$lblRemote = Decode-Utf8B64 "6L+c56uv77ya"
$note = Decode-Utf8B64 "6K+05piO77ya6YCJ5oupIFJlYmFzZSDlkI7vvIzmnKzmrKHmjqjpgIHkvJrkuK3mraLlubbmiafooYzlr7npvZDvvJvmiJDlip/lkI7or7fph43mlrDmjqjpgIHjgILoi6XmnInlhrLnqoHvvIzor7fmjInmj5DnpLrop6PlhrPlkI4gZ2l0IHJlYmFzZSAtLWNvbnRpbnVl77yM5YaN6YeN5paw5o6o6YCB44CC5LiA6Iis5LiN6ZyA6KaBIGZvcmNlIHB1c2jjgII="

if ($Kind -eq "FetchFailed") {
    $btnYesText = Decode-Utf8B64 "5LuN6KaB5o6o6YCB"
    $subtitle = Decode-Utf8B64 "5peg5rOVIGZldGNoIOacgOaWsOi/nOerr++8jOaXoOazleWPr+mdoOWIpOaWreaYr+WQpuWIhuWPieOAguW7uuiuruWPlua2iOaOqOmAgeW5tuajgOafpee9kee7nOWQjuWGjeivleOAgg=="
    $note = ""
} elseif ($Kind -eq "Behind") {
    $btnYesText = Decode-Utf8B64 "56uL5Y2zIFJlYmFzZQ=="
    $subtitle = Decode-Utf8B64 "5pys5Zyw5YiG5pSv6JC95ZCO5LqO6L+c56uv77yM55u05o6o5bCG6KKr5omT5Zue44CC5piv5ZCm5YWI5omn6KGMIHB1bGwgLS1yZWJhc2Ug77yI5b+r6L+b77yJ77yf"
} else {
    $btnYesText = Decode-Utf8B64 "56uL5Y2zIFJlYmFzZQ=="
    $subtitle = Decode-Utf8B64 "5pys5Zyw5LiO6L+c56uv5bey5YiG5Y+J77yM55u05o6l5o6o6YCB5Y+v6IO95Lqn55SfIG1lcmdlIGNvbW1pdO+8jOaIluiiq+acjeWKoeWZqOaLkue7neOAguW7uuiuruWFiCByZWJhc2Ug5ZCO6YeN5paw5o6o6YCB44CC5piv5ZCm56uL5Y2zIFJlYmFzZe+8nw=="
}

if (-not [string]::IsNullOrWhiteSpace($Detail)) {
    $subtitle = $subtitle + "`r`n`r`n" + $Detail.Trim()
}

$bodyText = $subtitle.Trim()
if ($note) { $bodyText = $bodyText + "`r`n`r`n" + $note }

$cPage = [System.Drawing.Color]::FromArgb(248, 250, 252)
$cHeader = [System.Drawing.Color]::FromArgb(15, 23, 42)
$cAccent = [System.Drawing.Color]::FromArgb(217, 119, 6)
$cInk = [System.Drawing.Color]::FromArgb(15, 23, 42)
$cMuted = [System.Drawing.Color]::FromArgb(100, 116, 139)
$cBorder = [System.Drawing.Color]::FromArgb(226, 232, 240)
$cCard = [System.Drawing.Color]::White

$fontUi = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$fontTitle = New-Object System.Drawing.Font("Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold)
$fontSub = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$fontBody = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

$form = New-Object System.Windows.Forms.Form
$form.Text = $title
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size(580, 380)
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
$titleLabel.Location = New-Object System.Drawing.Point(64, 20)
$titleLabel.Size = New-Object System.Drawing.Size(480, 32)
$titleLabel.Font = $fontTitle
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Text = $title
$titleLabel.BackColor = $cHeader
$header.Controls.Add($titleLabel)

$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = "Bottom"
$footer.Height = 72
$footer.BackColor = $cPage

$btnNo = New-Object System.Windows.Forms.Button
$btnNo.Text = $btnCancelText
$btnNo.Size = New-Object System.Drawing.Size(120, 38)
$btnNo.Location = New-Object System.Drawing.Point(24, 16)
$btnNo.FlatStyle = "Flat"
$btnNo.BackColor = $cCard
$btnNo.ForeColor = $cInk
$btnNo.FlatAppearance.BorderColor = $cBorder
$btnNo.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$footer.Controls.Add($btnNo)

$btnYes = New-Object System.Windows.Forms.Button
$btnYes.Text = $btnYesText
$btnYes.Size = New-Object System.Drawing.Size(140, 38)
$btnYes.Location = New-Object System.Drawing.Point(400, 16)
$btnYes.FlatStyle = "Flat"
$btnYes.BackColor = $cAccent
$btnYes.ForeColor = [System.Drawing.Color]::White
$btnYes.FlatAppearance.BorderSize = 0
$btnYes.DialogResult = [System.Windows.Forms.DialogResult]::Yes
$footer.Controls.Add($btnYes)

$hostPanel = New-Object System.Windows.Forms.Panel
$hostPanel.Dock = "Fill"
$hostPanel.Padding = New-Object System.Windows.Forms.Padding(24, 12, 24, 8)
$hostPanel.BackColor = $cPage

$meta = New-Object System.Windows.Forms.Label
$meta.Dock = "Top"
$meta.Height = 28
$meta.Font = $fontSub
$meta.ForeColor = $cMuted
$metaParts = New-Object System.Collections.Generic.List[string]
if ($Branch) { [void]$metaParts.Add($lblBranch + $Branch) }
if ($Remote) { [void]$metaParts.Add($lblRemote + $Remote) }
$meta.Text = [string]::Join("    ", $metaParts.ToArray())

$body = New-Object System.Windows.Forms.Label
$body.Dock = "Fill"
$body.Font = $fontBody
$body.ForeColor = $cInk
$body.Text = $bodyText

$hostPanel.Controls.Add($body)
$hostPanel.Controls.Add($meta)

$form.Controls.Add($hostPanel)
$form.Controls.Add($footer)
$form.Controls.Add($header)
$form.Controls.Add($accent)

$form.AcceptButton = $btnYes
$form.CancelButton = $btnNo
$form.Add_Shown({ $btnYes.Focus() | Out-Null })
$form.Add_Resize({
    $btnYes.Left = [Math]::Max(20, $footer.ClientSize.Width - $btnYes.Width - 24)
})
$btnYes.Left = [Math]::Max(20, $footer.ClientSize.Width - $btnYes.Width - 24)

$result = $form.ShowDialog()
$form.Dispose()

if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
    exit 0
}
exit 1
