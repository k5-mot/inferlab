<#
.SYNOPSIS
このrepositoryのair-gap運用に必要なPython package資材を取得します。

.DESCRIPTION
Dify plugin packageに内包されたrequirements.txtと、private-chat APIのpyproject.tomlを依存定義として使用します。
各依存定義はDownload-Pip-from-Projects.ps1へ渡し、Python 3.12から3.15の対象platform向けarchiveを取得します。

.PARAMETER OutputDir
取得したpackage archiveを保存するpypiserver用directoryです。

.PARAMETER PluginDirectory
検証済みDify plugin packageがあるdirectoryです。

.PARAMETER PluginLockFile
Dify plugin packageとchecksumを固定したJSON fileです。

.PARAMETER PrivateChatPyprojectUrl
private-chat APIのpyproject.tomlを取得するURLです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Pip-Packages.ps1

repository既定のDify pluginとprivate-chat APIに必要なpackage資材を`/srv/12-registry/pypi`へ取得します。

.EXAMPLE
.\script\Download-Pip-Packages.ps1 -OutputDir .\airgap\pypi -PluginDirectory .\airgap\dify\plugins

Windows client上の転送用directoryへpackage資材を取得します。

.NOTES
先にDownload-Dify-Plugins.ps1を実行し、checksum検証済みplugin packageを用意する必要があります。
副作用として指定directoryへpackage archiveを作成または上書きします。
#>
[CmdletBinding()]
param (
    [string]$OutputDir = "/srv/12-registry/pypi",

    [string]$PluginDirectory = "/srv/21-dify/plugins",

    [string]$PluginLockFile = (Join-Path $PSScriptRoot "../21-dify/plugins/plugins.lock.json"),

    [string]$PrivateChatPyprojectUrl = "https://raw.githubusercontent.com/k5-mot/private-chat/main/api/pyproject.toml",

    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

<#
.SYNOPSIS
projectの依存定義を共通download処理へ渡します。
.PARAMETER ProjectDirectory
pyproject.tomlまたはrequirements.txtがあるproject directoryです。
.PARAMETER OutputDir
package archiveの保存先directoryです。
.OUTPUTS
値を返しません。
.NOTES
保存先へpackage archiveを作成または上書きし、downloadに失敗した場合は例外を送出します。
#>
function Invoke-ProjectPackageDownload {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDirectory,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    $DownloaderPath = Join-Path $PSScriptRoot "Download-Pip-from-Projects.ps1"
    if (-not (Test-Path -LiteralPath $DownloaderPath -PathType Leaf)) {
        throw "project用PyPI download scriptが見つかりません: $DownloaderPath"
    }

    & $DownloaderPath -ProjectDirectory $ProjectDirectory -OutputDir $OutputDir
}

$PluginLockFile = [System.IO.Path]::GetFullPath($PluginLockFile)
$PluginDirectory = [System.IO.Path]::GetFullPath($PluginDirectory)
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

if (-not (Test-Path -LiteralPath $PluginLockFile -PathType Leaf)) {
    throw "plugin lock fileが見つかりません: $PluginLockFile"
}

$PluginLock = Get-Content -LiteralPath $PluginLockFile -Raw | ConvertFrom-Json
if ($PluginLock.schemaVersion -ne 1 -or $PluginLock.plugins.Count -eq 0) {
    throw "未対応または空のplugin lock fileです: $PluginLockFile"
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$TemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("repository-pip-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TemporaryDirectory -Force | Out-Null

try {
    $PluginNumber = 0
    foreach ($Plugin in $PluginLock.plugins) {
        $PluginNumber += 1
        $PluginPath = Join-Path $PluginDirectory $Plugin.fileName
        if (-not (Test-Path -LiteralPath $PluginPath -PathType Leaf)) {
            throw "Dify plugin packageが見つかりません。先にDownload-Dify-Plugins.ps1を実行してください: $PluginPath"
        }

        $ActualPluginHash = (Get-FileHash -LiteralPath $PluginPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualPluginHash -ne $Plugin.sha256.ToLowerInvariant()) {
            throw "plugin checksumが一致しません: $PluginPath"
        }

        $PluginProjectDirectory = Join-Path $TemporaryDirectory "dify-plugin-$PluginNumber"
        New-Item -ItemType Directory -Path $PluginProjectDirectory -Force | Out-Null
        $RequirementsPath = Join-Path $PluginProjectDirectory "requirements.txt"
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($PluginPath)
        try {
            $RequirementsEntry = $Archive.GetEntry("requirements.txt")
            if ($null -eq $RequirementsEntry) {
                throw "pluginにrequirements.txtが含まれていません: $PluginPath"
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($RequirementsEntry, $RequirementsPath, $true)
        }
        finally {
            $Archive.Dispose()
        }

        $ActualRequirementsHash = (Get-FileHash -LiteralPath $RequirementsPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualRequirementsHash -ne $Plugin.requirementsSha256.ToLowerInvariant()) {
            throw "requirements.txtのchecksumが一致しません: $PluginPath"
        }

        Write-Host "Download Dify plugin dependencies: $($Plugin.id) $($Plugin.version)"
        Invoke-ProjectPackageDownload -ProjectDirectory $PluginProjectDirectory -OutputDir $OutputDir
    }

    $PrivateChatProjectDirectory = Join-Path $TemporaryDirectory "private-chat-api"
    New-Item -ItemType Directory -Path $PrivateChatProjectDirectory -Force | Out-Null
    Write-Host "Download private-chat dependency definition: $PrivateChatPyprojectUrl"
    Invoke-WebRequest -Uri $PrivateChatPyprojectUrl -OutFile (Join-Path $PrivateChatProjectDirectory "pyproject.toml")
    Invoke-ProjectPackageDownload -ProjectDirectory $PrivateChatProjectDirectory -OutputDir $OutputDir
}
finally {
    Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$DownloadedFiles = @(
    Get-ChildItem -Path $OutputDir -File -Include "*.whl", "*.tar.gz", "*.zip" -Recurse -ErrorAction SilentlyContinue
)
if ($DownloadedFiles.Count -eq 0) {
    throw "PyPI package archiveが作成されませんでした: $OutputDir"
}

Write-Host "Repository PyPI assets are ready: $OutputDir"
