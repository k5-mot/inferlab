<#
.SYNOPSIS
Linux x86_64向けのdeb packageを取得します。

.DESCRIPTION
Debian 13(trixie)のmain/amd64 repositoryから、指定したdeb packageと依存packageを取得します。
既定では`deb/`へ保存します。

.PARAMETER DestinationDirectory
取得したdeb packageを保存するdirectoryです。

.PARAMETER Packages
取得するdeb package名の配列です。

.PARAMETER RepositoryBaseUrl
参照するDebian repository root URLです。

.PARAMETER PackagesPath
repository rootからPackages.gzまでの相対pathです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Deb-Packages.ps1

tmux、neovim、vim、gitを依存込みで取得します。

.EXAMPLE
.\script\Download-Deb-Packages.ps1 -DestinationDirectory .\deb -Packages tmux,git

指定したdeb packageを`deb/`へ取得します。

.NOTES
副作用として指定directoryへ`.deb` fileを作成または上書きします。
実行にはPowerShellと外部repositoryへのHTTP接続が必要です。
#>
[CmdletBinding()]
param (
    [string]$DestinationDirectory = (Join-Path (Get-Location).Path "deb"),

    [string[]]$Packages = @(
        "tmux",
        "neovim",
        "vim",
        "git"
    ),

    [string]$RepositoryBaseUrl = "https://deb.debian.org/debian/",

    [string]$PackagesPath = "dists/trixie/main/binary-amd64/Packages.gz",

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"

if ($Packages.Count -eq 0) {
    throw "取得するdeb packageが指定されていません。"
}

$CommonScript = Join-Path $PSScriptRoot "..\12-registry\scripts\download-assets-common.ps1"
. $CommonScript

$DestinationDirectory = [System.IO.Path]::GetFullPath($DestinationDirectory)
$PackagesUrl = Join-RepositoryUrl -BaseUrl $RepositoryBaseUrl -RelativePath $PackagesPath
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null

Write-Host "Download deb packages: $($Packages -join ', ')"
Save-DebPackagesWithDependencies `
    -PackageNames $Packages `
    -PackagesUrl $PackagesUrl `
    -RepositoryBaseUrl $RepositoryBaseUrl `
    -OutputDirectory $DestinationDirectory

Assert-AssetFilesExist -Directory $DestinationDirectory -Pattern "*.deb" -Description "deb"
