#Requires -Version 5.1
<#
.SYNOPSIS
  Dirty working tree blocks pull/sync: compact UI with stash + pull --rebase actions.
#>
param(
    [string]$RepoRoot = "",
    [string]$CurrentBranch = "",
    [int]$ChangeCount = 0
)

$ErrorActionPreference = "Continue"

function Decode-Utf8B64([string]$Text) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Invoke-GitInRepo([string[]]$GitArgs) {
    Push-Location -LiteralPath $script:RepoRoot
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = & git @GitArgs 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        return @{
            Code = $code
            Output = [string]::Join([Environment]::NewLine, @($output))
        }
    } finally {
        Pop-Location
    }
}

function Show-Error([string]$Message, [string]$Detail) {
    $text = $Message.Trim()
    if ($Detail) { $text = $text + "`r`n`r`n" + $Detail.Trim() }
    [void][System.Windows.Forms.MessageBox]::Show(
        $text,
        $script:FailTitle,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
}

function Confirm-Action([string]$Message) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $script:Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

if (-not $RepoRoot) {
    $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}
$script:RepoRoot = (($RepoRoot -split "[\r\n]+")[0]).Trim()

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Title = Decode-Utf8B64 "5peg5rOV5ZCM5q2l"
$script:FailTitle = Decode-Utf8B64 "5ZCM5q2l5aSx6LSl"
$headerSub = Decode-Utf8B64 "5bel5L2c5Yy65pyJ5pyq5o+Q5Lqk5pS55Yqo"
$reasonShort = Decode-Utf8B64 "5ouJ5Y+W5ZCM5LqL5Luj56CB5YmN6ZyA5aSE55CG5pys5Zyw5pS55Yqo77yI5Y2V5YiG5pSvIG1haW4g5Y2P5L2c77yJ44CC5o6o6I2Q5LiA6ZSuIHN0YXNoIOWQjiBwdWxsIC0tcmViYXNl77yM5a6M5oiQ5ZCO6Ieq5Yqo5oGi5aSN5pS55Yqo44CC"
$lblCurrent = Decode-Utf8B64 "5b2T5YmN5YiG5pSv77ya"
$lblChanges = Decode-Utf8B64 "5pyq5o+Q5Lqk77ya"
$btnCombinedText = Decode-Utf8B64 "5LiA6ZSu77yac3Rhc2gg5bm25ouJ5Y+W"
$btnStashOnlyText = Decode-Utf8B64 "c3Rhc2gg5bm25ouJ5Y+W77yI5LiN5oGi5aSN77yJ"
$btnCancelText = Decode-Utf8B64 "5Y+W5raI"
$btnCloseDoneText = Decode-Utf8B64 "5a6M5oiQ77yM5YWz6Zet"
$statusBusy = Decode-Utf8B64 "5q2j5Zyo5aSE55CG77yM6K+356iN5YCZ4oCm"
$statusReady = Decode-Utf8B64 "54q25oCB77ya5pyJ5pyq5o+Q5Lqk5pS55YqoIOKAlCDor7fpgInmi6nmk43kvZw="
$statusDoneCombined = Decode-Utf8B64 "5bey5a6M5oiQ77yac3Rhc2gg4oaSIHB1bGwgLS1yZWJhc2Ug4oaSIOaBouWkjeaUueWKqOOAgg=="
$statusDoneStashOnly = Decode-Utf8B64 "5bey5a6M5oiQ77ya5pS55Yqo5beyIHN0YXNo77yM5ouJ5Y+W5oiQ5Yqf44CC5Y+v55SuIGdpdCBzdGFzaCBwb3Ag5oGi5aSN44CC"
$confirmCombined = Decode-Utf8B64 "5bCG5L6d5qyh5omn6KGM77yaZ2l0IHN0YXNoIHB1c2gg4oaSIGdpdCBwdWxsIC0tcmViYXNlIOKGkiBnaXQgc3Rhc2ggcG9w44CC57un57ut77yf"
$confirmStashOnly = Decode-Utf8B64 "5bCG5L6d5qyh5omn6KGM77yaZ2l0IHN0YXNoIHB1c2gg4oaSIGdpdCBwdWxsIC0tcmViYXNl77yI5LiN6Ieq5YqoIHBvcO+8ieOAgue7p+e7re+8nw=="
$errStashPush = Decode-Utf8B64 "Z2l0IHN0YXNoIHB1c2gg5aSx6LSl"
$errPull = Decode-Utf8B64 "Z2l0IHB1bGwgLS1yZWJhc2Ug5aSx6LSl"
$errStashPop = Decode-Utf8B64 "5ouJ5Y+W5oiQ5Yqf77yM5L2GIHN0YXNoIHBvcCDlpLHotKXjgILor7fmiYvliqggZ2l0IHN0YXNoIHBvcOOAgg=="
$errPullStashKept = Decode-Utf8B64 "5ouJ5Y+W5aSx6LSl77yM5pS55Yqo5bey5ZyoIHN0YXNoIOS4reOAguivt+aJi+WKqCBnaXQgc3Rhc2ggcG9wIOaBouWkjeOAgg=="
$conflictHint = Decode-Utf8B64 "6Iul5pyJ5Yay56qB77ya5pS55paH5Lu2IOKGkiBnaXQgYWRkIOKGkiBnaXQgcmViYXNlIC0tY29udGludWU="
$tipCombined = Decode-Utf8B64 "c3Rhc2gg5ZCr5pyq6Lef6Liq5paH5Lu277yM5ouJ5Y+W5ZCO6Ieq5YqoIHBvcCDmgaLlpI0="
$tipStashOnly = Decode-Utf8B64 "5pS55Yqo5L+d55WZ5ZyoIHN0YXNoIOagiOmhtu+8jOmcgOaJi+WKqCBwb3A="
$tipCancel = Decode-Utf8B64 "5L+d5oyB5b2T5YmN5pS55Yqo5LiN5Y+Y"
$filesUnit = Decode-Utf8B64 "IOS4quaWh+S7tg=="
$unknownDash = "-"

$currentDisplay = if ([string]::IsNullOrWhiteSpace($CurrentBranch)) { $unknownDash } else { $CurrentBranch.Trim() }
$changeDisplay = if ($ChangeCount -gt 0) { ([string]$ChangeCount + $filesUnit) } else { $unknownDash }
$bodyText = $reasonShort.Trim()

$cPage = [System.Drawing.Color]::FromArgb(248, 250, 252)
$cHeader = [System.Drawing.Color]::FromArgb(15, 23, 42)
$cAccent = [System.Drawing.Color]::FromArgb(217, 119, 6)
$cInk = [System.Drawing.Color]::FromArgb(15, 23, 42)
$cMuted = [System.Drawing.Color]::FromArgb(100, 116, 139)
$cBorder = [System.Drawing.Color]::FromArgb(226, 232, 240)
$cCard = [System.Drawing.Color]::White
$cOk = [System.Drawing.Color]::FromArgb(22, 163, 74)

$fontUi = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$fontTitle = New-Object System.Drawing.Font("Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold)
$fontSub = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$fontBody = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$fontPrimary = New-Object System.Drawing.Font("Microsoft YaHei UI", 10.5, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:Title
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size(620, 400)
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
$header.Height = 76
$header.BackColor = $cHeader

$iconBox = New-Object System.Windows.Forms.PictureBox
$iconBox.Size = New-Object System.Drawing.Size(32, 32)
$iconBox.Location = New-Object System.Drawing.Point(20, 22)
$iconBox.SizeMode = "StretchImage"
$iconBox.Image = [System.Drawing.SystemIcons]::Warning.ToBitmap()
$header.Controls.Add($iconBox)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Location = New-Object System.Drawing.Point(64, 16)
$titleLabel.Size = New-Object System.Drawing.Size(520, 28)
$titleLabel.Font = $fontTitle
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Text = $script:Title
$titleLabel.BackColor = $cHeader
$header.Controls.Add($titleLabel)

$subLabel = New-Object System.Windows.Forms.Label
$subLabel.Location = New-Object System.Drawing.Point(64, 44)
$subLabel.Size = New-Object System.Drawing.Size(520, 22)
$subLabel.Font = $fontSub
$subLabel.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$subLabel.Text = $headerSub
$subLabel.BackColor = $cHeader
$header.Controls.Add($subLabel)

$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = "Bottom"
$footer.Height = 118
$footer.BackColor = $cPage

$btnCombined = New-Object System.Windows.Forms.Button
$btnCombined.Text = $btnCombinedText
$btnCombined.Size = New-Object System.Drawing.Size(572, 40)
$btnCombined.Location = New-Object System.Drawing.Point(24, 10)
$btnCombined.FlatStyle = "Flat"
$btnCombined.Font = $fontPrimary
$btnCombined.BackColor = $cAccent
$btnCombined.ForeColor = [System.Drawing.Color]::White
$btnCombined.FlatAppearance.BorderSize = 0
$footer.Controls.Add($btnCombined)

$btnStashOnly = New-Object System.Windows.Forms.Button
$btnStashOnly.Text = $btnStashOnlyText
$btnStashOnly.Size = New-Object System.Drawing.Size(220, 34)
$btnStashOnly.Location = New-Object System.Drawing.Point(24, 62)
$btnStashOnly.FlatStyle = "Flat"
$btnStashOnly.BackColor = $cCard
$btnStashOnly.ForeColor = $cInk
$btnStashOnly.FlatAppearance.BorderColor = $cBorder
$footer.Controls.Add($btnStashOnly)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = $btnCancelText
$btnCancel.Size = New-Object System.Drawing.Size(96, 34)
$btnCancel.Location = New-Object System.Drawing.Point(500, 62)
$btnCancel.FlatStyle = "Flat"
$btnCancel.BackColor = $cCard
$btnCancel.ForeColor = $cMuted
$btnCancel.FlatAppearance.BorderColor = $cBorder
$footer.Controls.Add($btnCancel)

$hostPanel = New-Object System.Windows.Forms.Panel
$hostPanel.Dock = "Fill"
$hostPanel.Padding = New-Object System.Windows.Forms.Padding(24, 10, 24, 6)
$hostPanel.BackColor = $cPage

$meta = New-Object System.Windows.Forms.Label
$meta.Dock = "Top"
$meta.Height = 22
$meta.Font = $fontSub
$meta.ForeColor = $cMuted
$meta.Text = ($lblCurrent + $currentDisplay + "    " + $lblChanges + $changeDisplay)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = "Top"
$statusLabel.Height = 24
$statusLabel.Font = $fontSub
$statusLabel.ForeColor = $cAccent
$statusLabel.Text = $statusReady

$body = New-Object System.Windows.Forms.TextBox
$body.Dock = "Fill"
$body.Font = $fontBody
$body.ForeColor = $cInk
$body.BackColor = $cCard
$body.BorderStyle = "FixedSingle"
$body.Multiline = $true
$body.ReadOnly = $true
$body.ScrollBars = "None"
$body.Text = $bodyText
$body.TabStop = $false

$hostPanel.Controls.Add($body)
$hostPanel.Controls.Add($statusLabel)
$hostPanel.Controls.Add($meta)

$form.Controls.Add($hostPanel)
$form.Controls.Add($footer)
$form.Controls.Add($header)
$form.Controls.Add($accent)

$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.AutoPopDelay = 12000
$tooltip.InitialDelay = 400
$tooltip.ReshowDelay = 200
$tooltip.SetToolTip($btnCombined, $tipCombined)
$tooltip.SetToolTip($btnStashOnly, $tipStashOnly)
$tooltip.SetToolTip($btnCancel, $tipCancel)

$script:ActionButtons = @($btnCombined, $btnStashOnly, $btnCancel)
$script:ExitCode = 1

function Set-ActionBusy([bool]$Busy) {
    foreach ($b in $script:ActionButtons) {
        $b.Enabled = -not $Busy
    }
    if ($Busy) {
        $statusLabel.ForeColor = $cMuted
        $statusLabel.Text = $statusBusy
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-StatusOk([string]$Text) {
    $statusLabel.ForeColor = $cOk
    $statusLabel.Text = $Text
}

function Invoke-PullRebase {
    return Invoke-GitInRepo @("pull", "--rebase")
}

function Invoke-StashSync([bool]$PopAfter) {
    Set-ActionBusy $true
    $stash = Invoke-GitInRepo @("stash", "push", "-u", "-m", "ugit-sync")
    if ($stash.Code -ne 0) {
        Set-ActionBusy $false
        Show-Error $errStashPush $stash.Output
        return
    }
    $pull = Invoke-PullRebase
    if ($pull.Code -ne 0) {
        Set-ActionBusy $false
        Show-Error $errPull ($pull.Output + "`r`n`r`n" + $errPullStashKept + "`r`n`r`n" + $conflictHint)
        return
    }
    if ($PopAfter) {
        $pop = Invoke-GitInRepo @("stash", "pop")
        Set-ActionBusy $false
        if ($pop.Code -ne 0) {
            Show-Error $errStashPop ($pop.Output + "`r`n`r`n" + $conflictHint)
            $script:ExitCode = 2
            $btnCancel.Text = $btnCloseDoneText
            return
        }
        Set-StatusOk $statusDoneCombined
    } else {
        Set-ActionBusy $false
        Set-StatusOk $statusDoneStashOnly
    }
    $script:ExitCode = 0
    $btnCombined.Enabled = $false
    $btnStashOnly.Enabled = $false
    $btnCancel.Text = $btnCloseDoneText
}

$btnCancel.Add_Click({
    $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Close()
})

$btnCombined.Add_Click({
    if (-not (Confirm-Action $confirmCombined)) { return }
    Invoke-StashSync $true
})

$btnStashOnly.Add_Click({
    if (-not (Confirm-Action $confirmStashOnly)) { return }
    Invoke-StashSync $false
})

$form.Add_Shown({
    $btnCombined.Focus() | Out-Null
    $btnCombined.Width = [Math]::Max(200, $footer.ClientSize.Width - 48)
    $btnCancel.Left = [Math]::Max(24, $footer.ClientSize.Width - $btnCancel.Width - 24)
})
$form.Add_Resize({
    $btnCombined.Width = [Math]::Max(200, $footer.ClientSize.Width - 48)
    $btnCancel.Left = [Math]::Max(24, $footer.ClientSize.Width - $btnCancel.Width - 24)
})
$form.AcceptButton = $btnCombined
$form.CancelButton = $btnCancel

[void]$form.ShowDialog()
$form.Dispose()
exit $script:ExitCode
