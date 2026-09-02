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
    "@eslint/eslinrc",
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
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Platforms = @(
        [pscustomobject]@{ Name = "linux"; Os = "linux"; Cpu = "x64" }
    )
    $Packages = @("is-number@6.0.0", "is-number@7.0.0")
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
npm packageのOSまたはCPU selectorがtargetに一致するか判定します。
.PARAMETER Selectors
package-lock.jsonに記録されたselectorです。
.PARAMETER Target
判定対象のOSまたはCPUです。
.OUTPUTS
targetへ適用する場合はtrueを返します。
#>
function Test-NpmTargetSelector {
    param(
        [object]$Selectors,
        [Parameter(Mandatory = $true)][string]$Target
    )

    if ($null -eq $Selectors) {
        return $true
    }

    $Values = @($Selectors)
    if ($Values -contains "!$Target") {
        return $false
    }
    $PositiveValues = @($Values | Where-Object { -not ([string]$_).StartsWith("!") })
    return $PositiveValues.Count -eq 0 -or $PositiveValues -contains $Target
}

<#
.SYNOPSIS
package-lock.jsonからtarget platform向けpackage specを取得します。
.PARAMETER LockFile
package-lock.jsonのpathです。
.PARAMETER Platform
target platform情報です。
.OUTPUTS
package URLまたは`name@version`形式のspec配列を返します。
#>
function Get-PackageSpecsFromPackageLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockFile,
        [Parameter(Mandatory = $true)][pscustomobject]$Platform
    )

    $Lock = Get-Content -Raw -LiteralPath $LockFile | ConvertFrom-Json
    $PackagesProperty = $Lock.PSObject.Properties["packages"]
    if (-not $PackagesProperty) {
        return @()
    }

    $Specs = @()
    foreach ($PackageProperty in $PackagesProperty.Value.PSObject.Properties) {
        $PackagePath = $PackageProperty.Name
        $PackageInfo = $PackageProperty.Value
        if (-not $PackagePath -or -not $PackageInfo.version) {
            continue
        }
        if (-not (Test-NpmTargetSelector -Selectors $PackageInfo.os -Target $Platform.Os)) {
            continue
        }
        if (-not (Test-NpmTargetSelector -Selectors $PackageInfo.cpu -Target $Platform.Cpu)) {
            continue
        }

        $Resolved = [string]$PackageInfo.resolved
        if ($Resolved -match "^https?:") {
            $Specs += $Resolved
            continue
        }

        $Name = $PackagePath -replace "^.*node_modules/", ""
        $Specs += "$Name@$($PackageInfo.version)"
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

$OutputDir = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "npm"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$WorkDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "npm-download-$([guid]::NewGuid().ToString("N"))"
$AllPackageSpecs = @()
try {
    New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
    foreach ($Platform in $Platforms) {
        $PlatformWorkDirectory = Join-Path $WorkDirectory $Platform.Name
        New-Item -ItemType Directory -Path $PlatformWorkDirectory -Force | Out-Null

        Push-Location $PlatformWorkDirectory
        try {
            Invoke-NativeCommand -FilePath "npm" -Arguments @("init", "-y") | Out-Null
            $InstallArguments = @(
                "install",
                "--package-lock-only",
                "--ignore-scripts",
                "--registry=$($Registries[0])",
                "--os=$($Platform.Os)",
                "--cpu=$($Platform.Cpu)"
            ) + $InstallPackages
            Write-Host "Resolve npm packages: platform=$($Platform.Name) packages=$($Packages.Count)"
            Invoke-NativeCommand -FilePath "npm" -Arguments $InstallArguments
            $AllPackageSpecs += Get-PackageSpecsFromPackageLock -LockFile (Join-Path $PlatformWorkDirectory "package-lock.json") -Platform $Platform
        } finally {
            Pop-Location
        }
    }

    Push-Location $WorkDirectory
    try {
        foreach ($PackageSpec in @($AllPackageSpecs | Sort-Object -Unique)) {
            Invoke-NativeCommand -FilePath "npm" -Arguments @("pack", $PackageSpec, "--pack-destination", $OutputDir, "--registry=$($Registries[0])", "--silent")
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
