$ErrorActionPreference = "Stop"

# RPM repositoryから依存込みで取得するpackageを定義する。
$RpmPackages = @(
    "tmux",
    "neovim",
    "vim",
    "git"
)

# 既定ではRocky Linux 9のBaseOS/AppStream/CRBとEPELを参照する。
$DefaultRpmRepositoryBaseUrls = @(
    "https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/",
    "https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/",
    "https://dl.rockylinux.org/pub/rocky/9/CRB/x86_64/os/",
    "https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/"
)
$DefaultRpmArchitecture = "x86_64"

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDirectory "download-assets-common.ps1")

$AssetsPath = Get-AssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory (Get-Location).Path
Write-Host "assets directory: $AssetsPath"

$RpmRepositoryBaseUrls = $DefaultRpmRepositoryBaseUrls
if ($env:RPM_REPOSITORY_BASE_URLS) {
    $RpmRepositoryBaseUrls = Split-ListValue -Value $env:RPM_REPOSITORY_BASE_URLS
} elseif ($env:RPM_REPOSITORY_BASE_URL) {
    $RpmRepositoryBaseUrls = @($env:RPM_REPOSITORY_BASE_URL)
}

$RpmArchitecture = if ($env:RPM_ARCHITECTURE) { $env:RPM_ARCHITECTURE } else { $DefaultRpmArchitecture }

New-AssetDirectories -AssetsPath $AssetsPath -Names @("rpm")
$RpmAssetsDir = Join-Path $AssetsPath "rpm"

Save-RpmPackagesWithDependencies -PackageNames $RpmPackages -RepositoryBaseUrls $RpmRepositoryBaseUrls -Architecture $RpmArchitecture -OutputDirectory $RpmAssetsDir
Assert-AssetFilesExist -Directory $RpmAssetsDir -Pattern "*.rpm" -Description "RPM"
