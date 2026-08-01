$ErrorActionPreference = "Stop"

# PyPIから依存込みで取得するpackageを定義する。
$PypiPackages = @(
    "python-docx",
    "pypdf",
    "pypandoc"
)

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDirectory "download-assets-common.ps1")

$AssetsPath = Get-AssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory (Get-Location).Path
Write-Host "assets directory: $AssetsPath"

New-AssetDirectories -AssetsPath $AssetsPath -Names @("wheel")
$PypiAssetsDir = Join-Path $AssetsPath "wheel"

Invoke-PythonCommand -Arguments (@("-m", "pip", "download", "--dest", $PypiAssetsDir) + $PypiPackages)
Assert-AssetFilesExist -Directory $PypiAssetsDir -Pattern @("*.whl", "*.tar.gz", "*.zip") -Description "PyPI"
