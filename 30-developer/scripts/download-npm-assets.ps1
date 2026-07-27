$ErrorActionPreference = "Stop"

# npmから依存込みで取得するpackageを定義する。
$NpmPackages = @(
    "cowsay"
)

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDirectory "download-assets-common.ps1")

$AssetsPath = Get-AssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory (Get-Location).Path
Write-Host "assets directory: $AssetsPath"

New-AssetDirectories -AssetsPath $AssetsPath -Names @("npm")
$NpmAssetsDir = Join-Path $AssetsPath "npm"
$NpmWorkDir = Join-Path (Join-Path (Split-Path -Parent $AssetsPath) ".npm-works") "npm-assets"
New-Item -ItemType Directory -Force -Path $NpmWorkDir | Out-Null

Push-Location $NpmWorkDir
try {
    Invoke-NativeCommand -FilePath "npm" -Arguments @("init", "-y") | Out-Null
    Invoke-NativeCommand -FilePath "npm" -Arguments (@("install", "--package-lock-only", "--ignore-scripts") + $NpmPackages)

    $NpmPackageSpecs = Invoke-NativeCommand -FilePath "node" -Arguments @(
        "-e",
        "const lock=require('./package-lock.json'); for (const [k,p] of Object.entries(lock.packages)) { if (k && p.resolved && p.version) console.log(k.split('node_modules/').pop()+'@'+p.version); }"
    )

    foreach ($PackageSpec in $NpmPackageSpecs) {
        Invoke-NativeCommand -FilePath "npm" -Arguments @("pack", $PackageSpec, "--pack-destination", $NpmAssetsDir)
    }
} finally {
    Pop-Location
}

Assert-AssetFilesExist -Directory $NpmAssetsDir -Pattern "*.tgz" -Description "npm"
