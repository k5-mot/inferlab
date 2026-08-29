<#
.SYNOPSIS
VS Code拡張機能のVSIX fileを取得します。

.DESCRIPTION
Visual Studio Marketplaceから指定した拡張機能のlatest VSIXを取得します。
既定では使用する拡張機能を`/srv/12-registry/vsix/`へ保存します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-VSIX.ps1 -OutputDir C:\airgap

指定directoryの`vscode`配下へVSIXを取得します。

.NOTES
副作用として指定directoryへ`.vsix` fileを作成または上書きします。
実行にはPowerShellとVisual Studio MarketplaceへのHTTP接続が必要です。
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
$Registries = @(
    "https://marketplace.visualstudio.com"
)
$Packages = @(
        "openai.chatgpt",
        "ms-azuretools.vscode-containers",
        "terrastruct.d2",
        "ms-vscode-remote.remote-containers",
        "ms-azuretools.vscode-docker",
        "p1c2u.docker-compose",
        "hediet.vscode-drawio",
        "pomdtr.excalidraw-editor",
        "pkief.material-icon-theme",
        "zhuangtongfa.material-theme",
        "oxsecurity.ox-ide",
        "oxc.oxc-vscode",
        "ms-vscode-remote.remote-ssh",
        "ms-vscode-remote.remote-ssh-edit",
        "ms-vscode.remote-server",
        "ms-vscode-remote.vscode-remote-extensionpack",
        "ms-vscode.remote-explorer",
        "ms-vscode-remote.remote-wsl",
        "zoocodeorganization.zoo-code"
)
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Packages = @("p1c2u.docker-compose")
}
if ($Packages.Count -eq 0) {
    throw "取得するVS Code拡張機能IDが指定されていません。"
}

<#
.SYNOPSIS
VS Code拡張機能IDからVSIX取得URLを生成します。

.DESCRIPTION
publisher.extension形式をpublisherとextension名へ分解し、Visual Studio Marketplaceのlatest vspackage URLを生成します。

.PARAMETER ExtensionId
publisher.extension形式のVS Code拡張機能IDです。
.PARAMETER Registry
Visual Studio Marketplaceのbase URLです。

.OUTPUTS
VSIX取得URLを文字列として返します。

.NOTES
副作用はありません。不正なIDでは例外を送出します。
#>
function Get-VsixDownloadUrl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Registry,

        [Parameter(Mandatory = $true)]
        [string]$ExtensionId
    )

    $Parts = $ExtensionId.Split([string[]]@("."), 2, [System.StringSplitOptions]::None)
    if ($Parts.Count -ne 2) {
        throw "VS Code拡張機能IDが不正です: $ExtensionId"
    }

    $Publisher = [System.Uri]::EscapeDataString($Parts[0])
    $ExtensionName = [System.Uri]::EscapeDataString($Parts[1])
    return "$Registry/_apis/public/gallery/publishers/$Publisher/vsextensions/$ExtensionName/latest/vspackage"
}

<#
.SYNOPSIS
VS Code拡張機能のVSIX fileを保存します。

.DESCRIPTION
指定した拡張機能IDのlatest VSIXをVisual Studio Marketplaceから取得し、拡張機能IDをfile名にして保存します。

.PARAMETER ExtensionId
publisher.extension形式のVS Code拡張機能IDです。
.PARAMETER Registry
Visual Studio Marketplaceのbase URLです。

.PARAMETER OutputDirectory
VSIX fileの保存先directoryです。

.OUTPUTS
保存したVSIX file pathを文字列として返します。

.NOTES
保存先fileを作成または上書きします。HTTP取得に失敗した場合は例外を送出します。
#>
function Save-VscodeExtension {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Registry,

        [Parameter(Mandatory = $true)]
        [string]$ExtensionId,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory
    )

    $Url = Get-VsixDownloadUrl -Registry $Registry -ExtensionId $ExtensionId
    $OutputPath = Join-Path $OutputDirectory "$ExtensionId.vsix"
    Write-Host "Download VSIX: $ExtensionId"
    Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing
    return $OutputPath
}

$DestinationDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "vscode"
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null

foreach ($ExtensionId in $Packages) {
    Save-VscodeExtension -Registry $Registries[0] -ExtensionId $ExtensionId -OutputDirectory $DestinationDirectory | Out-Null
}

$DownloadedFiles = @(
    Get-ChildItem -Path $DestinationDirectory -Filter "*.vsix" -File -ErrorAction SilentlyContinue
)

if ($DownloadedFiles.Count -eq 0) {
    throw "VSIX fileが作成されませんでした: $DestinationDirectory"
}
