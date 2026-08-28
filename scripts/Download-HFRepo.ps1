<#
.SYNOPSIS
Hugging Face model repositoryを取得します。

.DESCRIPTION
`huggingface-cli download`を使い、指定したHugging Face model repositoryを`owner--repo`形式のdirectoryへ保存します。
既定ではvLLMとTEIで利用するmodel repositoryを`/srv/huggingface/`配下へ取得します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-HFRepo.ps1 -OutputDir C:\airgap

Hugging Face repositoryを`C:\airgap\hfrepo`へ取得します。

.NOTES
副作用として指定directory配下へfileを作成または上書きします。
実行にはPowerShellとhuggingface-cliが必要です。
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
    "https://huggingface.co"
)
$Packages = @(
        "Qwen/Qwen3.8-27B-FP8",
        "Qwen/Qwen3-Embedding-0.6B",
        "Qwen/Qwen3-Reranker-0.6B",
        "cl-nagoya/ruri-v3-310m",
        "cl-nagoya/ruri-v3-reranker-310m"
)
if ($Packages.Count -eq 0) {
    throw "取得するHugging Face repositoryが指定されていません。"
}

if (-not (Get-Command huggingface-cli -ErrorAction SilentlyContinue)) {
    throw "huggingface-cli が見つかりません。huggingface_hubをインストールしてください。"
}

<#
.SYNOPSIS
Hugging Face repository IDからlocal directory名を生成します。

.DESCRIPTION
`owner/repo`形式のrepository IDを、filesystem上で扱いやすい`owner--repo`形式へ変換します。

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

.DESCRIPTION
`huggingface-cli download`を実行し、指定repositoryのsnapshotをlocal directoryへ同期します。

.PARAMETER Repository
取得するHugging Face repository IDです。

.PARAMETER OutputDirectory
repositoryを保存するlocal directoryです。

.OUTPUTS
値は返しません。

.NOTES
保存先directoryを作成し、既存fileを更新します。downloadに失敗した場合は例外を送出します。
#>
function Save-HuggingFaceRepository {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory
    )

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    Write-Host "Download Hugging Face repository: $Repository"
    huggingface-cli download `
        $Repository `
        --repo-type model `
        --local-dir $OutputDirectory

    if ($LASTEXITCODE -ne 0) {
        throw "Hugging Face repositoryの取得に失敗しました: $Repository"
    }
}

$DestinationDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "hfrepo"
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
$env:HF_ENDPOINT = $Registries[0]

foreach ($Repository in $Packages) {
    $DirectoryName = ConvertTo-HuggingFaceDirectoryName -Repository $Repository
    $OutputDirectory = Join-Path $DestinationDirectory $DirectoryName
    Save-HuggingFaceRepository -Repository $Repository -OutputDirectory $OutputDirectory
}
