#Requires -Version 5.1
<#
.SYNOPSIS
  Config table build: Excel -> ConfigInstance / Language (no CSV), then sync to src.

.DESCRIPTION
  Framework mode (default):
    Input:  config/*.xlsx, config/Localization/*.xlsx
    Output: config/.build/ConfigInstance.lua, Language.lua
    Sync:   src/.../ConfigInstance.luau, Language.luau

  Work mode:
    -Mode Work -ExcelDir <dir> [-LocalizationDir <dir>]
    Or -ProjectName with pack-tool Work/<Project>/Excel if pack-tool exists.

  Scalar number empty cells abort the build; number[] empty becomes {}.
#>
param(
    [string]$RepoRoot = "",
    [ValidateSet("Framework", "Work")]
    [string]$Mode = "Framework",
    [string]$ProjectName = "",
    [string]$ExcelDir = "",
    [string]$LocalizationDir = "",
    [switch]$SkipLanguage,
    [switch]$NoCopyToSrc,
    [switch]$CopyToSrc
)

$ErrorActionPreference = "Stop"

if ($env:UGIT_NO_COPY_TO_SRC -eq "1") {
    $NoCopyToSrc = $true
}

function Write-Info([string]$Message) {
    Write-Host "[BuildConfig] $Message"
}

function Find-RepoRoot([string]$Start) {
    $seeds = @()
    if ($Start) { $seeds += $Start }
    if ($PSScriptRoot) { $seeds += $PSScriptRoot }
    $seeds += (Get-Location).Path

    foreach ($seed in $seeds) {
        $dir = [System.IO.Path]::GetFullPath($seed)
        while ($true) {
            $cfg = Join-Path $dir "config"
            $script = Join-Path $dir "scripts\ugit\ExcelToLua.py"
            if ((Test-Path -LiteralPath $cfg) -and (Test-Path -LiteralPath $script)) {
                return $dir
            }
            $parent = Split-Path $dir -Parent
            if (-not $parent -or $parent -eq $dir) { break }
            $dir = $parent
        }
    }
    throw "Repo root not found (need config/ and scripts/ugit/ExcelToLua.py). Pass -RepoRoot."
}

function Write-HookErrorFile([string]$Message, [string]$Kind = "") {
    $errPath = Join-Path $PSScriptRoot "precommit-last-error.txt"
    $kindPath = Join-Path $PSScriptRoot "precommit-last-error.kind"
    try {
        $utf8bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($errPath, ($Message.Trim() + "`r`n"), $utf8bom)
        if ($Kind) {
            [System.IO.File]::WriteAllText($kindPath, ($Kind.Trim() + "`r`n"), [System.Text.Encoding]::ASCII)
        } elseif (Test-Path -LiteralPath $kindPath) {
            Remove-Item -LiteralPath $kindPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Test-PythonOpenpyxl([string]$Exe, [string[]]$Prefix) {
    return (Invoke-PythonProbe $Exe $Prefix "import openpyxl")
}

# ExcelToLua.py uses Path.write_text(..., newline=) which needs 3.10+.
$script:MinPythonMajor = 3
$script:MinPythonMinor = 10

function Invoke-PythonProbe([string]$Exe, [string[]]$Prefix, [string]$Code) {
    # Native stderr (e.g. py launcher "No installed Python") must not abort under Stop.
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

function Get-PythonVersionLabel([string]$Exe, [string[]]$Prefix) {
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

function Try-InstallOpenpyxl([string]$Exe, [string[]]$Prefix) {
    Write-Info "openpyxl not found, auto-installing via pip..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = & $Exe @Prefix -m pip install --disable-pip-version-check openpyxl 2>&1
        if ($LASTEXITCODE -ne 0) {
            $null = & $Exe @Prefix -m pip install --user --disable-pip-version-check openpyxl 2>&1
        }
    } catch {}
    finally {
        $ErrorActionPreference = $prev
    }
    return (Test-PythonOpenpyxl $Exe $Prefix)
}

function Decode-Utf8B64([string]$Text) {
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Fail-MissingPython([string]$Kind, [string]$Diag = "") {
    $installBat = Join-Path $PSScriptRoot "Install-Python.bat"
    $head = Decode-Utf8B64 "6YWN572u5qCh6aqM5aSx6LSl77yM5o+Q5Lqk5bey5Lit5q2i44CCCgrljp/lm6A6IOacrOacuue8uuWwkeaJk+ihqOeOr+Wig++8iFB5dGhvbiArIG9wZW5weXhs77yJ44CCCg=="
    if ($Kind -eq "PythonTooOld") {
        $head = Decode-Utf8B64 "6YWN572u5qCh6aqM5aSx6LSl77yM5o+Q5Lqk5bey5Lit5q2i44CCCgrljp/lm6A6IFB5dGhvbiDniYjmnKzov4fkvY7vvIjpnIDopoEgMy4xMCDmiJbku6XkuIrvvInjgIIK"
        $body = Decode-Utf8B64 "5bey5qOA5rWL5YiwIFB5dGhvbu+8jOS9hueJiOacrOS9juS6jiAzLjEw77yI5omT6KGo6ZyA6KaBIDMuMTAr77yM5L6L5aaCIFBBVEgg5LiK55qEIDMuOSDkvJrooqvot7Pov4fvvInjgIIKCuivt+eCueS4i+aWuee7v+iJsuaMiemSruOAjOS4gOmUruWuieijhSBQeXRob27jgI3vvIjmjqjojZDlronoo4UgMy4xMu+8ieOAggrmiJbmiYvliqjov5DooYzvvJoKICBzY3JpcHRzXHVnaXRcMi3lronoo4VQeXRob27njq/looMuYmF0Cgrlronoo4XlrozmiJDlkI7lhbPpl63lvLnnqpflho3ph43mlrDmj5DkuqTjgII="
    } elseif ($Kind -eq "NoPython") {
        $body = Decode-Utf8B64 "5pyq5qOA5rWL5Yiw5Y+v55So55qEIFB5dGhvbuOAggoK6K+354K55Ye75LiL5pa557u/6Imy5oyJ6ZKu44CM5LiA6ZSu5a6J6KOFIFB5dGhvbuOAje+8iOmcgOiBlOe9ke+8ieOAggrmiJblj4zlh7vov5DooYzvvJoKICBzY3JpcHRzXHVnaXRcMi3lronoo4VQeXRob27njq/looMuYmF0Cgrlronoo4XlrozmiJDlkI7lhbPpl63mnKznqpflj6PvvIzph43mlrDmj5DkuqTljbPlj6/jgII="
    } else {
        $body = Decode-Utf8B64 "5bey5om+5YiwIFB5dGhvbu+8jOS9huacquWuieijhSBvcGVucHl4bO+8iOaIluiHquWKqOWuieijheWksei0pe+8ieOAggoK6K+354K55Ye75LiL5pa557u/6Imy5oyJ6ZKu44CM5LiA6ZSu5a6J6KOFIG9wZW5weXhs44CN44CCCuaIluWPjOWHu+i/kOihjO+8mgogIHNjcmlwdHNcdWdpdFwyLeWuieijhVB5dGhvbueOr+Wigy5iYXQKCuWuieijheWujOaIkOWQjuWFs+mXreacrOeql+WPo++8jOmHjeaWsOaPkOS6pOWNs+WPr+OAgg=="
    }
    $msg = $head + "`r`n" + $body
    if (Test-Path -LiteralPath $installBat) {
        $msg = $msg + "`r`n`r`n" + (Decode-Utf8B64 "5a6J6KOF6ISa5pys6Lev5b6EOiA=") + $installBat
    }
    if (-not [string]::IsNullOrWhiteSpace($Diag)) {
        $msg = $msg + "`r`n`r`n[diag]`r`n" + $Diag.Trim()
    }
    Write-HookErrorFile $msg $Kind
    Write-Host "[BuildConfig][ERROR]" -ForegroundColor Red
    Write-Host $msg -ForegroundColor Red
    exit 1
}

function Refresh-Path {
    # Git hooks often inherit a stale/minimal PATH; merge Machine+User so user-scope Python is visible.
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machinePath, $userPath | Where-Object { $_ }) -join ";"
}

function Add-PythonCandidate {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )
    # Do NOT pipe empty Get-Command | ExpandProperty (AutomationNull) through Where-Object:
    # in Windows PowerShell 5.1, two+ AutomationNulls can collapse the whole candidate list.
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ($Path -match '(?i)\\WindowsApps\\') { return }
    $List.Add($Path)
}

function Add-PythonCandidatesFromDir {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$RootDir
    )
    if ([string]::IsNullOrWhiteSpace($RootDir)) { return }
    if (-not (Test-Path -LiteralPath $RootDir)) { return }
    Get-ChildItem -LiteralPath $RootDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "Python*" } |
        Sort-Object Name -Descending |
        ForEach-Object {
            Add-PythonCandidate $List (Join-Path $_.FullName "python.exe")
        }
}

function Find-Python {
    Refresh-Path

    $candidateList = New-Object System.Collections.Generic.List[string]

    # Prefer pack-tool embedded python if present
    $repoGuess = if ($PSScriptRoot) {
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    } else { $null }
    if ($repoGuess) {
        Get-ChildItem -LiteralPath $repoGuess -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $embedded = Join-Path $_.FullName "Tool\Python\python.exe"
            Add-PythonCandidate $candidateList $embedded
        }
    }

    foreach ($name in @("python", "py")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            Add-PythonCandidate $candidateList ([string]$cmd.Source)
        }
    }

    $localApp = [string]$env:LOCALAPPDATA
    if (-not [string]::IsNullOrWhiteSpace($localApp)) {
        Add-PythonCandidatesFromDir $candidateList (Join-Path $localApp "Programs\Python")
    }
    foreach ($pf in @([string]$env:ProgramFiles, [string]${env:ProgramFiles(x86)})) {
        if (-not [string]::IsNullOrWhiteSpace($pf)) {
            Add-PythonCandidatesFromDir $candidateList $pf
        }
    }

    $seen = @{}
    $pythonOk = @()
    $tooOld = New-Object System.Collections.Generic.List[string]
    $probed = 0
    $existCount = 0
    $needLabel = "{0}.{1}" -f $script:MinPythonMajor, $script:MinPythonMinor
    foreach ($c in $candidateList) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $existCount++

        $tagList = @("")
        if ([System.IO.Path]::GetFileNameWithoutExtension($c) -eq "py") {
            # PATH default `py -3` may be 3.9 while 3.12 is also installed.
            $tagList = @("-3.13", "-3.12", "-3.11", "-3.10", "-3")
        }

        foreach ($tag in $tagList) {
            $prefix = @()
            if ($tag) { $prefix = @($tag) }

            $key = $c.ToLowerInvariant() + "|" + $tag
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $probed++
            if (-not (Invoke-PythonProbe $c $prefix "import sys")) { continue }

            $ver = Get-PythonVersionLabel $c $prefix
            if (-not (Test-PythonVersionOk $ver)) {
                $label = if ($ver) { $ver } else { "?" }
                $skipMsg = "skip Python {0} (need >={1}): {2}" -f $label, $needLabel, $c
                if ($tag) { $skipMsg = $skipMsg + " " + $tag }
                Write-Info $skipMsg
                [void]$tooOld.Add(("{0} ({1})" -f $c, $label))
                continue
            }

            if (Test-PythonOpenpyxl $c $prefix) {
                Write-Info ("using Python {0}: {1}" -f $ver, $c)
                return @{ Exe = $c; Prefix = $prefix }
            }
            $pythonOk += @{ Exe = $c; Prefix = $prefix; Ver = $ver }
        }
    }

    # Have Python >= min but no openpyxl: try auto pip install once
    foreach ($p in $pythonOk) {
        if (Try-InstallOpenpyxl $p.Exe $p.Prefix) {
            Write-Info "openpyxl installed: $($p.Exe)"
            return $p
        }
    }

    $pathPreview = $env:Path
    if ($pathPreview.Length -gt 240) {
        $pathPreview = $pathPreview.Substring(0, 240) + "..."
    }
    $diag = @(
        "candidates=$($candidateList.Count) exist=$existCount probed=$probed pythonOk=$($pythonOk.Count) tooOld=$($tooOld.Count)",
        "Get-Command python=$([bool](Get-Command python -ErrorAction SilentlyContinue)) py=$([bool](Get-Command py -ErrorAction SilentlyContinue))",
        "LOCALAPPDATA=$env:LOCALAPPDATA",
        "PATH(preview)=$pathPreview"
    ) -join "`r`n"
    if ($tooOld.Count -gt 0) {
        $diag = $diag + "`r`n" + "tooOld=" + [string]::Join("; ", $tooOld.ToArray())
    }

    if ($pythonOk.Count -gt 0) {
        Fail-MissingPython "NoOpenpyxl" $diag
    }
    if ($tooOld.Count -gt 0) {
        Fail-MissingPython "PythonTooOld" $diag
    }
    Fail-MissingPython "NoPython" $diag
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Invoke-ExcelToLua(
    [hashtable]$Py,
    [string]$ScriptPath,
    [string]$ExcelDirPath,
    [string]$OutPath,
    [string]$ModeName
) {
    if (-not (Test-Path -LiteralPath $ExcelDirPath)) {
        throw "Excel dir missing: $ExcelDirPath"
    }
    $xlsx = @(Get-ChildItem -LiteralPath $ExcelDirPath -Filter "*.xlsx" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "~$*" })
    if ($xlsx.Count -eq 0) {
        throw "No xlsx in: $ExcelDirPath"
    }
    Ensure-Dir (Split-Path $OutPath -Parent)
    Write-Info ("Excel -> Lua: {0} files ({1}) mode={2}" -f $xlsx.Count, $ExcelDirPath, $ModeName)
    $args = $Py.Prefix + @(
        $ScriptPath,
        "--excel-dir", $ExcelDirPath,
        "--out", $OutPath,
        "--mode", $ModeName
    )
    & $Py.Exe @args
    if ($LASTEXITCODE -ne 0) {
        $errFile = Join-Path $PSScriptRoot "precommit-last-error.txt"
        if (Test-Path -LiteralPath $errFile) {
            $detail = (Get-Content -LiteralPath $errFile -Raw -Encoding UTF8).Trim()
            # Avoid throw-with-detail: UGit/cmd mangles multiline/special chars.
            Write-Host "[BuildConfig][ERROR]" -ForegroundColor Red
            Write-Host $detail -ForegroundColor Red
            exit 1
        }
        Write-Host "[BuildConfig][ERROR] ExcelToLua.py failed, exit=$LASTEXITCODE" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path -LiteralPath $OutPath)) {
        throw "Output missing: $OutPath"
    }
    Write-Info "OK output: $OutPath"
}

function Copy-ToLuau([string]$SrcLua, [string]$DstLuau) {
    Ensure-Dir (Split-Path $DstLuau -Parent)
    Copy-Item -LiteralPath $SrcLua -Destination $DstLuau -Force
    Write-Info "Synced: $DstLuau"
}

function Find-PackWork([string]$Repo, [string]$Project) {
    Get-ChildItem -LiteralPath $Repo -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $work = Join-Path $_.FullName "Work\$Project"
        $excel = Join-Path $work "Excel"
        if (Test-Path -LiteralPath $excel) {
            return $work
        }
    }
    return $null
}

$repo = Find-RepoRoot $RepoRoot
$py = Find-Python
$scriptPath = Join-Path $repo "scripts\ugit\ExcelToLua.py"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing $scriptPath"
}

Write-Info "RepoRoot=$repo Mode=$Mode Python=$($py.Exe)"

$configLua = $null
$languageLua = $null
$skipCopy = [bool]$NoCopyToSrc -or ($env:UGIT_NO_COPY_TO_SRC -eq "1")
$doCopySrc = -not $skipCopy
if ($doCopySrc) {
    Write-Info "will copy lua -> src luau"
} else {
    Write-Info "validate only, skip copy to src"
}

if ($Mode -eq "Framework") {
    $excelDirPath = Join-Path $repo "config"
    $locDir = Join-Path $repo "config\Localization"
    $buildDir = Join-Path $repo "config\.build"
    Ensure-Dir $buildDir
    $configLua = Join-Path $buildDir "ConfigInstance.lua"
    $languageLua = Join-Path $buildDir "Language.lua"

    Invoke-ExcelToLua $py $scriptPath $excelDirPath $configLua "config"

    if (-not $SkipLanguage) {
        Invoke-ExcelToLua $py $scriptPath $locDir $languageLua "language"
    }
}
else {
    $workExcel = $ExcelDir
    $workLoc = $LocalizationDir
    $outDir = $null

    if ($ProjectName) {
        $workRoot = Find-PackWork $repo $ProjectName
        if (-not $workRoot) {
            throw "Work project not found: $ProjectName (need <pack>/Work/$ProjectName/Excel)"
        }
        if (-not $workExcel) { $workExcel = Join-Path $workRoot "Excel" }
        if (-not $workLoc) { $workLoc = Join-Path $workRoot "Localization" }
        $outDir = $workRoot
    }
    elseif ($workExcel) {
        $outDir = Split-Path ([System.IO.Path]::GetFullPath($workExcel)) -Parent
    }
    else {
        throw "Work mode needs -ProjectName or -ExcelDir"
    }

    $configLua = Join-Path $outDir "ConfigInstance.lua"
    $languageLua = Join-Path $outDir "Language.lua"
    Invoke-ExcelToLua $py $scriptPath $workExcel $configLua "config"

    if (-not $SkipLanguage) {
        if (Test-Path -LiteralPath $workLoc) {
            Invoke-ExcelToLua $py $scriptPath $workLoc $languageLua "language"
        }
        else {
            Write-Info "Skip language: no Localization dir"
            $languageLua = $null
        }
    }

    $doCopySrc = [bool]$CopyToSrc
}

if ($doCopySrc) {
    $dstConfig = Join-Path $repo "src\ReplicatedFirst\AllSideCode\ToolBasic\ConfigInstance.luau"
    Copy-ToLuau $configLua $dstConfig
    if ($languageLua -and (Test-Path -LiteralPath $languageLua)) {
        $dstLang = Join-Path $repo "src\ReplicatedFirst\AllSideCode\ToolBasic\TranslationHelper\Language.luau"
        Copy-ToLuau $languageLua $dstLang
    }
}

Write-Info "Build finished"
exit 0
