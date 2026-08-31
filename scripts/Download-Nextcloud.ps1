<#
.SYNOPSIS
airgap環境へ持ち込むNextcloud OIDC app archiveを取得します。

.DESCRIPTION
Nextcloudの`user_oidc` app archiveを指定directoryへ取得し、SHA256 checksumを検証します。
このscriptはcontainer image archiveを扱いません。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-Nextcloud.ps1 -OutputDir C:\airgap

Nextcloud OIDC app archiveを`C:\airgap\nextcloud`へ取得します。

.NOTES
副作用として指定directoryへfileを作成または上書きします。
実行にはPowerShellが必要です。
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

$Overwrite = $true
$Registries = @(
    "https://github.com/nextcloud-releases/user_oidc"
)
$Packages = @(
    @{
        Registry = $Registries[0]
        Path = "releases/download/v8.10.1/user_oidc-v8.10.1.tar.gz"
        FileName = "user_oidc-v8.10.1.tar.gz"
        Sha256 = "49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd"
    }
)

$OutputDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "nextcloud"
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

foreach ($Package in $Packages) {
    $Url = "$($Package['Registry'])/$($Package['Path'])"
    $FileName = $Package["FileName"]
    $ExpectedSha256 = $Package["Sha256"]
    $ArtifactPath = Join-Path $OutputDirectory $FileName

    if ((Test-Path $ArtifactPath) -and -not $Overwrite) {
        Write-Host "Skip $FileName"
        continue
    }

    Write-Host "Download $FileName"
    Invoke-WebRequest -Uri $Url -OutFile $ArtifactPath -UseBasicParsing

    $ActualSha256 = (Get-FileHash -Algorithm SHA256 -Path $ArtifactPath).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $ExpectedSha256) {
        throw "チェックサムが一致しません: $FileName"
    }
}
