<#
.SYNOPSIS
閉域環境へ持ち込むLibreTranslate model資材を取得します。

.DESCRIPTION
英語・日本語のArgos Translate modelとMiniSBD modelをHTTPで取得し、
LibreTranslate 1.9.6へread-only bind mountできるdirectory treeを作成します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-LibreTranslate.ps1 -OutputDir C:\airgap

model資材を`C:\airgap\libretranslate`へ保存します。

.NOTES
副作用として指定directoryへfileを作成または上書きし、対象model directoryを更新します。
実行にはPowerShellとinternet接続が必要です。Dockerは使用しません。
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
    "https://argos-net.com/v1",
    "https://github.com/LibreTranslate/MiniSBD/releases/download/v0.0.1"
)
$Packages = @(
    [pscustomobject]@{
        Type = "argos"
        Name = "en_ja"
        FileName = "translate-en_ja-1_1.argosmodel"
        Url = "$($Registries[0])/translate-en_ja-1_1.argosmodel"
        Sha256 = "16300cc4eaa85320520cabcf433b63d01be40ef6966251de72043a083408f716"
    },
    [pscustomobject]@{
        Type = "argos"
        Name = "ja_en"
        FileName = "translate-ja_en-1_1.argosmodel"
        Url = "$($Registries[0])/translate-ja_en-1_1.argosmodel"
        Sha256 = "623e3477959a815eb0a5ef53e09079ae8f1f9d3bbcd230473baf28c03fb83335"
    },
    [pscustomobject]@{
        Type = "minisbd"
        Name = "en"
        FileName = "en.onnx"
        Url = "$($Registries[1])/en.onnx"
        Sha256 = "6fa9f3a3b201687bd43e329b2b0736789efc97b37883b5b759b31988dca9f353"
    },
    [pscustomobject]@{
        Type = "minisbd"
        Name = "ja"
        FileName = "ja.onnx"
        Url = "$($Registries[1])/ja.onnx"
        Sha256 = "5ef874606b0afe24cc799b737ba1d9c09259e80ddee7646fc557a8f9e0e1017c"
    }
)
if ($env:DOWNLOAD_TEST) {
    $Packages = @($Packages | Where-Object { $_.Type -eq "minisbd" -and $_.Name -eq "en" })
}

<#
.SYNOPSIS
model資材を取得し、checksumを検証します。
.PARAMETER Asset
Url、FileName、Sha256を持つ取得対象です。
.PARAMETER OutputPath
資材を保存するfile pathです。
.OUTPUTS
値を返しません。
.NOTES
保存先fileを上書きします。download失敗またはchecksum不一致の場合は例外を送出します。
#>
function Save-VerifiedModelAsset {
    param (
        [Parameter(Mandatory = $true)][pscustomobject]$Asset,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    Write-Host "Download LibreTranslate asset: $($Asset.FileName)"
    $WebClient = [System.Net.WebClient]::new()
    try {
        $WebClient.DownloadFile($Asset.Url, $OutputPath)
    }
    finally {
        $WebClient.Dispose()
    }

    $ActualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $Asset.Sha256) {
        throw "LibreTranslate資材のchecksumが一致しません: $($Asset.FileName)"
    }
}

<#
.SYNOPSIS
Argos model archiveをruntime用package directoryへ展開します。
.PARAMETER ArchivePath
展開する`.argosmodel` archiveのpathです。
.PARAMETER PackageName
archive内と展開先で使用するmodel package名です。
.PARAMETER PackageDirectory
model packageを格納する親directoryです。
.OUTPUTS
値を返しません。
.NOTES
対象package directoryを検証済みarchiveの内容で置き換えます。不正なarchiveは例外を送出します。
#>
function Expand-ArgosModelArchive {
    param (
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$PackageDirectory
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $StagingDirectory = Join-Path $PackageDirectory ".extract-$([guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $StagingDirectory -Force | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $StagingDirectory)
        $StagedPackage = Join-Path $StagingDirectory $PackageName
        if (-not (Test-Path -LiteralPath (Join-Path $StagedPackage "metadata.json") -PathType Leaf)) {
            throw "Argos model archiveの構造が不正です: $ArchivePath"
        }

        $InstalledPackage = Join-Path $PackageDirectory $PackageName
        Remove-Item -LiteralPath $InstalledPackage -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $StagedPackage -Destination $InstalledPackage
    }
    finally {
        Remove-Item -LiteralPath $StagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$OutputDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "libretranslate"
$ArchiveDirectory = Join-Path $OutputDirectory "archives"
$PackageDirectory = Join-Path $OutputDirectory "packages"
$MiniSbdDirectory = Join-Path $OutputDirectory "minisbd"
New-Item -ItemType Directory -Path $ArchiveDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $MiniSbdDirectory -Force | Out-Null

$ManifestLines = @()
foreach ($Asset in $Packages) {
    $AssetDirectory = if ($Asset.Type -eq "argos") { $ArchiveDirectory } else { $MiniSbdDirectory }
    $AssetPath = Join-Path $AssetDirectory $Asset.FileName
    Save-VerifiedModelAsset -Asset $Asset -OutputPath $AssetPath
    $RelativePath = if ($Asset.Type -eq "argos") {
        "archives/$($Asset.FileName)"
    }
    else {
        "minisbd/$($Asset.FileName)"
    }
    $ManifestLines += "$($Asset.Sha256)  $RelativePath"

    if ($Asset.Type -eq "argos") {
        Expand-ArgosModelArchive `
            -ArchivePath $AssetPath `
            -PackageName $Asset.Name `
            -PackageDirectory $PackageDirectory
    }
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines((Join-Path $OutputDirectory "SHA256SUMS"), $ManifestLines, $Utf8NoBom)
Write-Host "LibreTranslate assets are ready: $OutputDirectory"
