<#
.SYNOPSIS
対象project directoryのpackage.jsonからnpm package archiveを取得します。

.DESCRIPTION
対象project directoryの`package.json`を読み、Windows x64とLinux x64向けに依存解決します。
解決されたpackageを`npm pack`で`.tgz`として保存し、Verdaccioへpublishできる資材を作成します。

.PARAMETER OutputDir
取得したnpm package archiveを保存するdirectoryです。

.PARAMETER ProjectDir
package.jsonがあるproject directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-NpmPkgs-from-Project.ps1 -ProjectDir C:\src\project -OutputDir C:\assets

カレントディレクトリのpackage.jsonからregistry投入用`.tgz`を作成します。

.EXAMPLE
.\scripts\Download-NpmPkgs-from-Project.ps1 -ProjectDir C:\src\private-chat\app -OutputDir C:\assets

指定したproject directoryのpackage.jsonからregistry投入用`.tgz`を作成します。

.NOTES
対象project directoryではfileを作成しません。作業fileは一時directoryへ作成し、成果物だけをOutputDirへ保存します。
#>
[CmdletBinding()]
param (
    [string]$OutputDir,

    [string]$ProjectDir,

    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}
if (-not $OutputDir) {
    throw "OutputDir is required."
}
if (-not $ProjectDir) {
    throw "ProjectDir is required."
}

$ErrorActionPreference = "Stop"
$Registries = @(
    "https://registry.npmjs.org"
)
$Packages = @()
$Platforms = @(
    [pscustomobject]@{ Name = "linux"; Os = "linux"; Cpu = "x64" },
    [pscustomobject]@{ Name = "windows"; Os = "win32"; Cpu = "x64" }
)
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Platforms = @(
        [pscustomobject]@{ Name = "linux"; Os = "linux"; Cpu = "x64" }
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
package.jsonからdownload対象のpackage specを取得します。
.PARAMETER Path
package.jsonのpathです。
.OUTPUTS
npm installへ渡すpackage spec配列を返します。
#>
function Get-PackageSpecsFromPackageJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Manifest = Get-Content -Raw -Path $Path | ConvertFrom-Json
    $Specs = @()
    foreach ($Section in @("dependencies", "devDependencies", "optionalDependencies")) {
        $Property = $Manifest.PSObject.Properties[$Section]
        if (-not $Property) {
            continue
        }

        foreach ($Dependency in $Property.Value.PSObject.Properties) {
            $Range = [string]$Dependency.Value
            if ($Range -match "^(workspace|file|link):") {
                continue
            }
            $Specs += "$($Dependency.Name)@$Range"
        }
    }

    return @($Specs | Sort-Object -Unique)
}

<#
.SYNOPSIS
package-lock.jsonからtarget platform向けpackage specを取得します。
.PARAMETER LockFile
package-lock.jsonのpathです。
.PARAMETER Platform
target platform情報です。
.OUTPUTS
`name@version`形式のpackage spec配列を返します。
#>
function Get-PackageSpecsFromPackageLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockFile,
        [Parameter(Mandatory = $true)][pscustomobject]$Platform
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
    $ParserScript = Join-Path ([System.IO.Path]::GetTempPath()) "npm-lock-parser-$([guid]::NewGuid().ToString("N")).js"
    try {
        $Code | Set-Content -LiteralPath $ParserScript -Encoding ascii
        $Specs = Invoke-NativeCommand -FilePath "node" -Arguments @($ParserScript, $LockFile, $Platform.Os, $Platform.Cpu)
    }
    finally {
        Remove-Item -LiteralPath $ParserScript -Force -ErrorAction SilentlyContinue
    }

    return @($Specs | Sort-Object -Unique)
}

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)
if (-not (Test-Path -Path $ProjectDir -PathType Container)) {
    throw "ProjectDir was not found: $ProjectDir"
}

$PackageJsonPath = Join-Path $ProjectDir "package.json"
if (-not (Test-Path -Path $PackageJsonPath -PathType Leaf)) {
    throw "package.json was not found in project directory: $ProjectDir"
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm が見つかりません。Node.jsとnpmをインストールしてください。"
}

$Packages = @(Get-PackageSpecsFromPackageJson -Path $PackageJsonPath)
if ($Packages.Count -eq 0) {
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
            ) + $Packages
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
