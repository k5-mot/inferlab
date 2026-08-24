<#
.SYNOPSIS
Difyのair-gap運用に必要なpluginとPython依存packageを取得します。

.DESCRIPTION
lock fileで固定した署名付き`.difypkg`をDify Marketplaceから取得し、SHA-256を検証します。
plugin内の`requirements.txt`も検証し、plugin daemonのPython 3.12 Linux x86_64環境向けwheelを取得します。

.PARAMETER PluginDirectory
検証済み`.difypkg`とchecksum一覧を保存するdirectoryです。

.PARAMETER PackageDirectory
plugin依存wheelとchecksum一覧を保存するpypiserver用directoryです。

.PARAMETER LockFile
plugin、取得URL、checksum、target platformを固定したJSON fileです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Dify-Plugins.ps1

repository既定のpluginを`/srv/21-dify/plugins`へ、依存wheelを`/srv/12-registry/pypi`へ取得します。

.EXAMPLE
.\script\Download-Dify-Plugins.ps1 -PluginDirectory .\airgap\dify\plugins -PackageDirectory .\airgap\pypi

Windows client上の転送用directoryへair-gap資材を取得します。

.NOTES
副作用として指定directoryへfileを作成または上書きします。
実行にはPowerShell、Python 3、pip、Internet接続が必要です。
#>
[CmdletBinding()]
param (
    [string]$PluginDirectory = "/srv/21-dify/plugins",

    [string]$PackageDirectory = "/srv/12-registry/pypi",

    [string]$LockFile = (Join-Path $PSScriptRoot "../21-dify/plugins/plugins.lock.json"),

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "python が見つかりません。Python 3とpipをインストールしてください。"
}

$LockFile = [System.IO.Path]::GetFullPath($LockFile)
$PluginDirectory = [System.IO.Path]::GetFullPath($PluginDirectory)
$PackageDirectory = [System.IO.Path]::GetFullPath($PackageDirectory)

if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf)) {
    throw "plugin lock fileが見つかりません: $LockFile"
}

$PluginLock = Get-Content -LiteralPath $LockFile -Raw | ConvertFrom-Json
if ($PluginLock.schemaVersion -ne 1 -or $PluginLock.plugins.Count -eq 0) {
    throw "未対応または空のplugin lock fileです: $LockFile"
}

New-Item -ItemType Directory -Path $PluginDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null

$TemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("dify-plugin-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TemporaryDirectory -Force | Out-Null

try {
    foreach ($Plugin in $PluginLock.plugins) {
        $PluginPath = Join-Path $PluginDirectory $Plugin.fileName
        Write-Host "Download Dify plugin: $($Plugin.uniqueIdentifier)"
        Invoke-WebRequest -Uri $Plugin.url -OutFile $PluginPath

        $ActualPluginHash = (Get-FileHash -LiteralPath $PluginPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualPluginHash -ne $Plugin.sha256.ToLowerInvariant()) {
            throw "plugin checksumが一致しません: $PluginPath"
        }

        $RequirementsPath = Join-Path $TemporaryDirectory ("$($Plugin.id.Replace('/', '-'))-requirements.txt")
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

        $PipArguments = @(
            "-m",
            "pip",
            "download",
            "--requirement",
            $RequirementsPath,
            "--dest",
            $PackageDirectory,
            "--python-version",
            $PluginLock.target.pythonVersion.Replace(".", ""),
            "--implementation",
            $PluginLock.target.implementation,
            "--abi",
            $PluginLock.target.abi,
            "--only-binary=:all:"
        )

        foreach ($Platform in $PluginLock.target.platforms) {
            $PipArguments += @("--platform", $Platform)
        }

        python @PipArguments
        if ($LASTEXITCODE -ne 0) {
            throw "plugin依存wheelの取得に失敗しました: $($Plugin.id)"
        }
    }
}
finally {
    Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$PluginChecksumLines = Get-ChildItem -LiteralPath $PluginDirectory -Filter "*.difypkg" -File |
    Sort-Object -Property Name |
    ForEach-Object { "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name }
$PluginChecksumLines | Set-Content -LiteralPath (Join-Path $PluginDirectory "SHA256SUMS") -Encoding ascii

$PackageChecksumLines = Get-ChildItem -LiteralPath $PackageDirectory -Filter "*.whl" -File |
    Sort-Object -Property Name |
    ForEach-Object { "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name }
if ($PackageChecksumLines.Count -eq 0) {
    throw "plugin依存wheelが作成されませんでした: $PackageDirectory"
}
$PackageChecksumLines | Set-Content -LiteralPath (Join-Path $PackageDirectory "DIFY_PLUGIN_SHA256SUMS") -Encoding ascii

Write-Host "Dify air-gap plugin assets are ready."
Write-Host "Plugins: $PluginDirectory"
Write-Host "Python packages: $PackageDirectory"
