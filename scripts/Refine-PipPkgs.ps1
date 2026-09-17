<#
.SYNOPSIS
requirements.txtをwheelだけで導入できる完全なrequirements fileへ変換します。

.DESCRIPTION
uvで推移依存を解決し、requirements-full.txtとrequirements-next.txtを作成します。
requirements-full.txtは元のversion制約を尊重し、requirements-next.txtはすべての固定versionを外して最新の互換versionへ更新します。
source distributionは使用せず、Python 3.10と3.14のWindows x64とLinux x64でwheelを解決できることを検証します。

.PARAMETER ProjectDir
requirements.txtがあるproject directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Refine-PipPkgs.ps1 -ProjectDir C:\src\project

requirements.txtからrequirements-full.txtとrequirements-next.txtを作成します。

.NOTES
作業directoryとuv cacheはproject directory内に一時作成し、処理終了時に削除します。
#>
[CmdletBinding()]
param (
    [string]$ProjectDir,

    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}
if (-not $ProjectDir) {
    throw "ProjectDir is required."
}

$ErrorActionPreference = "Stop"
$ValidationTargets = @(
    [pscustomobject]@{ PythonVersion = "3.10"; Platform = "windows" },
    [pscustomobject]@{ PythonVersion = "3.10"; Platform = "x86_64-manylinux2014" },
    [pscustomobject]@{ PythonVersion = "3.14"; Platform = "windows" },
    [pscustomobject]@{ PythonVersion = "3.14"; Platform = "x86_64-manylinux2014" }
)

<#
.SYNOPSIS
外部commandを実行し、終了codeを検証します。
.PARAMETER FilePath
実行するcommand名またはpathです。
.PARAMETER Arguments
commandへ渡すargument配列です。
.OUTPUTS
commandの標準出力を返します。
#>
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        throw "required command was not found: $FilePath"
    }

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

<#
.SYNOPSIS
uvでrequirements fileの依存を解決します。
.PARAMETER InputPath
依存解決の入力requirements fileです。
.PARAMETER OutputPath
固定versionを書き込むrequirements fileです。
.PARAMETER CacheDirectory
uv cacheとして使用する一時directoryです。
.PARAMETER Upgrade
既存の出力versionを無視して更新する場合に指定します。
.PARAMETER PythonVersion
特定のPython version向けに解決する場合に指定します。
.PARAMETER PythonPlatform
特定のplatform向けに解決する場合に指定します。
.OUTPUTS
値を返しません。OutputPathを作成または更新します。
#>
function Invoke-RequirementsCompile {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$CacheDirectory,
        [switch]$Upgrade,
        [string]$PythonVersion,
        [string]$PythonPlatform
    )

    $Arguments = @(
        "pip", "compile", $InputPath,
        "--output-file", $OutputPath,
        "--only-binary", ":all:",
        "--cache-dir", $CacheDirectory,
        "--no-annotate",
        "--no-header",
        "--no-progress"
    )
    if ($PythonVersion) {
        $Arguments += @("--python-version", $PythonVersion)
    }
    if ($PythonPlatform) {
        $Arguments += @("--python-platform", $PythonPlatform)
    }
    else {
        $Arguments += "--universal"
    }
    if ($Upgrade) {
        $Arguments += "--upgrade"
    }

    $null = Invoke-NativeCommand -FilePath "uv" -Arguments $Arguments
}

<#
.SYNOPSIS
uvが出力したrequirementから固定versionだけを取り除きます。
.PARAMETER Requirement
uvが出力した1行のrequirementです。
.OUTPUTS
version固定を外したrequirementを返します。
#>
function ConvertTo-UnpinnedRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    if ($Requirement -match "^([A-Za-z0-9][A-Za-z0-9_.-]*)(\[[^\]]+\])?==[^;\s]+(\s*;.*)?$") {
        return "$($Matches[1])$($Matches[2])$($Matches[3])".Trim()
    }

    return $Requirement
}

<#
.SYNOPSIS
固定済みrequirements fileからupgrade用の入力fileを作成します。
.PARAMETER InputPath
uvが生成した固定済みrequirements fileです。
.PARAMETER OutputPath
version固定を外したrequirements fileの出力pathです。
.OUTPUTS
値を返しません。OutputPathを作成または上書きします。
#>
function New-UnpinnedRequirements {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $Requirements = foreach ($Line in Get-Content -LiteralPath $InputPath) {
        $Trimmed = $Line.Trim()
        if ($Trimmed -and -not $Trimmed.StartsWith("#")) {
            ConvertTo-UnpinnedRequirement -Requirement $Trimmed
        }
    }
    $Requirements | Set-Content -LiteralPath $OutputPath -Encoding ascii
}

<#
.SYNOPSIS
固定済みrequirementsを対象Pythonとplatformでwheel解決できるか検証します。
.PARAMETER RequirementsPath
検証する固定済みrequirements fileです。
.PARAMETER WorkDirectory
検証結果を一時出力するdirectoryです。
.PARAMETER CacheDirectory
uv cacheとして使用する一時directoryです。
.OUTPUTS
値を返しません。wheelだけで解決できない場合は例外を送出します。
#>
function Assert-WheelCompatibility {
    param(
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [Parameter(Mandatory = $true)][string]$WorkDirectory,
        [Parameter(Mandatory = $true)][string]$CacheDirectory
    )

    foreach ($Target in $ValidationTargets) {
        $OutputPath = Join-Path $WorkDirectory "requirements-$($Target.PythonVersion)-$($Target.Platform).txt"
        Invoke-RequirementsCompile `
            -InputPath $RequirementsPath `
            -OutputPath $OutputPath `
            -CacheDirectory $CacheDirectory `
            -PythonVersion $Target.PythonVersion `
            -PythonPlatform $Target.Platform
    }
}

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw "uvが見つかりません。uvをインストールしてください。"
}

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
if (-not (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
    throw "ProjectDir was not found: $ProjectDir"
}

$RequirementsPath = Join-Path $ProjectDir "requirements.txt"
if (-not (Test-Path -LiteralPath $RequirementsPath -PathType Leaf)) {
    throw "requirements.txt was not found in project directory: $ProjectDir"
}

$FullRequirementsPath = Join-Path $ProjectDir "requirements-full.txt"
$NextRequirementsPath = Join-Path $ProjectDir "requirements-next.txt"
$WorkDirectory = Join-Path $ProjectDir ".refine-pip-$([guid]::NewGuid().ToString("N"))"
$CacheDirectory = Join-Path $WorkDirectory "cache"
$StagedFullRequirementsPath = Join-Path $WorkDirectory "requirements-full.txt"
$StagedNextRequirementsPath = Join-Path $WorkDirectory "requirements-next.txt"
$UnpinnedRequirementsPath = Join-Path $WorkDirectory "requirements-next.in"
try {
    New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    Invoke-RequirementsCompile `
        -InputPath $RequirementsPath `
        -OutputPath $StagedFullRequirementsPath `
        -CacheDirectory $CacheDirectory `
        -Upgrade `
        -PythonVersion "3.10"
    Assert-WheelCompatibility `
        -RequirementsPath $StagedFullRequirementsPath `
        -WorkDirectory $WorkDirectory `
        -CacheDirectory $CacheDirectory

    New-UnpinnedRequirements -InputPath $StagedFullRequirementsPath -OutputPath $UnpinnedRequirementsPath
    Invoke-RequirementsCompile `
        -InputPath $UnpinnedRequirementsPath `
        -OutputPath $StagedNextRequirementsPath `
        -CacheDirectory $CacheDirectory `
        -Upgrade `
        -PythonVersion "3.10"
    Assert-WheelCompatibility `
        -RequirementsPath $StagedNextRequirementsPath `
        -WorkDirectory $WorkDirectory `
        -CacheDirectory $CacheDirectory

    Copy-Item -LiteralPath $StagedFullRequirementsPath -Destination $FullRequirementsPath -Force
    Copy-Item -LiteralPath $StagedNextRequirementsPath -Destination $NextRequirementsPath -Force
}
finally {
    Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Created requirements files: $FullRequirementsPath, $NextRequirementsPath"
