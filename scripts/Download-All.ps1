<#
.SYNOPSIS
主要な事前取得scriptをまとめて実行します。

.DESCRIPTION
`scripts/`配下のdownload scriptを順に実行し、指定した出力directoryへair-gap資材を取得します。
Hugging Face modelは大容量のため、既定では対象外です。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER IncludeHFRepo
Hugging Face model repositoryも取得します。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-All.ps1 -OutputDir C:\airgap

Hugging Face model以外の主要資材を取得します。

.NOTES
副作用として指定directoryへ各種download成果物を作成または上書きします。
#>
[CmdletBinding()]
param (
    [string]$OutputDir,
    [switch]$IncludeHFRepo,
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

$DownloadScripts = @(
    "Download-Difypkg.ps1",
    "Download-Nextcloud.ps1",
    "Download-Docling.ps1"
)

if ($IncludeHFRepo) {
    $DownloadScripts += "Download-HFRepo.ps1"
}

$DownloadScripts += @(
    "Download-RPM.ps1",
    "Download-DEB.ps1",
    "Download-VSIX.ps1",
    "Download-DockerImages.ps1",
    "Download-PipPkgs.ps1",
    "Download-NpmPkgs.ps1"
)

foreach ($Script in $DownloadScripts) {
    $ScriptPath = Join-Path $PSScriptRoot $Script
    Write-Host "Running ==> $Script"
    & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath -OutputDir $OutputDir
    if ($LASTEXITCODE -ne 0) {
        throw "Download failed: $Script"
    }
}
