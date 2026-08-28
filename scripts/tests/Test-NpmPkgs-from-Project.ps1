<#
.SYNOPSIS
from-Project版のnpm package取得をfixtureで検証します。
.PARAMETER Static
network downloadを行わず、interfaceとfixtureだけを検証します。
#>
param (
    [switch]$Static
)

. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$ScriptPath = Join-Path $PSScriptRoot "../Download-NpmPkgs-from-Project.ps1"
$FixturePath = Join-Path $PSScriptRoot "package.json"
$TestParameters = @{
    ScriptPath = $ScriptPath
    ExpectedParameters = @("OutputDir", "ProjectDir", "Help")
    ExpectedOutputDirectory = "npm"
}
Assert-DownloadScript @TestParameters

$Manifest = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
$PackageCount = @($Manifest.dependencies.PSObject.Properties).Count +
    @($Manifest.devDependencies.PSObject.Properties).Count
if ($PackageCount -eq 0) {
    throw "npm検証用fixtureにpackageが定義されていません: $FixturePath"
}

if ($Static) {
    return
}

$OutputBase = Join-Path $PSScriptRoot ".tmp/npm-from-projects"
Remove-Item -LiteralPath $OutputBase -Recurse -Force -ErrorAction SilentlyContinue
& $ScriptPath -OutputDir $OutputBase -ProjectDir $PSScriptRoot

$DownloadedPackages = @(
    Get-ChildItem -LiteralPath (Join-Path $OutputBase "npm") -Filter "*.tgz" -File -ErrorAction SilentlyContinue
)
if ($DownloadedPackages.Count -eq 0) {
    throw "from-Project版のnpm packageが作成されませんでした: $OutputBase"
}
foreach ($UnexpectedPath in @(
    (Join-Path $PSScriptRoot "node_modules"),
    (Join-Path $PSScriptRoot "package-lock.json")
)) {
    if (Test-Path -LiteralPath $UnexpectedPath) {
        throw "npm fixture directoryに作業fileが残っています: $UnexpectedPath"
    }
}
