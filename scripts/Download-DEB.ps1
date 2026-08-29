<#
.SYNOPSIS
Debian 13およびUbuntu 24.04 LTS x86_64向けのdeb packageを取得します。

.DESCRIPTION
Debian 13（trixie）とUbuntu 24.04 LTS（noble）のrepositoryから、指定したdeb packageと依存packageを取得します。

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
        Name = "Debian 13 (trixie)"
        BaseUrl = "https://deb.debian.org/debian/"
        PackagePaths = @(
            "dists/trixie/main/binary-amd64/Packages.gz"
        )
    },
    [pscustomobject]@{
        Name = "Ubuntu 24.04 LTS (noble)"
        BaseUrl = "https://archive.ubuntu.com/ubuntu/"
        PackagePaths = @(
            "dists/noble/main/binary-amd64/Packages.gz",
            "dists/noble/universe/binary-amd64/Packages.gz"
        )
    }
)
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Packages = @("hello")
}

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

New-Item `
    -ItemType Directory `
    -Path $DestinationDirectory `
    -Force |
    Out-Null

Write-Host "Debian and Ubuntu deb packages:"
Write-Host "  Packages: $($Packages -join ', ')"
Write-Host "  Destination: $DestinationDirectory"

foreach ($Registry in $Registries) {
    $PackagesUrls = @(
        foreach ($PackagesPath in $Registry.PackagePaths) {
            Join-RepositoryUrl `
                -BaseUrl $Registry.BaseUrl `
                -RelativePath $PackagesPath
        }
    )

    Write-Host "  Repository: $($Registry.Name)"
    foreach ($PackagesUrl in $PackagesUrls) {
        Write-Host "    $PackagesUrl"
    }

    Save-DebPackagesWithDependencies `
        -PackageNames $Packages `
        -PackagesUrl $PackagesUrls `
        -RepositoryBaseUrl $Registry.BaseUrl `
        -OutputDirectory $DestinationDirectory
}

Assert-AssetFilesExist `
    -Directory $DestinationDirectory `
    -Pattern "*.deb" `
    -Description "Debian/Ubuntu deb"
