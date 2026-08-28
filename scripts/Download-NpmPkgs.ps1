<#
.SYNOPSIS
このrepositoryのair-gap運用に必要なnpm package資材を取得します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-NpmPkgs.ps1 -OutputDir C:\airgap

repository内の対象projectからnpm packageを`C:\airgap\npm`へ取得します。
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
$Registries = @(
    "https://registry.npmjs.org"
)
$Packages = @(
    ".",
    "41-llmwiki/ingester",
    "41-llmwiki/runtime",
    "42-openkb/viewer"
)

<#
.SYNOPSIS
projectの依存定義を共通download処理へ渡します。
.PARAMETER ProjectDir
package.jsonがあるproject directoryです。
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

    $DownloaderPath = Join-Path $PSScriptRoot "Download-NpmPkgs-from-Project.ps1"
    & $DownloaderPath -ProjectDir $ProjectDir -OutputDir $OutputDir
}

$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
foreach ($Package in $Packages) {
    $ProjectDir = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Package))
    Invoke-ProjectPackageDownload -ProjectDir $ProjectDir -OutputDir $OutputDir
}
