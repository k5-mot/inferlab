<#
.SYNOPSIS
対象project directoryのpackage.jsonからnpm package archiveを取得します。

.DESCRIPTION
対象project directoryの`package.json`を読み、Windows x64とLinux x64向けに依存解決します。
解決されたpackageを`npm pack`で`.tgz`として保存し、Verdaccioへpublishできる資材を作成します。

.PARAMETER OutputDir
取得したnpm package archiveを保存するdirectoryです。

.PARAMETER ProjectDirectory
package.jsonがあるproject directoryです。省略時はカレントディレクトリです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\Download-Npm-Packages.ps1 -OutputDir C:\assets\12-registry\npm-packages

カレントディレクトリのpackage.jsonからregistry投入用`.tgz`を作成します。

.EXAMPLE
.\Download-Npm-Packages.ps1 -ProjectDirectory C:\src\private-chat\app -OutputDir C:\assets\12-registry\npm-packages

指定したproject directoryのpackage.jsonからregistry投入用`.tgz`を作成します。

.NOTES
対象project directoryではfileを作成しません。作業fileは一時directoryへ作成し、成果物だけをOutputDirへ保存します。
#>
[CmdletBinding()]
param (
    [string]$OutputDir,

    [string]$ProjectDirectory = (Get-Location).Path,

    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"
$Platforms = @(
    [pscustomobject]@{ Name = "linux"; Os = "linux"; Cpu = "x64" },
    [pscustomobject]@{ Name = "windows"; Os = "win32"; Cpu = "x64" }
)

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
package-lock.jsonからpackage specを取得します。
.PARAMETER LockFile
package-lock.jsonのpathです。
.OUTPUTS
`package.json`の`os`または`cpu`条件がtargetに一致するかを返します。
#>
function Test-NpmPackageSelector {
    param(
        [object]$Values,
        [Parameter(Mandatory = $true)][string]$Target
    )

    if (-not $Values) {
        return $true
    }

    $Selectors = @($Values)
    if ($Selectors -contains "!$Target") {
        return $false
    }

    $PositiveSelectors = @()
    foreach ($Selector in $Selectors) {
        if (-not ([string]$Selector).StartsWith("!")) {
            $PositiveSelectors += $Selector
        }
    }

    return $PositiveSelectors.Count -eq 0 -or $PositiveSelectors -contains $Target
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

    $Lock = Get-Content -Raw -Path $LockFile | ConvertFrom-Json -AsHashtable
    $Specs = @()
    foreach ($PackagePath in $Lock.packages.Keys) {
        $Package = $Lock.packages[$PackagePath]
        if (-not $PackagePath -or -not $Package.ContainsKey("version")) {
            continue
        }
        if ($Package.ContainsKey("os") -and -not (Test-NpmPackageSelector -Values $Package["os"] -Target $Platform.Os)) {
            continue
        }
        if ($Package.ContainsKey("cpu") -and -not (Test-NpmPackageSelector -Values $Package["cpu"] -Target $Platform.Cpu)) {
            continue
        }

        $Name = $PackagePath -replace "^.*node_modules/", ""
        $Specs += "$Name@$($Package["version"])"
    }

    return @($Specs | Sort-Object -Unique)
}

if (-not $OutputDir) {
    throw "OutputDir is required."
}

$ProjectDirectory = [System.IO.Path]::GetFullPath($ProjectDirectory)
if (-not (Test-Path -Path $ProjectDirectory -PathType Container)) {
    throw "ProjectDirectory was not found: $ProjectDirectory"
}

$PackageJsonPath = Join-Path $ProjectDirectory "package.json"
if (-not (Test-Path -Path $PackageJsonPath -PathType Leaf)) {
    throw "package.json was not found in project directory: $ProjectDirectory"
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm が見つかりません。Node.jsとnpmをインストールしてください。"
}

$Packages = Get-PackageSpecsFromPackageJson -Path $PackageJsonPath
if ($Packages.Count -eq 0) {
    throw "取得するnpm packageが指定されていません。"
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
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
            Invoke-NativeCommand -FilePath "npm" -Arguments @("pack", $PackageSpec, "--pack-destination", $OutputDir, "--silent")
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
