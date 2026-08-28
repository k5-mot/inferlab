<#
.SYNOPSIS
Ubuntu 24.04 LTS x86_64向けのdeb packageを取得します。

.DESCRIPTION
Ubuntu 24.04 LTS（noble）のmain/amd64およびuniverse/amd64
repositoryから、指定したdeb packageと依存packageを取得します。

既定では`/srv/12-registry/deb/`へ保存します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-DEB.ps1 -OutputDir C:\airgap

指定directoryの`deb`配下へpackageを依存込みで取得します。

.NOTES
副作用として指定directoryへ`.deb` fileを作成または上書きします。

実行にはPowerShellと外部repositoryへのHTTP接続が必要です。

Save-DebPackagesWithDependenciesのPackagesUrl parameterは、
複数のURLを受け取れる必要があります。
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
$Packages = @(
        "bash",
        "zsh",
        "curl",
        "git",
        "jq",
        "tmux",
        "neovim",
        "vim",
        "build-essential",
        "pkg-config",
        "libreadline-dev",
        "libncurses-dev",
        "clang",
        "ncdu"
)
$Registries = @(
    [pscustomobject]@{
        BaseUrl = "https://archive.ubuntu.com/ubuntu/"
        PackagePaths = @(
            "dists/noble/main/binary-amd64/Packages.gz",
            "dists/noble/universe/binary-amd64/Packages.gz"
        )
    }
)

$Packages = @(
    $Packages |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Unique
)

if ($Packages.Count -eq 0) {
    throw "取得するdeb packageが指定されていません。"
}

$CommonScript = [System.IO.Path]::GetFullPath(
    (Join-Path `
        $PSScriptRoot `
        "../12-registry/scripts/download-assets-common.ps1")
)

if (-not (Test-Path -LiteralPath $CommonScript -PathType Leaf)) {
    throw "共通scriptが見つかりません: $CommonScript"
}

. $CommonScript

$DestinationDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "deb"

$PackagesUrls = @(
    foreach ($Registry in $Registries) {
        foreach ($PackagesPath in $Registry.PackagePaths) {
            Join-RepositoryUrl `
                -BaseUrl $Registry.BaseUrl `
                -RelativePath $PackagesPath
        }
    }
)

New-Item `
    -ItemType Directory `
    -Path $DestinationDirectory `
    -Force |
    Out-Null

Write-Host "Ubuntu 24.04 LTS (noble) deb packages:"
Write-Host "  Packages: $($Packages -join ', ')"
Write-Host "  Destination: $DestinationDirectory"
Write-Host "  Package indexes:"

foreach ($PackagesUrl in $PackagesUrls) {
    Write-Host "    $PackagesUrl"
}

Save-DebPackagesWithDependencies `
    -PackageNames $Packages `
    -PackagesUrl $PackagesUrls `
    -RepositoryBaseUrl ($Registries[0].BaseUrl) `
    -OutputDirectory $DestinationDirectory

Assert-AssetFilesExist `
    -Directory $DestinationDirectory `
    -Pattern "*.deb" `
    -Description "Ubuntu 24.04 deb"
