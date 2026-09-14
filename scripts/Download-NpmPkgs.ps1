<#
.SYNOPSIS
このrepositoryのair-gap運用に必要なnpm package資材を取得します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-NpmPkgs.ps1 -OutputDir C:\airgap

script内のpackage listからnpm packageを`C:\airgap\npm`へ取得します。

.NOTES
npm cacheと一時fileはOutputDirと同じvolumeへ作成し、処理終了時に削除します。
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
    "https://registry.npmjs.org"
)
$Platforms = @(
    [pscustomobject]@{ Name = "linux"; Os = "linux"; Cpu = "x64" },
    [pscustomobject]@{ Name = "windows"; Os = "win32"; Cpu = "x64" }
)
$Packages = @(
    "@eslint/eslintrc",
    "@fission-ai/openspec@1.7.0",
    "@pandacss/dev@^1.12.0",
    "@serendie/design-token@^1.4.6",
    "@serendie/symbols@^1.0.3",
    "@serendie/ui@^3.7.0",
    "@testing-library/jest-dom@^7.0.0",
    "@testing-library/react@^16.3.2",
    "@testing-library/user-event@^14.6.1",
    "@types/cytoscape@3.21.9",
    "@types/js-yaml@4.0.9",
    "@types/node@20",
    "@types/node@24.10.1",
    "@types/react-dom@18",
    "@types/react-dom@19",
    "@types/react-dom@^19.0.0",
    "@types/react@18",
    "@types/react@19",
    "@types/react@^19.0.0",
    "@vitejs/plugin-react@^5.0.0",
    "@vitest/coverage-v8@^4.1.10",
    "clsx",
    "croner@10.0.1",
    "cytoscape@3.33.1",
    "esbuild@0.25.9",
    "eslint",
    "eslint-config-next",
    "gray-matter@4.0.3",
    "js-yaml@4.1.0",
    "jsdom@^30.0.1",
    "keycloak-js@^26.2.0",
    "llm-wiki-compiler@1.1.0",
    "lucide@0.544.0",
    "mint@4.2.821",
    "msw@^2.15.0",
    "next@15",
    "next@16",
    "pnpm@11.18.0",
    "postcss@4",
    "react-dom@^19.0.0",
    "react-hook-form",
    "react@18",
    "react@19",
    "react@^19.0.0",
    "skills@1.5.21",
    "tailwind-merge",
    "tailwindcss@4",
    "typescript@5",
    "typescript@5.9.2",
    "typescript@6",
    "typescript@7",
    "vite-plus@^0.2.1",
    "vite@^7.0.0",
    "vitest@^4.1.10",
    "zod@4.4.3",
    "zustand"
)
if ($env:DOWNLOAD_TEST) {
    $Platforms = @(
        [pscustomobject]@{ Name = "linux"; Os = "linux"; Cpu = "x64" }
    )
    $Packages = @(
        "@types/react@18",
        "@types/react-dom@19",
        "is-number@6.0.0",
        "is-number@7.0.0",
        "tailwindcss@4"
    )
}

<#
.SYNOPSIS
外部commandを実行し、終了codeを検証します。
.PARAMETER FilePath
実行するcommand名またはpathです。
.PARAMETER Arguments
commandへ渡すargument配列です。
.OUTPUTS
commandの標準出力を返します。
#>
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        throw "required command was not found: $FilePath"
    }

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

<#
.SYNOPSIS
同名packageの複数versionをnpm aliasへ変換します。
.PARAMETER PackageSpecs
変換するnpm package spec配列です。
.OUTPUTS
npm installへ渡すpackage spec配列を返します。
#>
function ConvertTo-NpmInstallSpecs {
    param(
        [Parameter(Mandatory = $true)][string[]]$PackageSpecs
    )

    $ParsedPackages = foreach ($PackageSpec in $PackageSpecs) {
        if ($PackageSpec -notmatch "^(@[^/\s]+/[^@\s]+|[^@\s]+)(?:@(\S+))?$") {
            throw "npm package specが不正です: $PackageSpec"
        }

        [pscustomobject]@{
            Name = $Matches[1]
            Range = $Matches[2]
            Original = $PackageSpec
        }
    }

    $PackageCounts = @{}
    foreach ($Package in $ParsedPackages) {
        if (-not $PackageCounts.ContainsKey($Package.Name)) {
            $PackageCounts[$Package.Name] = 0
        }
        $PackageCounts[$Package.Name] += 1
    }

    $UsedAliases = @{}
    foreach ($Package in $ParsedPackages) {
        if ($PackageCounts[$Package.Name] -eq 1) {
            $Package.Original
            continue
        }

        $Range = if ($Package.Range) { $Package.Range } else { "latest" }
        $AliasBase = (($Package.Name -replace "^@", "") -replace "/", "-")
        $AliasSuffix = (($Range -replace "^[\^~]", "") -replace "[^A-Za-z0-9._-]", "-").Trim("-")
        if (-not $AliasSuffix) {
            $AliasSuffix = "latest"
        }
        $Alias = "$AliasBase-$AliasSuffix"
        $AliasIndex = 2
        while ($UsedAliases.ContainsKey($Alias)) {
            $Alias = "$AliasBase-$AliasSuffix-$AliasIndex"
            $AliasIndex += 1
        }
        $UsedAliases[$Alias] = $true
        "$Alias@npm:$($Package.Name)@$Range"
    }
}

<#
.SYNOPSIS
package-lock.jsonからtarget platform向けpackage specを取得します。
.PARAMETER LockFile
package-lock.jsonのpathです。
.PARAMETER Platform
target platform情報です。
.PARAMETER ParserDirectory
一時parserを作成するdirectoryです。
.OUTPUTS
package URLまたは`name@version`形式のspec配列を返します。
#>
function Get-PackageSpecsFromPackageLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockFile,
        [Parameter(Mandatory = $true)][pscustomobject]$Platform,
        [Parameter(Mandatory = $true)][string]$ParserDirectory
    )

    $Code = @'
const fs = require("fs");
const lock = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const os = process.argv[3];
const cpu = process.argv[4];
function selectorMatches(values, target) {
  if (!values) return true;
  const selectors = Array.isArray(values) ? values : [values];
  if (selectors.includes(`!${target}`)) return false;
  const positives = selectors.filter((value) => !String(value).startsWith("!"));
  return positives.length === 0 || positives.includes(target);
}
for (const [packagePath, packageInfo] of Object.entries(lock.packages || {})) {
  if (!packagePath || !packageInfo.version) continue;
  if (!selectorMatches(packageInfo.os, os)) continue;
  if (!selectorMatches(packageInfo.cpu, cpu)) continue;
  if (packageInfo.resolved && /^https?:/.test(packageInfo.resolved)) {
    console.log(packageInfo.resolved);
  } else {
    const name = packagePath.replace(/^.*node_modules\//, "");
    console.log(`${name}@${packageInfo.version}`);
  }
}
'@
    $ParserScript = Join-Path $ParserDirectory "npm-lock-parser-$([guid]::NewGuid().ToString("N")).cjs"
    try {
        $Code | Set-Content -LiteralPath $ParserScript -Encoding ascii
        $Specs = Invoke-NativeCommand -FilePath "node" -Arguments @($ParserScript, $LockFile, $Platform.Os, $Platform.Cpu)
    }
    finally {
        Remove-Item -LiteralPath $ParserScript -Force -ErrorAction SilentlyContinue
    }

    return @($Specs | Sort-Object -Unique)
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm が見つかりません。Node.jsとnpmをインストールしてください。"
}

$InstallPackages = @(ConvertTo-NpmInstallSpecs -PackageSpecs $Packages)
if ($InstallPackages.Count -eq 0) {
    throw "取得するnpm packageが指定されていません。"
}

$OutputRoot = [System.IO.Path]::GetFullPath($OutputDir)
$OutputDir = Join-Path $OutputRoot "npm"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$WorkDirectory = Join-Path $OutputRoot ".npm-download-$([guid]::NewGuid().ToString("N"))"
$CacheDirectory = Join-Path $WorkDirectory "cache"
$AllPackageSpecs = @()
try {
    New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    '{ "private": true }' | Set-Content -LiteralPath (Join-Path $WorkDirectory "package.json") -Encoding ascii
    foreach ($Platform in $Platforms) {
        $PlatformWorkDirectory = Join-Path $WorkDirectory $Platform.Name
        New-Item -ItemType Directory -Path $PlatformWorkDirectory -Force | Out-Null

        Push-Location $PlatformWorkDirectory
        try {
            '{ "private": true }' | Set-Content -LiteralPath "package.json" -Encoding ascii
            $InstallArguments = @(
                "install",
                "--package-lock-only",
                "--ignore-scripts",
                "--legacy-peer-deps",
                "--registry=$($Registries[0])",
                "--cache=$CacheDirectory",
                "--os=$($Platform.Os)",
                "--cpu=$($Platform.Cpu)"
            ) + $InstallPackages
            Write-Host "Resolve npm packages: platform=$($Platform.Name) packages=$($Packages.Count)"
            Invoke-NativeCommand -FilePath "npm" -Arguments $InstallArguments
            $AllPackageSpecs += Get-PackageSpecsFromPackageLock `
                -LockFile (Join-Path $PlatformWorkDirectory "package-lock.json") `
                -Platform $Platform `
                -ParserDirectory $WorkDirectory
        } finally {
            Pop-Location
        }
    }

    Push-Location $WorkDirectory
    try {
        foreach ($PackageSpec in @($AllPackageSpecs | Sort-Object -Unique)) {
            Invoke-NativeCommand -FilePath "npm" -Arguments @("pack", $PackageSpec, "--pack-destination", $OutputDir, "--registry=$($Registries[0])", "--cache=$CacheDirectory", "--allow-remote=all", "--silent")
        }
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -Recurse -Force -Path $WorkDirectory -ErrorAction SilentlyContinue
}

$DownloadedFiles = @(
    Get-ChildItem -Path $OutputDir -Filter "*.tgz" -File -ErrorAction SilentlyContinue
)

if ($DownloadedFiles.Count -eq 0) {
    throw "npm package archiveが作成されませんでした: $OutputDir"
}
