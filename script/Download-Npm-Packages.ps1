<#
.SYNOPSIS
Linux x64向けのnpm package archiveを取得します。

.DESCRIPTION
`npm install --package-lock-only`でLinux x64向けの依存解決を行い、lockfileに記録されたpackageを`npm pack`で`.tgz`として保存します。
既定ではfrontend開発と確認に必要なnpm packageと依存packageを`/srv/12-registry/npm-packages/`へ保存します。

.PARAMETER DestinationDirectory
取得したnpm package archiveを保存するdirectoryです。

.PARAMETER Packages
取得するnpm package specの配列です。

.PARAMETER Os
npmへ渡すtarget OSです。

.PARAMETER Cpu
npmへ渡すtarget CPUです。

.PARAMETER Libc
npmへ渡すtarget libcです。

.PARAMETER WorkDirectory
依存解決用の一時work directoryです。既定では`/srv/12-registry/npm-work/`を使います。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Npm-Packages.ps1

既定のnpm packageをLinux x64向けに取得します。

.EXAMPLE
.\script\Download-Npm-Packages.ps1 -DestinationDirectory .\npm -Packages cowsay,figlet

指定したnpm packageを`npm/`へ取得します。

.NOTES
副作用として指定directoryとwork directoryへfileを作成または上書きします。
実行にはPowerShell、Node.js、npmが必要です。
#>
[CmdletBinding()]
param (
    [string]$DestinationDirectory = "/srv/12-registry/npm-packages",

    [string[]]$Packages = @(
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
    ),

    [string]$Os = "linux",

    [string]$Cpu = "x64",

    [string]$Libc = "glibc",

    [string]$WorkDirectory = "/srv/12-registry/npm-work",

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"

if ($Packages.Count -eq 0) {
    throw "取得するnpm packageが指定されていません。"
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm が見つかりません。Node.jsとnpmをインストールしてください。"
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "node が見つかりません。Node.jsをインストールしてください。"
}

$DestinationDirectory = [System.IO.Path]::GetFullPath($DestinationDirectory)
$WorkDirectory = [System.IO.Path]::GetFullPath($WorkDirectory)
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null

Push-Location $WorkDirectory
try {
    Remove-Item -Force -ErrorAction SilentlyContinue "package.json", "package-lock.json"

    npm init -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "npm init に失敗しました。"
    }

    $InstallArguments = @(
        "install",
        "--package-lock-only",
        "--ignore-scripts",
        "--os=$Os",
        "--cpu=$Cpu",
        "--libc=$Libc"
    ) + $Packages

    Write-Host "Resolve npm packages: $($Packages -join ', ')"
    npm @InstallArguments
    if ($LASTEXITCODE -ne 0) {
        throw "npm install に失敗しました。"
    }

    $PackageSpecs = @(
        node -e "const lock=require('./package-lock.json'); for (const [key, pkg] of Object.entries(lock.packages || {})) { if (key && pkg.resolved && pkg.version) console.log(key.split('node_modules/').pop() + '@' + pkg.version); }"
    )
    if ($LASTEXITCODE -ne 0) {
        throw "package-lock.jsonの解析に失敗しました。"
    }

    foreach ($PackageSpec in $PackageSpecs) {
        npm pack $PackageSpec --pack-destination $DestinationDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "npm pack に失敗しました: $PackageSpec"
        }
    }
} finally {
    Pop-Location
}

$DownloadedFiles = @(
    Get-ChildItem -Path $DestinationDirectory -Filter "*.tgz" -File -ErrorAction SilentlyContinue
)

if ($DownloadedFiles.Count -eq 0) {
    throw "npm package archiveが作成されませんでした: $DestinationDirectory"
}
