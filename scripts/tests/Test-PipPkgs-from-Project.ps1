<#
.SYNOPSIS
from-Project版のPyPI package取得をfixtureで検証します。
.PARAMETER Static
network downloadを行わず、interface、行列定義、fixtureだけを検証します。
#>
param (
    [switch]$Static
)

. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$ScriptPath = Join-Path $PSScriptRoot "../Download-PipPkgs-from-Project.ps1"
$FixturePath = Join-Path $PSScriptRoot "requirements.txt"
$TestParameters = @{
    ScriptPath = $ScriptPath
    ExpectedParameters = @("OutputDir", "ProjectDir", "Help")
    ExpectedOutputDirectory = "pypi"
}
Assert-DownloadScript @TestParameters

$Requirements = @(
    Get-Content -LiteralPath $FixturePath |
        Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") }
)
if ($Requirements.Count -eq 0) {
    throw "PyPI検証用fixtureにpackageが定義されていません: $FixturePath"
}
foreach ($Requirement in $Requirements) {
    if ($Requirement -notmatch "^[A-Za-z0-9_.-]+(?:\[.*\])?==[^;\s]+(?:\s*;.*)?$") {
        throw "PyPI検証用fixtureのrequirementが不正です: $Requirement"
    }
}

$Source = Get-Content -LiteralPath $ScriptPath -Raw
foreach ($PythonVersion in @("3.12", "3.13", "3.14", "3.15")) {
    if ($Source -notmatch [regex]::Escape($PythonVersion)) {
        throw "Python version '$PythonVersion' が定義されていません。"
    }
}

if ($Static) {
    return
}

$OutputBase = Join-Path $PSScriptRoot ".tmp/pypi-from-projects"
Remove-Item -LiteralPath $OutputBase -Recurse -Force -ErrorAction SilentlyContinue
& $ScriptPath -OutputDir $OutputBase -ProjectDir $PSScriptRoot

$DownloadedPackages = @(
    Get-ChildItem -LiteralPath (Join-Path $OutputBase "pypi") -File -ErrorAction SilentlyContinue
)
if ($DownloadedPackages.Count -eq 0) {
    throw "from-Project版のPyPI packageが作成されませんでした: $OutputBase"
}
foreach ($UnexpectedPath in @(
    (Join-Path $PSScriptRoot "uv.lock"),
    (Join-Path $PSScriptRoot "pyproject.toml")
)) {
    if (Test-Path -LiteralPath $UnexpectedPath) {
        throw "PyPI fixture directoryに作業fileが残っています: $UnexpectedPath"
    }
}
foreach ($Platform in @(
    "any",
    "win32",
    "win_amd64",
    "manylinux_2_34_x86_64",
    "manylinux_2_28_x86_64",
    "manylinux_2_24_x86_64",
    "manylinux_2_17_x86_64",
    "manylinux2014_x86_64"
)) {
    if ($Source -notmatch [regex]::Escape($Platform)) {
        throw "Python platform '$Platform' が定義されていません。"
    }
}
