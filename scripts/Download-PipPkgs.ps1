<#
.SYNOPSIS
このrepositoryのair-gap運用に必要なPython package資材を取得します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-PipPkgs.ps1 -OutputDir C:\airgap

Dify plugin、private-chat、OpenKBのPython依存を`C:\airgap\pypi`へ取得します。

.NOTES
先にDownload-Difypkg.ps1を実行してDify plugin packageを用意する必要があります。
#>
[CmdletBinding()]
param (
    [string]$OutputDir,
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}
if (-not $OutputDir) {
    throw "OutputDir is required."
}

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Registries = @(
    "https://pypi.org/simple",
    "https://download.pytorch.org/whl/cpu",
    "https://raw.githubusercontent.com/k5-mot/private-chat/main/api/pyproject.toml"
)
$Packages = @(
    [pscustomobject]@{ Type = "difypkg"; Path = "dify/*.difypkg" },
    [pscustomobject]@{ Type = "project"; Path = "../42-openkb" },
    [pscustomobject]@{ Type = "pyproject"; Registry = $Registries[2] }
)

<#
.SYNOPSIS
projectの依存定義を共通download処理へ渡します。
.PARAMETER ProjectDir
pyproject.tomlまたはrequirements.txtがあるproject directoryです。
.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。
.OUTPUTS
値を返しません。
.NOTES
保存先へpackage archiveを作成または上書きし、downloadに失敗した場合は例外を送出します。
#>
function Invoke-ProjectPackageDownload {
    param (
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    $DownloaderPath = Join-Path $PSScriptRoot "Download-PipPkgs-from-Project.ps1"
    & $DownloaderPath -ProjectDir $ProjectDir -OutputDir $OutputDir
}

<#
.SYNOPSIS
Dify plugin packageからrequirements.txtを展開します。
.PARAMETER PackagePath
展開対象の`.difypkg` file pathです。
.PARAMETER ProjectDir
requirements.txtの展開先project directoryです。
.OUTPUTS
展開したrequirements.txtの絶対pathを返します。fileが含まれない場合はnullを返します。
.NOTES
一時project directoryへrequirements.txtを作成します。
#>
function Expand-DifyRequirements {
    param (
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$ProjectDir
    )

    New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
    $RequirementsPath = Join-Path $ProjectDir "requirements.txt"
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $Entry = $Archive.GetEntry("requirements.txt")
        if ($null -eq $Entry) {
            return $null
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $RequirementsPath, $true)
    }
    finally {
        $Archive.Dispose()
    }
    return $RequirementsPath
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$TemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("repository-pip-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TemporaryDirectory -Force | Out-Null

try {
    foreach ($Package in $Packages) {
        if ($Package.Type -eq "difypkg") {
            $PatternPath = Join-Path $OutputDir $Package.Path
            $PluginPackages = @(Get-ChildItem -Path $PatternPath -File -ErrorAction SilentlyContinue)
            if ($PluginPackages.Count -eq 0) {
                throw "Dify plugin packageが見つかりません。先にDownload-Difypkg.ps1を実行してください: $PatternPath"
            }
            $PluginNumber = 0
            foreach ($PluginPackage in $PluginPackages) {
                $PluginNumber += 1
                $ProjectDir = Join-Path $TemporaryDirectory "dify-$PluginNumber"
                $RequirementsPath = Expand-DifyRequirements -PackagePath $PluginPackage.FullName -ProjectDir $ProjectDir
                if (-not $RequirementsPath) {
                    Write-Host "Skip Dify plugin without requirements.txt: $($PluginPackage.Name)"
                    continue
                }
                $RequirementLines = @(
                    Get-Content -LiteralPath $RequirementsPath |
                        Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") }
                )
                if ($RequirementLines.Count -eq 0) {
                    Write-Host "Skip Dify plugin without Python dependency: $($PluginPackage.Name)"
                    continue
                }
                Invoke-ProjectPackageDownload -ProjectDir $ProjectDir -OutputDir $OutputDir
            }
            continue
        }

        if ($Package.Type -eq "project") {
            $ProjectDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $Package.Path))
            Invoke-ProjectPackageDownload -ProjectDir $ProjectDir -OutputDir $OutputDir
            continue
        }

        $ProjectDir = Join-Path $TemporaryDirectory "remote-pyproject"
        New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
        Invoke-WebRequest -Uri $Package.Registry -OutFile (Join-Path $ProjectDir "pyproject.toml")
        Invoke-ProjectPackageDownload -ProjectDir $ProjectDir -OutputDir $OutputDir
    }
}
finally {
    Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
