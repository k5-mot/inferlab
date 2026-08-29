$ErrorActionPreference = "Stop"

# 実行するregistry別download scriptを定義する。
$DownloadScripts = @(
    "download-pypi-assets.ps1",
    "download-npm-assets.ps1",
    "download-rpm-assets.ps1",
    "download-deb-assets.ps1",
    "download-docker-assets.ps1"
)

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

foreach ($ScriptName in $DownloadScripts) {
    & (Join-Path $ScriptDirectory $ScriptName)
}

Write-Host "download completed"
