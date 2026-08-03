<#
.SYNOPSIS
VS Code拡張機能のVSIX fileを取得します。

.DESCRIPTION
Visual Studio Marketplaceから指定した拡張機能のlatest VSIXを取得します。
既定ではInferLabで使う拡張機能を`12-registry/registry/vsix/`へ保存します。

.PARAMETER DestinationDirectory
取得したVSIX fileを保存するdirectoryです。

.PARAMETER ExtensionIds
publisher.extension形式のVS Code拡張機能IDの配列です。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Vscode-Extensions.ps1

既定のVS Code拡張機能を取得します。

.EXAMPLE
.\script\Download-Vscode-Extensions.ps1 -DestinationDirectory .\vsix -ExtensionIds openai.chatgpt,terrastruct.d2

指定したVS Code拡張機能を`vsix/`へ取得します。

.NOTES
副作用として指定directoryへ`.vsix` fileを作成または上書きします。
実行にはPowerShellとVisual Studio MarketplaceへのHTTP接続が必要です。
#>
[CmdletBinding()]
param (
    [string]$DestinationDirectory = (Join-Path $PSScriptRoot "..\12-registry\registry\vsix"),

    [string[]]$ExtensionIds = @(
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
    ),

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"

if ($ExtensionIds.Count -eq 0) {
    throw "取得するVS Code拡張機能IDが指定されていません。"
}

<#
.SYNOPSIS
VS Code拡張機能IDからVSIX取得URLを生成します。

.DESCRIPTION
publisher.extension形式をpublisherとextension名へ分解し、Visual Studio Marketplaceのlatest vspackage URLを生成します。

.PARAMETER ExtensionId
publisher.extension形式のVS Code拡張機能IDです。

.OUTPUTS
VSIX取得URLを文字列として返します。

.NOTES
副作用はありません。不正なIDでは例外を送出します。
#>
function Get-VsixDownloadUrl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ExtensionId
    )

    $Parts = $ExtensionId.Split([string[]]@("."), 2, [System.StringSplitOptions]::None)
    if ($Parts.Count -ne 2) {
        throw "VS Code拡張機能IDが不正です: $ExtensionId"
    }

    $Publisher = [System.Uri]::EscapeDataString($Parts[0])
    $ExtensionName = [System.Uri]::EscapeDataString($Parts[1])
    return "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/$Publisher/vsextensions/$ExtensionName/latest/vspackage"
}

<#
.SYNOPSIS
VS Code拡張機能のVSIX fileを保存します。

.DESCRIPTION
指定した拡張機能IDのlatest VSIXをVisual Studio Marketplaceから取得し、拡張機能IDをfile名にして保存します。

.PARAMETER ExtensionId
publisher.extension形式のVS Code拡張機能IDです。

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
        [string]$ExtensionId,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory
    )

    $Url = Get-VsixDownloadUrl -ExtensionId $ExtensionId
    $OutputPath = Join-Path $OutputDirectory "$ExtensionId.vsix"
    Write-Host "Download VSIX: $ExtensionId"
    Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing
    return $OutputPath
}

$DestinationDirectory = [System.IO.Path]::GetFullPath($DestinationDirectory)
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null

foreach ($ExtensionId in $ExtensionIds) {
    Save-VscodeExtension -ExtensionId $ExtensionId -OutputDirectory $DestinationDirectory | Out-Null
}

$DownloadedFiles = @(
    Get-ChildItem -Path $DestinationDirectory -Filter "*.vsix" -File -ErrorAction SilentlyContinue
)

if ($DownloadedFiles.Count -eq 0) {
    throw "VSIX fileが作成されませんでした: $DestinationDirectory"
}
