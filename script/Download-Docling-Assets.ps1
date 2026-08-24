<#
.SYNOPSIS
DoclingのmodelとTesseract traineddataを取得します。

.DESCRIPTION
uvx経由のDocling公式CLIでmodel catalogの各stageで⭐が付いたmodelを取得し、checksumで検証したTesseract traineddataを取得します。
既定では`out/srv/docling/`配下へ、airgap serverへそのまま配置できる構造で保存します。

.PARAMETER OutputDirectory
`srv/docling/`を作成する出力先directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Docling-Assets.ps1 -OutputDirectory out

Docling資材を`out/srv/docling/`へ取得します。

.EXAMPLE
.\script\Download-Docling-Assets.ps1 -OutputDirectory D:\airgap

Docling資材を`D:\airgap\srv\docling\`へ取得します。

.NOTES
副作用として指定directory配下へfileを作成または上書きします。
実行にはPowerShell、uvx、internet接続が必要です。
#>
[CmdletBinding()]
param (
    [string]$OutputDirectory = "out",

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"
$DoclingPackageSpec = "docling==2.118.0"
# model catalogの⭐を明示的なCLI IDへ固定し、`--all`による対象外modelの混入を防ぎます。
# v1.30.0のOCR Auto warm-upはRapidOCRを選ぶため、rapidocrとTesseract traineddataの両方を取得します。
$DoclingModels = @(
    "layout",
    "tableformer",
    "rapidocr",
    "picture_classifier",
    "granitedocling",
    "smolvlm",
    "code_formula"
)
$TessdataRevision = "e12c65a915945e4c28e237a9b52bc4a8f39a0cec"
$TessdataBaseUrl = "https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/$TessdataRevision"
$TessdataAssets = @(
    @{ Path = "eng.traineddata"; Sha256 = "8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba" },
    @{ Path = "jpn.traineddata"; Sha256 = "36bdf9ac823f5911e624c30d0553e890b8abc7c31a65b3ef14da943658c40b79" },
    @{ Path = "jpn_vert.traineddata"; Sha256 = "1258be6eb2a9851f18043234ad18cca13ed32690bfff62b335c898bbea371548" },
    @{ Path = "osd.traineddata"; Sha256 = "9cf5d576fcc47564f11265841e5ca839001e7e6f38ff7f7aacf46d15a96b00ff" },
    @{ Path = "script/Japanese.traineddata"; Sha256 = "c716f6a9d413b3c127f2f9defd9b6f4bba84eeb6c5bfd6feba7922d8025ddf2f" },
    @{ Path = "script/Japanese_vert.traineddata"; Sha256 = "6eca729ad647326a2149e09cf0589d626f4e746863092e22f46841eae4574a49" }
)

<#
.SYNOPSIS
必要なcommandが利用可能であることを確認します。

.PARAMETER Name
確認するcommand名です。

.OUTPUTS
値は返しません。

.NOTES
commandが見つからない場合は例外を送出します。副作用はありません。
#>
function Assert-CommandAvailable {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name が見つかりません。"
    }
}

<#
.SYNOPSIS
Docling公式CLIで選択したmodelをhost directoryへ取得します。

.PARAMETER PackageSpec
uvxが一時環境へ導入するDocling packageのversion付きspecifierです。

.PARAMETER ModelDirectory
Docling modelの保存先directoryです。

.PARAMETER Models
取得するDocling CLI model IDの配列です。

.OUTPUTS
値は返しません。

.NOTES
保存先へmodelをdownloadします。uvx経由のdocling-tools実行に失敗した場合は例外を送出します。
#>
function Save-DoclingModels {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageSpec,

        [Parameter(Mandatory = $true)]
        [string]$ModelDirectory,

        [Parameter(Mandatory = $true)]
        [string[]]$Models
    )

    Write-Host "Download Docling models: $($Models -join ', ')"
    & uvx --from $PackageSpec docling-tools models download --output-dir $ModelDirectory $Models

    if ($LASTEXITCODE -ne 0) {
        throw "Docling modelの取得に失敗しました: $ModelDirectory"
    }
}

<#
.SYNOPSIS
Tesseract traineddataを取得してchecksumを検証します。

.PARAMETER BaseUrl
traineddata取得元のbase URLです。

.PARAMETER RelativePath
base URLと保存先からの相対pathです。

.PARAMETER ExpectedSha256
期待するSHA-256値です。

.PARAMETER OutputDirectory
traineddataを保存するbase directoryです。

.OUTPUTS
値は返しません。

.NOTES
保存先fileを上書きします。download失敗またはchecksum不一致の場合は例外を送出します。
#>
function Save-VerifiedTessdata {
    param (
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory
    )

    $OutputPath = Join-Path $OutputDirectory $RelativePath
    $ParentDirectory = Split-Path -Parent $OutputPath
    $DownloadUrl = "$BaseUrl/$RelativePath"

    New-Item -ItemType Directory -Path $ParentDirectory -Force | Out-Null
    Write-Host "Download Tesseract traineddata: $RelativePath"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutputPath

    $ActualSha256 = (Get-FileHash -Algorithm SHA256 -Path $OutputPath).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $ExpectedSha256) {
        throw "Tesseract traineddataのchecksumが一致しません: $RelativePath"
    }
}

Assert-CommandAvailable -Name "uvx"

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$DoclingDirectory = Join-Path $OutputDirectory "srv/docling"
$TessdataDirectory = Join-Path $DoclingDirectory "tesseract"

New-Item -ItemType Directory -Path $DoclingDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $TessdataDirectory -Force | Out-Null

Save-DoclingModels `
    -PackageSpec $DoclingPackageSpec `
    -ModelDirectory $DoclingDirectory `
    -Models $DoclingModels

foreach ($Asset in $TessdataAssets) {
    Save-VerifiedTessdata `
        -BaseUrl $TessdataBaseUrl `
        -RelativePath $Asset["Path"] `
        -ExpectedSha256 $Asset["Sha256"] `
        -OutputDirectory $TessdataDirectory
}

Write-Host "Docling assets are ready: $DoclingDirectory"
