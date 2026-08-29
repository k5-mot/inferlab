<#
.SYNOPSIS
DoclingのmodelとTesseract traineddataを取得します。

.DESCRIPTION
Docling公式CLIのmodel定義に対応するHugging Face repositoryを直接取得し、checksumで検証したTesseract traineddataを取得します。
指定した出力先の`docling/`配下へ保存します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-Docling.ps1 -OutputDir C:\airgap

Docling資材を`C:\airgap\docling`へ取得します。

.NOTES
副作用として指定directory配下へfileを作成または上書きします。
実行にはPowerShell、hf、internet接続が必要です。
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
    "https://huggingface.co",
    "https://raw.githubusercontent.com/tesseract-ocr/tessdata_best"
)
$TessdataRevision = "e12c65a915945e4c28e237a9b52bc4a8f39a0cec"
$Packages = @(
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/docling-layout-heron"; Revision = "main" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/docling-layout-heron-onnx"; Revision = "main" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/docling-layout-heron-101"; Revision = "main" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/docling-models"; Revision = "v2.3.0" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/TableFormerV2"; Revision = "main" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/DocumentFigureClassifier-v2.5"; Revision = "main" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "ibm-granite/granite-docling-258M"; Revision = "main" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "HuggingFaceTB/SmolVLM-256M-Instruct"; Revision = "main" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/CodeFormulaV2"; Revision = "main" },
    [pscustomobject]@{ Type = "tessdata"; Name = "eng.traineddata"; Sha256 = "8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba" },
    [pscustomobject]@{ Type = "tessdata"; Name = "jpn.traineddata"; Sha256 = "36bdf9ac823f5911e624c30d0553e890b8abc7c31a65b3ef14da943658c40b79" },
    [pscustomobject]@{ Type = "tessdata"; Name = "jpn_vert.traineddata"; Sha256 = "1258be6eb2a9851f18043234ad18cca13ed32690bfff62b335c898bbea371548" },
    [pscustomobject]@{ Type = "tessdata"; Name = "osd.traineddata"; Sha256 = "9cf5d576fcc47564f11265841e5ca839001e7e6f38ff7f7aacf46d15a96b00ff" },
    [pscustomobject]@{ Type = "tessdata"; Name = "script/Japanese.traineddata"; Sha256 = "c716f6a9d413b3c127f2f9defd9b6f4bba84eeb6c5bfd6feba7922d8025ddf2f" },
    [pscustomobject]@{ Type = "tessdata"; Name = "script/Japanese_vert.traineddata"; Sha256 = "6eca729ad647326a2149e09cf0589d626f4e746863092e22f46841eae4574a49" }
)
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Packages = @(
        [pscustomobject]@{ Type = "hfrepo"; Name = "hf-internal-testing/tiny-random-bert"; Revision = "main" },
        [pscustomobject]@{ Type = "tessdata"; Name = "osd.traineddata"; Sha256 = "9cf5d576fcc47564f11265841e5ca839001e7e6f38ff7f7aacf46d15a96b00ff" }
    )
}
$DoclingHuggingFaceRepositories = @($Packages | Where-Object Type -eq "hfrepo")
$TessdataAssets = @($Packages | Where-Object Type -eq "tessdata")
$TessdataBaseUrl = "$($Registries[1])/$TessdataRevision"
$env:HF_ENDPOINT = $Registries[0]

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
Hugging Face repository IDからlocal directory名を生成します。

.PARAMETER Repository
変換対象のHugging Face repository IDです。

.OUTPUTS
生成したdirectory名を文字列として返します。

.NOTES
repository IDにslashが含まれない場合は例外を送出します。副作用はありません。
#>
function ConvertTo-HuggingFaceDirectoryName {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    if ($Repository -notmatch "^[^/]+/[^/]+$") {
        throw "Hugging Face repository IDが不正です: $Repository"
    }

    return ($Repository -replace "/", "--")
}

<#
.SYNOPSIS
Hugging Face repositoryをlocal directoryへ保存します。
.PARAMETER Repository
NameとRevisionを持つ取得対象repositoryです。
.PARAMETER OutputDirectory
repositoryを保存するlocal directoryです。
.OUTPUTS
値を返しません。
.NOTES
保存先directoryを作成し、既存fileを更新します。downloadに失敗した場合は例外を送出します。
#>
function Save-HuggingFaceRepository {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory
    )

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    Write-Host "Download Docling Hugging Face repository: $($Repository.Name)@$($Repository.Revision)"
    hf download `
        $Repository.Name `
        --repo-type model `
        --revision $Repository.Revision `
        --local-dir $OutputDirectory

    if ($LASTEXITCODE -ne 0) {
        throw "Docling Hugging Face repositoryの取得に失敗しました: $($Repository.Name)"
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
    $WebClient = [System.Net.WebClient]::new()
    try {
        $WebClient.DownloadFile($DownloadUrl, $OutputPath)
    }
    finally {
        $WebClient.Dispose()
    }

    $ActualSha256 = (Get-FileHash -Algorithm SHA256 -Path $OutputPath).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $ExpectedSha256) {
        throw "Tesseract traineddataのchecksumが一致しません: $RelativePath"
    }
}

if ($DoclingHuggingFaceRepositories.Count -gt 0) {
    Assert-CommandAvailable -Name "hf"
}

$DoclingDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "docling"
$TessdataDirectory = Join-Path $DoclingDirectory "tesseract"

New-Item -ItemType Directory -Path $DoclingDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $TessdataDirectory -Force | Out-Null

foreach ($Repository in $DoclingHuggingFaceRepositories) {
    $DirectoryName = ConvertTo-HuggingFaceDirectoryName -Repository $Repository.Name
    Save-HuggingFaceRepository `
        -Repository $Repository `
        -OutputDirectory (Join-Path $DoclingDirectory $DirectoryName)
}

foreach ($Asset in $TessdataAssets) {
    Save-VerifiedTessdata `
        -BaseUrl $TessdataBaseUrl `
        -RelativePath $Asset.Name `
        -ExpectedSha256 $Asset.Sha256 `
        -OutputDirectory $TessdataDirectory
}

Write-Host "Docling assets are ready: $DoclingDirectory"
