$ErrorActionPreference = "Stop"

# deb repositoryから依存込みで取得するpackageを定義する。
$DebPackages = @(
    "tmux",
    "neovim",
    "vim",
    "git"
)

# 既定ではDebian 13(trixie)のmain/amd64を参照する。
$DefaultDebRepositoryBaseUrl = "https://deb.debian.org/debian/"
$DefaultDebPackagesPath = "dists/trixie/main/binary-amd64/Packages.gz"

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDirectory "download-assets-common.ps1")

$AssetsPath = Get-AssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory (Get-Location).Path
Write-Host "assets directory: $AssetsPath"

$DebRepositoryBaseUrl = if ($env:DEB_REPOSITORY_BASE_URL) { $env:DEB_REPOSITORY_BASE_URL } else { $DefaultDebRepositoryBaseUrl }
$DebPackagesUrl = if ($env:DEB_PACKAGES_URL) { $env:DEB_PACKAGES_URL } else { Join-RepositoryUrl -BaseUrl $DebRepositoryBaseUrl -RelativePath $DefaultDebPackagesPath }

New-AssetDirectories -AssetsPath $AssetsPath -Names @("deb")
$DebAssetsDir = Join-Path $AssetsPath "deb"

Save-DebPackagesWithDependencies -PackageNames $DebPackages -PackagesUrl $DebPackagesUrl -RepositoryBaseUrl $DebRepositoryBaseUrl -OutputDirectory $DebAssetsDir
Assert-AssetFilesExist -Directory $DebAssetsDir -Pattern "*.deb" -Description "deb"
