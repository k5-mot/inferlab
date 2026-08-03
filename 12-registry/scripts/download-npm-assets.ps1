$ErrorActionPreference = "Stop"

# npmから依存込みで取得するpackageを定義する。
$NpmPackages = @(
    "@pandacss/dev@^1.12.0",
    "@serendie/design-token@^1.4.6",
    "@serendie/ui@^3.7.0",
    "@testing-library/jest-dom@^7.0.0",
    "@testing-library/react@^16.3.2",
    "@testing-library/user-event@^14.6.1",
    "@types/react@^19.0.0",
    "@types/react-dom@^19.0.0",
    "@vitejs/plugin-react@^5.0.0",
    "@vitest/coverage-v8@^4.1.10",
    "cowsay",
    "figlet",
    "jsdom@^30.0.1",
    "keycloak-js@^26.2.0",
    "lucide-react@^0.468.0",
    "msw@^2.15.0",
    "react@^19.0.0",
    "react-dom@^19.0.0",
    "typescript@^5.7.0",
    "vite@^7.0.0",
    "vite-plus@^0.2.1",
    "vitest@^4.1.10"
)

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDirectory "download-assets-common.ps1")

$AssetsPath = Get-AssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory (Get-Location).Path
Write-Host "assets directory: $AssetsPath"

New-AssetDirectories -AssetsPath $AssetsPath -Names @("npm-packages")
$NpmAssetsDir = Join-Path $AssetsPath "npm-packages"
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
