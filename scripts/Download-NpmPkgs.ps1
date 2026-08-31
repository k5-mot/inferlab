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
$Packages = @(
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
    "@types/node@24.10.1",
    "@types/react-dom@^19.0.0",
    "@types/react@^19.0.0",
    "@vitejs/plugin-react@^5.0.0",
    "@vitest/coverage-v8@^4.1.10",
    "croner@10.0.1",
    "cytoscape@3.33.1",
    "esbuild@0.25.9",
    "gray-matter@4.0.3",
    "js-yaml@4.1.0",
    "jsdom@^30.0.1",
    "keycloak-js@^26.2.0",
    "llm-wiki-compiler@1.1.0",
    "lucide@0.544.0",
    "mint@4.2.821",
    "msw@^2.15.0",
    "pnpm@11.18.0",
    "react-dom@^19.0.0",
    "react@^19.0.0",
    "skills@1.5.21",
    "typescript@5.9.2",
    "vite-plus@^0.2.1",
    "vite@^7.0.0",
    "vitest@^4.1.10",
    "zod@4.4.3"
)
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Packages = @("is-number@7.0.0")
}

<#
.SYNOPSIS
script内のpackage listを共通download処理へ渡します。
.PARAMETER Packages
npm installへ渡すpackage spec配列です。
.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。
.OUTPUTS
値を返しません。
.NOTES
一時directoryへpackage.jsonを作成し、downloadに失敗した場合は例外を送出します。
#>
function Invoke-PackageListDownload {
    param (
        [Parameter(Mandatory = $true)][string[]]$Packages,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    $DownloaderPath = Join-Path $PSScriptRoot "Download-NpmPkgs-from-Project.ps1"
    $ProjectDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repository-npm-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
        $Dependencies = [ordered]@{}
        foreach ($Package in $Packages) {
            if ($Package -notmatch "^(@[^/]+/[^@]+|[^@]+)@(.+)$") {
                throw "npm package specが不正です: $Package"
            }
            $Dependencies[$Matches[1]] = $Matches[2]
        }
        [ordered]@{
            private = $true
            dependencies = $Dependencies
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProjectDir "package.json") -Encoding ascii
        & $DownloaderPath -ProjectDir $ProjectDir -OutputDir $OutputDir
    }
    finally {
        Remove-Item -LiteralPath $ProjectDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
Invoke-PackageListDownload -Packages $Packages -OutputDir $OutputDir
