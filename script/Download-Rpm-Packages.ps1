<#
.SYNOPSIS
Linux x86_64向けのRPM packageを取得します。

.DESCRIPTION
Rocky Linux 9互換repositoryから、指定したRPM packageと依存packageを取得します。
既定ではBaseOS、AppStream、CRB、EPELを参照し、`rpm/`へ保存します。

.PARAMETER DestinationDirectory
取得したRPM packageを保存するdirectoryです。

.PARAMETER Packages
取得するRPM package名の配列です。

.PARAMETER RepositoryBaseUrls
参照するRPM repository root URLの配列です。

.PARAMETER Architecture
取得対象architectureです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Rpm-Packages.ps1

tmux、neovim、vim、gitを依存込みで取得します。

.EXAMPLE
.\script\Download-Rpm-Packages.ps1 -DestinationDirectory .\rpm -Packages tmux,git

指定したRPM packageを`rpm/`へ取得します。

.NOTES
副作用として指定directoryへ`.rpm` fileを作成または上書きします。
実行にはPowerShellと外部repositoryへのHTTP接続が必要です。
#>
[CmdletBinding()]
param (
    [string]$DestinationDirectory = (Join-Path (Get-Location).Path "rpm"),

    [string[]]$Packages = @(
        "bash",
        "zsh",
        "curl",
        "git",
        "jq",
        "tmux",
        "vim-enhanced",
        "ncdu",
        "pkgconf-pkg-config",
        "readline-devel",
        "ncurses-devel",
        "clang-libs"
    ),

    [string[]]$RepositoryBaseUrls = @(
        ### Oracle Linux 9
        "https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/",
        "https://yum.oracle.com/repo/OracleLinux/OL9/appstream/x86_64/",
        "https://yum.oracle.com/repo/OracleLinux/OL9/codeready/builder/x86_64/",
        "https://yum.oracle.com/repo/OracleLinux/OL9/developer/EPEL/x86_64/"
        ### Rocky Linux 9
        # "https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/",
        # "https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/",
        # "https://dl.rockylinux.org/pub/rocky/9/CRB/x86_64/os/",
        # "https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/"
        ### RedHat Enterprise Linux 9
        # "https://cdn.redhat.com/content/dist/rhel9/9/x86_64/baseos/os/",
        # "https://cdn.redhat.com/content/dist/rhel9/9/x86_64/appstream/os/",
        # "https://cdn.redhat.com/content/dist/rhel9/9/x86_64/codeready-builder/os/",
        # "https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/"
    ),

    [string]$Architecture = "x86_64",

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"

if ($Packages.Count -eq 0) {
    throw "取得するRPM packageが指定されていません。"
}

$CommonScript = Join-Path $PSScriptRoot "..\12-registry\scripts\download-assets-common.ps1"
. $CommonScript

$DestinationDirectory = [System.IO.Path]::GetFullPath($DestinationDirectory)
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null

Write-Host "Download RPM packages: $($Packages -join ', ')"
Save-RpmPackagesWithDependencies `
    -PackageNames $Packages `
    -RepositoryBaseUrls $RepositoryBaseUrls `
    -Architecture $Architecture `
    -OutputDirectory $DestinationDirectory

Assert-AssetFilesExist -Directory $DestinationDirectory -Pattern "*.rpm" -Description "RPM"
