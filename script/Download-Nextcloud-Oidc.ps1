<#
.SYNOPSIS
airgap環境へ持ち込むNextcloud OIDC app archiveを取得します。

.DESCRIPTION
Nextcloudの`user_oidc` app archiveを指定directoryへ取得し、SHA256 checksumを検証します。
このscriptはcontainer image archiveを扱いません。

.PARAMETER OutputDirectory
Nextcloud OIDC app archiveを保存するdirectoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Nextcloud-Oidc.ps1

Nextcloud OIDC app archiveを`nextcloud-oidc/`へ取得します。

.EXAMPLE
.\script\Download-Nextcloud-Oidc.ps1 -OutputDirectory .\nextcloud-apps

Nextcloud OIDC app archiveを`nextcloud-apps/`へ取得します。

.EXAMPLE
.\script\Download-Nextcloud-Oidc.ps1 -Help

scriptの詳細helpを表示します。

.NOTES
副作用として指定directoryへfileを作成または上書きします。
実行にはPowerShellが必要です。
#>
[CmdletBinding()]
param (
    [string]$OutputDirectory = (Join-Path (Get-Location).Path "nextcloud-oidc"),

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$Overwrite = $true
$FileArtifacts = @(
    @{
        Url = "https://github.com/nextcloud-releases/user_oidc/releases/download/v8.10.1/user_oidc-v8.10.1.tar.gz"
        FileName = "user_oidc-v8.10.1.tar.gz"
        Sha256 = "49ced1fe192302f4540b869438b6ccb9ca0d69b717b76ed7075a70aa5cf666fd"
    }
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

foreach ($FileArtifact in $FileArtifacts) {
    $Url = $FileArtifact["Url"]
    $FileName = $FileArtifact["FileName"]
    $ExpectedSha256 = $FileArtifact["Sha256"]
    $ArtifactPath = Join-Path $OutputDirectory $FileName

    if ((Test-Path $ArtifactPath) -and -not $Overwrite) {
        Write-Host "Skip $FileName"
        continue
    }

    Write-Host "Download $FileName"
    Invoke-WebRequest -Uri $Url -OutFile $ArtifactPath

    $ActualSha256 = (Get-FileHash -Algorithm SHA256 -Path $ArtifactPath).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $ExpectedSha256) {
        throw "チェックサムが一致しません: $FileName"
    }
}
