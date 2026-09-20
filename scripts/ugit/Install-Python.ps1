#Requires -Version 5.1
<#
.SYNOPSIS
  One-click install Python 3 + openpyxl for config table build.
.DESCRIPTION
  1) If Python >= 3.10 exists: only ensure openpyxl (skip 3.9 and older).
  2) Else try winget (Python.Python.3.12 user scope).
  3) Else download official python.org amd64 installer and silent-install (user, PrependPath).
  4) Then pip install openpyxl.
#>
param(
    [switch]$NoPause
)

$ErrorActionPreference = "Continue"

# Pinned official installer (user-scope, no admin required in normal cases).
$PythonVersion = "3.12.10"
$PythonInstallerUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe"
# Must match ExcelToLua.py / BuildConfig.ps1 (Path.write_text newline= needs 3.10+).
$script:MinPythonMajor = 3
$script:MinPythonMinor = 10

function Write-Step([string]$Message) {
    Write-Host "[Install-Python] $Message"
}

function Refresh-Path {
    $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machine, $user | Where-Object { $_ }) -join ";"
}

function Invoke-NativeOk {
    param(
        [string]$Exe,
        [string[]]$Prefix,
        [string]$Code
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = & $Exe @Prefix -c $Code 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-PythonVersionLabel {
    param(
        [string]$Exe,
        [string[]]$Prefix
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $Exe @Prefix -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        $line = @($out) | Where-Object { $_ -match '^\d+\.\d+$' } | Select-Object -Last 1
        if ($line) { return [string]$line }
        return $null
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-PythonVersionOk([string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Label)) { return $false }
    $parts = $Label.Split('.')
    if ($parts.Count -lt 2) { return $false }
    $maj = 0
    $min = 0
    if (-not [int]::TryParse($parts[0], [ref]$maj)) { return $false }
    if (-not [int]::TryParse($parts[1], [ref]$min)) { return $false }
    if ($maj -gt $script:MinPythonMajor) { return $true }
    if ($maj -lt $script:MinPythonMajor) { return $false }
    return ($min -ge $script:MinPythonMinor)
}

function Try-PythonCandidate {
    param(
        [string]$Exe,
        [string[]]$Prefix
    )
    if ([string]::IsNullOrWhiteSpace($Exe)) { return $null }
    if ($Exe -match '(?i)\\WindowsApps\\') { return $null }
    if (-not (Invoke-NativeOk $Exe $Prefix "import sys")) { return $null }
    $ver = Get-PythonVersionLabel $Exe $Prefix
    if (-not (Test-PythonVersionOk $ver)) {
        $label = if ($ver) { $ver } else { "?" }
        $need = "{0}.{1}" -f $script:MinPythonMajor, $script:MinPythonMinor
        Write-Step ("skip Python {0} (need >={1}): {2}" -f $label, $need, $Exe)
        return $null
    }
    return @{ Exe = $Exe; Prefix = $Prefix; Ver = $ver }
}

function Test-PythonReady {
    Refresh-Path
    $pyCmd = Get-Command py -ErrorAction SilentlyContinue
    if ($pyCmd -and $pyCmd.Source -and ($pyCmd.Source -notmatch '(?i)\\WindowsApps\\')) {
        foreach ($tag in @("-3.13", "-3.12", "-3.11", "-3.10", "-3")) {
            $hit = Try-PythonCandidate $pyCmd.Source @($tag)
            if ($hit) { return $hit }
        }
    }
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd -and $pythonCmd.Source) {
        $hit = Try-PythonCandidate ([string]$pythonCmd.Source) @()
        if ($hit) { return $hit }
    }
    $guesses = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
    )
    foreach ($g in $guesses) {
        if (Test-Path -LiteralPath $g) {
            $hit = Try-PythonCandidate $g @()
            if ($hit) { return $hit }
        }
    }
    $localRoot = Join-Path $env:LOCALAPPDATA "Programs\Python"
    if (Test-Path -LiteralPath $localRoot) {
        $dirs = @(Get-ChildItem -LiteralPath $localRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "Python*" } |
            Sort-Object Name -Descending)
        foreach ($dir in $dirs) {
            $exe = Join-Path $dir.FullName "python.exe"
            if (Test-Path -LiteralPath $exe) {
                $hit = Try-PythonCandidate $exe @()
                if ($hit) { return $hit }
            }
        }
    }
    return $null
}

function Install-OpenpyxlFor([hashtable]$Py) {
    Write-Step "pip install openpyxl ..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = & $Py.Exe @($Py.Prefix) -m pip install --disable-pip-version-check openpyxl 2>&1
        if ($LASTEXITCODE -ne 0) {
            $null = & $Py.Exe @($Py.Prefix) -m pip install --user --disable-pip-version-check openpyxl 2>&1
        }
    } catch {}
    finally {
        $ErrorActionPreference = $prev
    }
    return (Invoke-NativeOk $Py.Exe $Py.Prefix "import openpyxl")
}

function Install-PythonViaWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Step "winget not found, skip."
        return $false
    }
    Write-Step "winget install Python.Python.3.12 (user scope) ..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $winget.Source install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Step "winget exit=$LASTEXITCODE, trying Python.Python.3.11 ..."
        & $winget.Source install -e --id Python.Python.3.11 --scope user --accept-package-agreements --accept-source-agreements
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Step ("winget failed: " + $_.Exception.Message)
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Install-PythonViaOfficialInstaller {
    Write-Step "Downloading official installer:"
    Write-Step "  $PythonInstallerUrl"
    $tmpDir = Join-Path $env:TEMP "ugit-python-setup"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $installer = Join-Path $tmpDir ("python-{0}-amd64.exe" -f $PythonVersion)

    try {
        # TLS 1.2 for older PowerShell / corporate defaults
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {}

        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L --fail --retry 3 --retry-delay 2 -o $installer $PythonInstallerUrl
            if (($LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $installer)) {
                throw "curl download failed exit=$LASTEXITCODE"
            }
        } else {
            Invoke-WebRequest -Uri $PythonInstallerUrl -OutFile $installer -UseBasicParsing
        }
    } catch {
        Write-Step ("Download failed: " + $_.Exception.Message)
        return $false
    }

    $size = (Get-Item -LiteralPath $installer).Length
    if ($size -lt 1MB) {
        Write-Step "Downloader file too small ($size bytes), abort."
        return $false
    }
    Write-Step ("Downloaded OK ({0:N1} MB)" -f ($size / 1MB))

    # Silent per-user install + add to PATH + pip + launcher
    $args = @(
        "/quiet",
        "InstallAllUsers=0",
        "PrependPath=1",
        "Include_pip=1",
        "Include_launcher=1",
        "Include_test=0",
        "SimpleInstall=1"
    )
    Write-Step "Running silent installer (may take 1-2 minutes)..."
    try {
        $p = Start-Process -FilePath $installer -ArgumentList $args -Wait -PassThru
        Write-Step ("Installer exit=$($p.ExitCode)")
        # 0 = success; 3010 = success reboot required (still OK for us)
        if (($p.ExitCode -ne 0) -and ($p.ExitCode -ne 3010)) {
            return $false
        }
        return $true
    } catch {
        Write-Step ("Installer failed: " + $_.Exception.Message)
        return $false
    }
}

Write-Step start
Write-Step ("need Python >={0}.{1} (will install {2} if missing)" -f $script:MinPythonMajor, $script:MinPythonMinor, $PythonVersion)

$existing = Test-PythonReady
if ($existing) {
    $verText = if ($existing.Ver) { " $($existing.Ver)" } else { "" }
    Write-Step ("Python already found{0}: {1}" -f $verText, $existing.Exe)
    if (Install-OpenpyxlFor $existing) {
        Write-Step "OK. Please retry your git commit."
        if (-not $NoPause) { pause }
        exit 0
    }
    Write-Step "openpyxl install failed."
    if (-not $NoPause) { pause }
    exit 1
}

Write-Step ("No Python >={0}.{1} found, installing {2} ..." -f $script:MinPythonMajor, $script:MinPythonMinor, $PythonVersion)

$installed = Install-PythonViaWinget
if (-not $installed) {
    Write-Step "Falling back to official python.org installer..."
    $installed = Install-PythonViaOfficialInstaller
}

Refresh-Path
Start-Sleep -Seconds 2
$py = Test-PythonReady

# Installer just finished: PATH refresh sometimes lags; probe known path again
if (-not $py) {
    Start-Sleep -Seconds 2
    Refresh-Path
    $py = Test-PythonReady
}

if (-not $py) {
    Write-Step "Python still not found after install."
    Write-Step "Opening download page as last resort..."
    try { Start-Process "https://www.python.org/downloads/windows/" } catch {}
    Write-Host ""
    Write-Host "Please install Python $PythonVersion+ manually,"
    Write-Host "CHECK 'Add python.exe to PATH', then re-run this script."
    Write-Host ""
    if (-not $NoPause) { pause }
    exit 1
}

Write-Step "Python ready: $($py.Exe) $($py.Ver)"
if (-not (Install-OpenpyxlFor $py)) {
    Write-Step "openpyxl install failed. Run scripts\ugit\2-安装Python环境.bat"
    if (-not $NoPause) { pause }
    exit 1
}

Write-Step "OK. Please close the alert and retry your git commit."
if (-not $NoPause) { pause }
exit 0
