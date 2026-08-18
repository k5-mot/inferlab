<#
.SYNOPSIS
Ubuntu 24.04 LTS x86_64向けのdeb packageを取得します。

.DESCRIPTION
Ubuntu 24.04 LTS（noble）のmain/amd64およびuniverse/amd64
repositoryから、指定したdeb packageと依存packageを取得します。

既定では`/srv/12-registry/deb/`へ保存します。

.PARAMETER DestinationDirectory
取得したdeb packageを保存するdirectoryです。

.PARAMETER Packages
取得するdeb package名の配列です。

.PARAMETER RepositoryBaseUrl
参照するUbuntu repository root URLです。

.PARAMETER PackagesPaths
repository rootからPackages.gzまでの相対pathの配列です。

既定ではUbuntu 24.04 LTS（noble）のmainおよびuniverseを参照します。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Deb-Packages.ps1

bash、zsh、curl、git、jq、tmux、neovim、vim、
build-essential、clang、ncduなどを依存込みで取得します。

.EXAMPLE
.\script\Download-Deb-Packages.ps1 `
    -DestinationDirectory .\deb `
    -Packages tmux,git

指定したdeb packageを`deb/`へ取得します。

.EXAMPLE
.\script\Download-Deb-Packages.ps1 `
    -PackagesPaths @(
        "dists/noble/main/binary-amd64/Packages.gz"
    )

main componentだけを参照します。

.NOTES
副作用として指定directoryへ`.deb` fileを作成または上書きします。

実行にはPowerShellと外部repositoryへのHTTP接続が必要です。

Save-DebPackagesWithDependenciesのPackagesUrl parameterは、
複数のURLを受け取れる必要があります。
#>
[CmdletBinding()]
param (
    [string]$DestinationDirectory = (
        "/srv/12-registry/deb"
    ),

    [string[]]$Packages = @(
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
    ),

    [string]$RepositoryBaseUrl = "https://archive.ubuntu.com/ubuntu/",
    # [string]$RepositoryBaseUrl = "https://deb.debian.org/debian/",

    [string[]]$PackagesPaths = @(
        "dists/noble/main/binary-amd64/Packages.gz",
        "dists/noble/universe/binary-amd64/Packages.gz"
    ),
    # [string]$PackagesPaths = @(
    #    "dists/trixie/main/binary-amd64/Packages.gz"
    # ),

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"

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

$PackagesPaths = @(
    $PackagesPaths |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Unique
)

if ($PackagesPaths.Count -eq 0) {
    throw "参照するPackages.gzが指定されていません。"
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

$DestinationDirectory = [System.IO.Path]::GetFullPath(
    $DestinationDirectory
)

$PackagesUrls = @(
    foreach ($PackagesPath in $PackagesPaths) {
        Join-RepositoryUrl `
            -BaseUrl $RepositoryBaseUrl `
            -RelativePath $PackagesPath
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
    -RepositoryBaseUrl $RepositoryBaseUrl `
    -OutputDirectory $DestinationDirectory

Assert-AssetFilesExist `
    -Directory $DestinationDirectory `
    -Pattern "*.deb" `
    -Description "Ubuntu 24.04 deb"
