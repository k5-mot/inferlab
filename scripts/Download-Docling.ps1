<#
.SYNOPSIS
DoclingのmodelとTesseract traineddataを取得します。

.DESCRIPTION
uvx経由のDocling公式CLIで指定modelとHugging Face repositoryを取得し、checksumで検証したTesseract traineddataを取得します。
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
実行にはPowerShell、uvx、internet接続が必要です。
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
    "https://pypi.org/simple",
    "https://huggingface.co",
    "https://raw.githubusercontent.com/tesseract-ocr/tessdata_best"
)
$TessdataRevision = "e12c65a915945e4c28e237a9b52bc4a8f39a0cec"
$Packages = @(
    [pscustomobject]@{ Type = "cli"; Name = "docling==2.118.0" },
    [pscustomobject]@{ Type = "model"; Name = "layout" },
    [pscustomobject]@{ Type = "model"; Name = "tableformer" },
    [pscustomobject]@{ Type = "model"; Name = "tableformerv2" },
    [pscustomobject]@{ Type = "model"; Name = "picture_classifier" },
    [pscustomobject]@{ Type = "model"; Name = "granitedocling" },
    [pscustomobject]@{ Type = "model"; Name = "smolvlm" },
    [pscustomobject]@{ Type = "model"; Name = "code_formula" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/docling-layout-heron" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/docling-layout-heron-101" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/DocumentFigureClassifier-v2.5" },
    [pscustomobject]@{ Type = "hfrepo"; Name = "docling-project/CodeFormulaV2" },
    [pscustomobject]@{ Type = "tessdata"; Name = "eng.traineddata"; Sha256 = "8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba" },
    [pscustomobject]@{ Type = "tessdata"; Name = "jpn.traineddata"; Sha256 = "36bdf9ac823f5911e624c30d0553e890b8abc7c31a65b3ef14da943658c40b79" },
    [pscustomobject]@{ Type = "tessdata"; Name = "jpn_vert.traineddata"; Sha256 = "1258be6eb2a9851f18043234ad18cca13ed32690bfff62b335c898bbea371548" },
    [pscustomobject]@{ Type = "tessdata"; Name = "osd.traineddata"; Sha256 = "9cf5d576fcc47564f11265841e5ca839001e7e6f38ff7f7aacf46d15a96b00ff" },
    [pscustomobject]@{ Type = "tessdata"; Name = "script/Japanese.traineddata"; Sha256 = "c716f6a9d413b3c127f2f9defd9b6f4bba84eeb6c5bfd6feba7922d8025ddf2f" },
    [pscustomobject]@{ Type = "tessdata"; Name = "script/Japanese_vert.traineddata"; Sha256 = "6eca729ad647326a2149e09cf0589d626f4e746863092e22f46841eae4574a49" }
)
$DoclingPackageSpec = ($Packages | Where-Object Type -eq "cli").Name
$DoclingModels = @($Packages | Where-Object Type -eq "model" | Select-Object -ExpandProperty Name)
$DoclingHuggingFaceRepositories = @($Packages | Where-Object Type -eq "hfrepo" | Select-Object -ExpandProperty Name)
$TessdataAssets = @($Packages | Where-Object Type -eq "tessdata")
$TessdataBaseUrl = "$($Registries[2])/$TessdataRevision"
$env:UV_INDEX_URL = $Registries[0]
$env:HF_ENDPOINT = $Registries[1]

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
Docling公式CLIで指定したHugging Face repositoryをhost directoryへ取得します。

.PARAMETER PackageSpec
uvxが一時環境へ導入するDocling packageのversion付きspecifierです。

.PARAMETER ModelDirectory
Hugging Face repositoryの保存先directoryです。

.PARAMETER Repositories
取得するHugging Face repository IDの配列です。

.OUTPUTS
値は返しません。

.NOTES
保存先へrepository snapshotをdownloadします。uvx経由のdocling-tools実行に失敗した場合は例外を送出します。
#>
function Save-DoclingHuggingFaceRepositories {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageSpec,

        [Parameter(Mandatory = $true)]
        [string]$ModelDirectory,

        [Parameter(Mandatory = $true)]
        [string[]]$Repositories
    )

    Write-Host "Download Docling Hugging Face repositories: $($Repositories -join ', ')"
    & uvx --from $PackageSpec docling-tools models download-hf-repo --output-dir $ModelDirectory $Repositories

    if ($LASTEXITCODE -ne 0) {
        throw "Docling Hugging Face repositoryの取得に失敗しました: $ModelDirectory"
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

$DoclingDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "docling"
$TessdataDirectory = Join-Path $DoclingDirectory "tesseract"

New-Item -ItemType Directory -Path $DoclingDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $TessdataDirectory -Force | Out-Null

Save-DoclingModels `
    -PackageSpec $DoclingPackageSpec `
    -ModelDirectory $DoclingDirectory `
    -Models $DoclingModels

Save-DoclingHuggingFaceRepositories `
    -PackageSpec $DoclingPackageSpec `
    -ModelDirectory $DoclingDirectory `
    -Repositories $DoclingHuggingFaceRepositories

foreach ($Asset in $TessdataAssets) {
    Save-VerifiedTessdata `
        -BaseUrl $TessdataBaseUrl `
        -RelativePath $Asset.Name `
        -ExpectedSha256 $Asset["Sha256"] `
        -OutputDirectory $TessdataDirectory
}

Write-Host "Docling assets are ready: $DoclingDirectory"
