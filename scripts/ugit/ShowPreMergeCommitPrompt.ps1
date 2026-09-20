#Requires -Version 5.1
<#
.SYNOPSIS
  Merge commit blocked: compact UI with primary action and inline feedback.
#>
param(
    [string]$RepoRoot = "",
    [string]$Branch = "",
    [string]$Upstream = "",

    [ValidateSet("PullMerge", "LocalMerge", "Generic")]
    [string]$Kind = "Generic"
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

function Get-GitDir {
    $r = Invoke-GitInRepo @("rev-parse", "--git-dir")
    if ($r.Code -ne 0) { return $null }
    $line = (($r.Output -split "[\r\n]+") | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
    if (-not $line) { return $null }
    $gitDir = $line.Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
        $gitDir = Join-Path $script:RepoRoot $gitDir
    }
    return [System.IO.Path]::GetFullPath($gitDir)
}

function Test-MergeInProgress {
    $gitDir = Get-GitDir
    if (-not $gitDir) { return $false }
    return Test-Path -LiteralPath (Join-Path $gitDir "MERGE_HEAD")
}

function Test-WorkingTreeDirty {
    $r = Invoke-GitInRepo @("status", "--porcelain")
    if ($r.Code -ne 0) { return $false }
    return [bool]($r.Output.Trim())
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

function Invoke-MergeAbort {
    if (-not (Test-MergeInProgress)) {
        return @{ Ok = $true; Skipped = $true; Output = "" }
    }
    $r = Invoke-GitInRepo @("merge", "--abort")
    return @{ Ok = ($r.Code -eq 0); Skipped = $false; Output = $r.Output }
}

function Invoke-PullRebase {
    $r = Invoke-GitInRepo @("pull", "--rebase")
    return @{ Ok = ($r.Code -eq 0); Output = $r.Output }
}

if (-not $RepoRoot) {
    $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}
$script:RepoRoot = (($RepoRoot -split "[\r\n]+")[0]).Trim()

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Title = Decode-Utf8B64 "5o6o6YCB5YmN5qOA5rWL"
$script:FailTitle = Decode-Utf8B64 "5ZG95Luk5omn6KGM5aSx6LSl"
$headerSub = Decode-Utf8B64 "5bey6Zi75q2iIG1lcmdlIGNvbW1pdA=="
$reasonShort = Decode-Utf8B64 "5pys5LuT5bqT55SoIHJlYmFzZSDlkIzmraXliIbmlK/vvIzkuI3kvb/nlKggbWVyZ2UgY29tbWl077yI6YG/5YWN5Ye6546wIE1lcmdlIGJyYW5jaCAuLi7vvInjgII="
$nextPullMerge = Decode-Utf8B64 "5o6o6I2Q77ya5Y+W5raI5pys5qyhIG1lcmdl77yM5YaN55SoIHJlYmFzZSDmi4nlj5bov5znq6/jgII="
$nextLocalMerge = Decode-Utf8B64 "5o6o6I2Q77ya5YWI5Y+W5raI5pys5qyhIG1lcmdl77yb6Iul6ZyA5ZCM5q2l6L+c56uv5YaN54K5IHJlYmFzZSDmi4nlj5bjgII="
$nextGeneric = Decode-Utf8B64 "5o6o6I2Q77ya5Y+W5raIIG1lcmdlIOWQjuaUueeUqCByZWJhc2Ug5ZCM5q2l44CC"
$noteConflict = Decode-Utf8B64 "cmViYXNlIOiLpeWGsueqge+8muaUueaWh+S7tiDihpIgZ2l0IGFkZCDigKYg4oaSIGdpdCByZWJhc2UgLS1jb250aW51ZQ=="
$noteMore = Decode-Utf8B64 "5o6o6YCB5LuN5YiG5Y+J5pe25oyJIHByZS1wdXNoIOW8ueeql+WkhOeQhu+8m+mikee5geWHuueOsOivt+mHjeaWsOi/kOihjOWuieijheiEmuacrOOAgg=="
$lblBranch = Decode-Utf8B64 "5YiG5pSv77ya"
$lblUpstream = Decode-Utf8B64 "5LiK5ri477ya"
$btnCombinedText = Decode-Utf8B64 "5LiA6ZSu77ya5Y+W5raIIG1lcmdlIOW5tiByZWJhc2Ug5ouJ5Y+W"
$btnAbortText = Decode-Utf8B64 "5LuF5Y+W5raIIG1lcmdl"
$btnPullRebaseText = Decode-Utf8B64 "5LuFIHJlYmFzZSDmi4nlj5Y="
$btnStashText = Decode-Utf8B64 "c3Rhc2gg5ZCOIHJlYmFzZQ=="
$btnCloseText = Decode-Utf8B64 "56iN5ZCO5omL5Yqo"
$btnCloseDoneText = Decode-Utf8B64 "5a6M5oiQ5bm25YWz6Zet"
$lblDirty = Decode-Utf8B64 "5qOA5rWL5Yiw5pyq5o+Q5Lqk5pS55YqoIOKAlCDlj6/kvJjlhYjnlKggc3Rhc2gg5ZCOIHJlYmFzZQ=="
$tipCombined = Decode-Utf8B64 "5L6d5qyh5omn6KGMIG1lcmdlIC0tYWJvcnQg5LiOIHB1bGwgLS1yZWJhc2XvvIjmnIDluLjnlKjvvIk="
$tipAbort = Decode-Utf8B64 "5LuF5pKk6ZSAIG1lcmdl77yM5L+d55WZ5b2T5YmN5YiG5pSv54q25oCB"
$tipPull = Decode-Utf8B64 "bWVyZ2Ug5bey5Y+W5raI5ZCO77yM5ouJ5Y+W6L+c56uv5bm2IHJlYmFzZQ=="
$tipPullDisabled = Decode-Utf8B64 "6K+35YWI5Y+W5raIIG1lcmdl77yM5oiW54K55LiK5pa55LiA6ZSu5oyJ6ZKu"
$tipStash = Decode-Utf8B64 "5pqC5a2Y5pyq5o+Q5Lqk5pS55YqoIOKGkiDlj5bmtoggbWVyZ2Ug4oaSIHB1bGwgLS1yZWJhc2Ug4oaSIOaBouWkjeaUueWKqA=="
$tipClose = Decode-Utf8B64 "5YWz6Zet56qX5Y+j77yM56iN5ZCO5Zyo57uI56uv6Ieq6KGM5aSE55CG"
$statusBusy = Decode-Utf8B64 "5q2j5Zyo5omn6KGM77yM6K+356iN5YCZ4oCm"
$statusMerging = Decode-Utf8B64 "54q25oCB77yabWVyZ2Ug6L+b6KGM5LitIOKAlCDor7flhYjlj5bmtoggbWVyZ2U="
$statusReady = Decode-Utf8B64 "54q25oCB77yabWVyZ2Ug5bey5Y+W5raIIOKAlCDlj68gcHVsbCAtLXJlYmFzZQ=="
$statusIdle = Decode-Utf8B64 "54q25oCB77ya5pyq5ZyoIG1lcmdlIOS4rSDigJQg5Y+v55u05o6lIHB1bGwgLS1yZWJhc2U="
$statusDoneAbort = Decode-Utf8B64 "bWVyZ2Ug5bey5Y+W5raI44CC5Y+v54K544CM5LuFIHJlYmFzZSDmi4nlj5bjgI3miJbjgIzkuIDplK7jgI3nu6fnu63jgII="
$statusDonePull = Decode-Utf8B64 "5bey5a6M5oiQ77yacHVsbCAtLXJlYmFzZSDmiJDlip/jgII="
$statusDoneCombined = Decode-Utf8B64 "5bey5a6M5oiQ77yabWVyZ2Ug5bey5Y+W5raI77yMcHVsbCAtLXJlYmFzZSDmiJDlip/jgILlj6/lhbPpl63nqpflj6Pnu6fnu63lt6XkvZzjgII="
$statusDoneStash = Decode-Utf8B64 "5bey5a6M5oiQ77yac3Rhc2gg4oaSIHJlYmFzZSDihpIgc3Rhc2ggcG9w44CC"
$confirmCombined = Decode-Utf8B64 "5bCG5L6d5qyh5omn6KGM77yaCjEuIGdpdCBtZXJnZSAtLWFib3J0CjIuIGdpdCBwdWxsIC0tcmViYXNlCgrmmK/lkKbnu6fnu63vvJ8="
$confirmAbort = Decode-Utf8B64 "5bCG5omn6KGMIGdpdCBtZXJnZSAtLWFib3J077yM5piv5ZCm57un57ut77yf"
$confirmPullRebase = Decode-Utf8B64 "5bCG5omn6KGMIGdpdCBwdWxsIC0tcmViYXNl77yM5piv5ZCm57un57ut77yf"
$confirmStash = Decode-Utf8B64 "5bCG5L6d5qyh5omn6KGM77yaCjEuIGdpdCBzdGFzaCBwdXNoIC11IC1tIHVnaXQtcHJlbWVyZ2UKMi4gZ2l0IG1lcmdlIC0tYWJvcnTvvIjoi6Xku43lnKggbWVyZ2Ug5Lit77yJCjMuIGdpdCBwdWxsIC0tcmViYXNlCjQuIGdpdCBzdGFzaCBwb3AKCuaYr+WQpue7p+e7re+8nw=="
$needAbortFirst = Decode-Utf8B64 "5b2T5YmN5LuN5ZyoIG1lcmdlIOS4re+8jOivt+WFiOOAjOWPlua2iCBtZXJnZeOAjeaIlueCueOAjGFib3J0IOW5tiByZWJhc2Ug5ouJ5Y+W44CN44CC"
$conflictHint = Decode-Utf8B64 "6IulIHJlYmFzZSDlhrLnqoHvvJrmlLnmlofku7Yg4oaSIGdpdCBhZGQg4oCmIOKGkiBnaXQgcmViYXNlIC0tY29udGludWU="
$errAbort = Decode-Utf8B64 "Z2l0IG1lcmdlIC0tYWJvcnQg5aSx6LSl"
$errPull = Decode-Utf8B64 "Z2l0IHB1bGwgLS1yZWJhc2Ug5aSx6LSl"
$errStashPush = Decode-Utf8B64 "Z2l0IHN0YXNoIHB1c2gg5aSx6LSl"
$errAbortStashKept = Decode-Utf8B64 "Z2l0IG1lcmdlIC0tYWJvcnQg5aSx6LSl77yIc3Rhc2gg5bey5L+d5a2Y77yM5Y+v55SoIGdpdCBzdGFzaCBwb3Ag5oGi5aSN77yJ"
$errPullStashKept = Decode-Utf8B64 "Z2l0IHB1bGwgLS1yZWJhc2Ug5aSx6LSl77yIc3Rhc2gg5LuN5L+d55WZ77yM5Y+v55SoIGdpdCBzdGFzaCBwb3Ag5oGi5aSN77yJ"
$errStashPop = Decode-Utf8B64 "Z2l0IHN0YXNoIHBvcCDlpLHotKXvvIhyZWJhc2Ug5bey5a6M5oiQ77yM6K+35omL5YqoIGdpdCBzdGFzaCBwb3DvvIk="

if ($Kind -eq "PullMerge") {
    $scene = Decode-Utf8B64 "5qOA5rWL5Yiw77yaZ2l0IHB1bGwg5q2j5Zyo5Yib5bu6IG1lcmdlIGNvbW1pdA=="
    $nextStep = $nextPullMerge
} elseif ($Kind -eq "LocalMerge") {
    $scene = Decode-Utf8B64 "5qOA5rWL5Yiw77yaZ2l0IG1lcmdlIOato+WcqOWIm+W7uiBtZXJnZSBjb21taXQ="
    $nextStep = $nextLocalMerge
} else {
    $scene = Decode-Utf8B64 "5qOA5rWL5Yiw77ya5q2j5Zyo5Yib5bu6IG1lcmdlIGNvbW1pdA=="
    $nextStep = $nextGeneric
}

$bodyParts = New-Object System.Collections.Generic.List[string]
[void]$bodyParts.Add($reasonShort.Trim())
[void]$bodyParts.Add("")
[void]$bodyParts.Add($scene.Trim())
[void]$bodyParts.Add($nextStep.Trim())
[void]$bodyParts.Add("")
[void]$bodyParts.Add($noteConflict.Trim())
[void]$bodyParts.Add($noteMore.Trim())
$bodyText = [string]::Join("`r`n", $bodyParts.ToArray())

$cPage = [System.Drawing.Color]::FromArgb(248, 250, 252)
$cHeader = [System.Drawing.Color]::FromArgb(15, 23, 42)
$cAccent = [System.Drawing.Color]::FromArgb(217, 119, 6)
$cInk = [System.Drawing.Color]::FromArgb(15, 23, 42)
$cMuted = [System.Drawing.Color]::FromArgb(100, 116, 139)
$cBorder = [System.Drawing.Color]::FromArgb(226, 232, 240)
$cCard = [System.Drawing.Color]::White
$cOk = [System.Drawing.Color]::FromArgb(22, 163, 74)
$cDirtyBg = [System.Drawing.Color]::FromArgb(255, 251, 235)
$cDirtyBorder = [System.Drawing.Color]::FromArgb(251, 191, 36)

$fontUi = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$fontTitle = New-Object System.Drawing.Font("Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold)
$fontSub = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$fontBody = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$fontPrimary = New-Object System.Drawing.Font("Microsoft YaHei UI", 10.5, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:Title
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size(620, 460)
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

$btnAbort = New-Object System.Windows.Forms.Button
$btnAbort.Text = $btnAbortText
$btnAbort.Size = New-Object System.Drawing.Size(118, 34)
$btnAbort.Location = New-Object System.Drawing.Point(24, 62)
$btnAbort.FlatStyle = "Flat"
$btnAbort.BackColor = $cCard
$btnAbort.ForeColor = $cInk
$btnAbort.FlatAppearance.BorderColor = $cBorder
$footer.Controls.Add($btnAbort)

$btnPullRebase = New-Object System.Windows.Forms.Button
$btnPullRebase.Text = $btnPullRebaseText
$btnPullRebase.Size = New-Object System.Drawing.Size(118, 34)
$btnPullRebase.Location = New-Object System.Drawing.Point(150, 62)
$btnPullRebase.FlatStyle = "Flat"
$btnPullRebase.BackColor = $cCard
$btnPullRebase.ForeColor = $cInk
$btnPullRebase.FlatAppearance.BorderColor = $cBorder
$footer.Controls.Add($btnPullRebase)

$btnStash = New-Object System.Windows.Forms.Button
$btnStash.Text = $btnStashText
$btnStash.Size = New-Object System.Drawing.Size(128, 34)
$btnStash.Location = New-Object System.Drawing.Point(276, 62)
$btnStash.FlatStyle = "Flat"
$btnStash.BackColor = $cCard
$btnStash.ForeColor = $cInk
$btnStash.FlatAppearance.BorderColor = $cBorder
$footer.Controls.Add($btnStash)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = $btnCloseText
$btnClose.Size = New-Object System.Drawing.Size(96, 34)
$btnClose.Location = New-Object System.Drawing.Point(500, 62)
$btnClose.FlatStyle = "Flat"
$btnClose.BackColor = $cCard
$btnClose.ForeColor = $cMuted
$btnClose.FlatAppearance.BorderColor = $cBorder
$footer.Controls.Add($btnClose)

$hostPanel = New-Object System.Windows.Forms.Panel
$hostPanel.Dock = "Fill"
$hostPanel.Padding = New-Object System.Windows.Forms.Padding(24, 10, 24, 6)
$hostPanel.BackColor = $cPage

$meta = New-Object System.Windows.Forms.Label
$meta.Dock = "Top"
$meta.Height = 22
$meta.Font = $fontSub
$meta.ForeColor = $cMuted
$metaParts = New-Object System.Collections.Generic.List[string]
if ($Branch) { [void]$metaParts.Add($lblBranch + $Branch) }
if ($Upstream) { [void]$metaParts.Add($lblUpstream + $Upstream) }
$meta.Text = [string]::Join("    ", $metaParts.ToArray())

$dirtyBanner = New-Object System.Windows.Forms.Label
$dirtyBanner.Dock = "Top"
$dirtyBanner.Height = 28
$dirtyBanner.Font = $fontSub
$dirtyBanner.ForeColor = $cAccent
$dirtyBanner.BackColor = $cDirtyBg
$dirtyBanner.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$dirtyBanner.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
$dirtyBanner.Visible = $false

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = "Top"
$statusLabel.Height = 24
$statusLabel.Font = $fontSub
$statusLabel.ForeColor = $cAccent

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
$hostPanel.Controls.Add($dirtyBanner)
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
$tooltip.SetToolTip($btnAbort, $tipAbort)
$tooltip.SetToolTip($btnStash, $tipStash)
$tooltip.SetToolTip($btnClose, $tipClose)

$script:ActionButtons = @($btnCombined, $btnAbort, $btnPullRebase, $btnStash, $btnClose)

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

function Set-StatusWarn([string]$Text) {
    $statusLabel.ForeColor = $cAccent
    $statusLabel.Text = $Text
}

function Update-UiState {
    $merging = Test-MergeInProgress
    $dirty = Test-WorkingTreeDirty

    $dirtyBanner.Visible = $dirty
    if ($dirty) {
        $dirtyBanner.Text = "  " + $lblDirty
        $btnStash.FlatAppearance.BorderColor = $cDirtyBorder
        $btnStash.Font = $fontPrimary
    } else {
        $btnStash.FlatAppearance.BorderColor = $cBorder
        $btnStash.Font = $fontUi
    }

    if ($merging) {
        Set-StatusWarn $statusMerging
        $btnAbort.Enabled = $true
        $btnPullRebase.Enabled = $false
        $tooltip.SetToolTip($btnPullRebase, $tipPullDisabled)
    } else {
        if ($statusLabel.ForeColor -ne $cOk) {
            Set-StatusWarn $statusReady
        }
        $btnAbort.Enabled = $false
        $btnPullRebase.Enabled = $true
        $tooltip.SetToolTip($btnPullRebase, $tipPull)
    }

    $btnCombined.Enabled = $true
    $btnStash.Enabled = $true
    $btnClose.Enabled = $true
}

function Layout-FooterButtons {
    $w = $footer.ClientSize.Width
    $btnCombined.Width = [Math]::Max(200, $w - 48)
    $btnClose.Left = [Math]::Max(24, $w - $btnClose.Width - 24)
    $btnStash.Left = [Math]::Max(276, $btnClose.Left - $btnStash.Width - 10)
}

$btnClose.Add_Click({
    $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Close()
})

$btnAbort.Add_Click({
    if (-not (Test-MergeInProgress)) {
        Set-StatusWarn $statusIdle
        return
    }
    if (-not (Confirm-Action $confirmAbort)) { return }
    Set-ActionBusy $true
    $r = Invoke-MergeAbort
    Set-ActionBusy $false
    if ($r.Ok) {
        Set-StatusOk $statusDoneAbort
        Update-UiState
    } else {
        Show-Error $errAbort $r.Output
        Update-UiState
    }
})

$btnPullRebase.Add_Click({
    if (Test-MergeInProgress) {
        Set-StatusWarn $needAbortFirst
        return
    }
    if (-not (Confirm-Action $confirmPullRebase)) { return }
    Set-ActionBusy $true
    $r = Invoke-PullRebase
    Set-ActionBusy $false
    if ($r.Ok) {
        Set-StatusOk ($statusDonePull + " " + $noteConflict)
        $btnClose.Text = $btnCloseDoneText
    } else {
        Show-Error $errPull ($r.Output + "`r`n`r`n" + $conflictHint)
        Update-UiState
    }
})

$btnCombined.Add_Click({
    if (-not (Confirm-Action $confirmCombined)) { return }
    Set-ActionBusy $true
    if (Test-MergeInProgress) {
        $abort = Invoke-MergeAbort
        if (-not $abort.Ok) {
            Set-ActionBusy $false
            Show-Error $errAbort $abort.Output
            Update-UiState
            return
        }
    }
    $pull = Invoke-PullRebase
    Set-ActionBusy $false
    if ($pull.Ok) {
        Set-StatusOk $statusDoneCombined
        $btnClose.Text = $btnCloseDoneText
        $btnCombined.Enabled = $false
        $btnAbort.Enabled = $false
        $btnPullRebase.Enabled = $false
        $btnStash.Enabled = $false
    } else {
        Show-Error $errPull ($pull.Output + "`r`n`r`n" + $conflictHint)
        Update-UiState
    }
})

$btnStash.Add_Click({
    if (-not (Confirm-Action $confirmStash)) { return }
    Set-ActionBusy $true
    $stash = Invoke-GitInRepo @("stash", "push", "-u", "-m", "ugit-premerge")
    if ($stash.Code -ne 0) {
        Set-ActionBusy $false
        Show-Error $errStashPush $stash.Output
        return
    }
    if (Test-MergeInProgress) {
        $abort = Invoke-MergeAbort
        if (-not $abort.Ok) {
            Set-ActionBusy $false
            Show-Error $errAbortStashKept $abort.Output
            return
        }
    }
    $pull = Invoke-PullRebase
    if (-not $pull.Ok) {
        Set-ActionBusy $false
        Show-Error $errPullStashKept ($pull.Output + "`r`n`r`n" + $conflictHint)
        Update-UiState
        return
    }
    $pop = Invoke-GitInRepo @("stash", "pop")
    Set-ActionBusy $false
    if ($pop.Code -ne 0) {
        Show-Error $errStashPop ($pop.Output + "`r`n`r`n" + $conflictHint)
        $btnClose.Text = $btnCloseDoneText
        return
    }
    Set-StatusOk $statusDoneStash
    $btnClose.Text = $btnCloseDoneText
    $btnCombined.Enabled = $false
    $btnAbort.Enabled = $false
    $btnPullRebase.Enabled = $false
    $btnStash.Enabled = $false
})

$form.Add_Shown({
    Update-UiState
    Layout-FooterButtons
    $btnCombined.Focus() | Out-Null
})
$form.Add_Resize({ Layout-FooterButtons })
$form.AcceptButton = $btnCombined
$form.CancelButton = $btnClose

[void]$form.ShowDialog()
$form.Dispose()
exit 0
