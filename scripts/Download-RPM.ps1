<#
.SYNOPSIS
Linux x86_64向けのRPM packageを取得します。

.DESCRIPTION
Rocky Linux 9互換repositoryから、指定したRPM packageと依存packageを取得します。
既定ではBaseOS、AppStream、CRB、EPELを参照し、`/srv/12-registry/rpm/`へ保存します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-RPM.ps1 -OutputDir C:\airgap

指定directoryの`rpm`配下へpackageを依存込みで取得します。

.NOTES
副作用として指定directoryへ`.rpm` fileを作成または上書きします。
実行にはPowerShellと外部repositoryへのHTTP接続が必要です。
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
        "vim-enhanced",
        "ncdu",
        "pkgconf-pkg-config",
        "readline-devel",
        "ncurses-devel",
        "clang-libs"
)
$Registries = @(
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
)
$Architecture = "x86_64"

if ($Packages.Count -eq 0) {
    throw "取得するRPM packageが指定されていません。"
}

$CommonScript = Join-Path $PSScriptRoot "..\12-registry\scripts\download-assets-common.ps1"
. $CommonScript

$DestinationDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "rpm"
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null

Write-Host "Download RPM packages: $($Packages -join ', ')"
Save-RpmPackagesWithDependencies `
    -PackageNames $Packages `
    -RepositoryBaseUrls $Registries `
    -Architecture $Architecture `
    -OutputDirectory $DestinationDirectory

Assert-AssetFilesExist -Directory $DestinationDirectory -Pattern "*.rpm" -Description "RPM"
