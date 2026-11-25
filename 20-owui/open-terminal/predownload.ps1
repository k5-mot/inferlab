<#
.SYNOPSIS
Open Terminal派生imageを閉域でbuildするための資材を取得します。

.DESCRIPTION
`npm/package-lock.json`で固定したPi coding agentとOfficeCLIのnpm archiveと、
OfficeCLIのLinux x64 release binaryを取得します。binaryはrelease付属の`SHA256SUMS`で検証し、
`Dockerfile.offline`が`sha256sum -c`で再検証できる`officecli-linux-x64.sha256`を作成します。
取得した`OutputDir`を閉域のrepositoryの`20-owui/open-terminal/offline`へ配置してから、
`Dockerfile.offline`でbuildします。

.PARAMETER OutputDir
資材を保存するdirectoryです。既定値はこのscriptと同じdirectoryの`offline`です。
`npm`と`officecli`のsub directoryを作成し、既存fileは上書きします。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File 20-owui/open-terminal/predownload.ps1

`20-owui/open-terminal/offline`へ資材を取得します。

.NOTES
Node.jsとnpm、およびnpm registryとGitHubへの接続が必要です。
base imageの`ghcr.io/open-webui/open-terminal`は`scripts/Download-DockerImages.ps1`で取得します。
#>
[CmdletBinding()]
param (
    [string]$OutputDir = (Join-Path $PSScriptRoot "offline"),

    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$NpmProjectDir = Join-Path $PSScriptRoot "npm"
$OfficeCliRepository = "https://github.com/iOfficeAI/OfficeCLI"
$OfficeCliAsset = "officecli-linux-x64"

<#
.SYNOPSIS
npm projectのpackage.jsonから、固定したOfficeCLIのversionを取得します。
.PARAMETER PackageJsonPath
package.jsonのpathです。
.OUTPUTS
OfficeCLIのversion文字列を返します。
#>
function Get-OfficeCliVersion {
    param(
        [Parameter(Mandatory = $true)][string]$PackageJsonPath
    )

    $Manifest = Get-Content -Raw -Path $PackageJsonPath | ConvertFrom-Json
    $Version = [string]$Manifest.dependencies.'@officecli/officecli'
    if ($Version -notmatch "^\d+\.\d+\.\d+$") {
        throw "@officecli/officecliのversionは完全固定 (x.y.z) で指定してください: $Version"
    }
    return $Version
}

<#
.SYNOPSIS
OfficeCLIのrelease binaryを取得し、release付属のSHA256SUMSで検証します。
.PARAMETER Version
OfficeCLIのversionです。npm packageのversionとrelease tagは一致します。
.PARAMETER Destination
binaryとchecksum fileを保存するdirectoryです。
.OUTPUTS
なし。検証に失敗した場合は例外を送出し、取得したbinaryを削除します。
#>
function Save-OfficeCliBinary {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $ReleaseUrl = "$OfficeCliRepository/releases/download/v$Version"
    $BinaryPath = Join-Path $Destination $OfficeCliAsset
    $SumsPath = Join-Path $Destination "SHA256SUMS"

    Write-Host "Download OfficeCLI binary: v$Version $OfficeCliAsset"
    Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseUrl/$OfficeCliAsset" -OutFile $BinaryPath
    Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseUrl/SHA256SUMS" -OutFile $SumsPath

    # SHA256SUMSは`<hex>  <name>`形式。file名の列を完全一致で照合する。
    $Expected = $null
    foreach ($Line in Get-Content -Path $SumsPath) {
        $Parts = $Line.Trim() -split "\s+"
        if ($Parts.Count -ge 2 -and $Parts[1].TrimStart("*") -eq $OfficeCliAsset) {
            $Expected = $Parts[0].ToLowerInvariant()
            break
        }
    }
    if (-not $Expected) {
        throw "SHA256SUMSに$OfficeCliAsset がありません: $ReleaseUrl/SHA256SUMS"
    }

    $Actual = (Get-FileHash -Algorithm SHA256 -Path $BinaryPath).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) {
        Remove-Item -Force -Path $BinaryPath
        throw "OfficeCLI binaryのchecksumが一致しません (expected $Expected, actual $Actual)"
    }

    # Dockerfile.offlineの`sha256sum -c`が読む形式で保存する。改行はLFにする。
    $ChecksumLine = "$Expected  $OfficeCliAsset`n"
    [System.IO.File]::WriteAllText((Join-Path $Destination "$OfficeCliAsset.sha256"), $ChecksumLine)
    Remove-Item -Force -Path $SumsPath
    Write-Host "OfficeCLI binary verified: $Expected"
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# package-lock.jsonのLinux x64向けpackageを<OutputDir>/npmへ`.tgz`として保存する。
& (Join-Path $RepositoryRoot "scripts/Download-NpmPkgs-from-Project.ps1") `
    -ProjectDir $NpmProjectDir `
    -OutputDir $OutputDir

$Version = Get-OfficeCliVersion -PackageJsonPath (Join-Path $NpmProjectDir "package.json")
Save-OfficeCliBinary -Version $Version -Destination (Join-Path $OutputDir "officecli")

$Archives = @(Get-ChildItem -Path (Join-Path $OutputDir "npm") -Filter "*.tgz" -File)
Write-Host "Completed: $($Archives.Count) npm archives and OfficeCLI v$Version in $OutputDir"
