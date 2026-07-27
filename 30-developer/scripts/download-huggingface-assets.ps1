$ErrorActionPreference = "Stop"

# Hugging Face Hubから取得するmodel repositoryを定義する。
$HuggingFaceModels = @(
    "cl-nagoya/ruri-v3-310m",
    "cl-nagoya/ruri-v3-reranker-310m"
)

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDirectory "download-assets-common.ps1")

$AssetsPath = Get-AssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory (Get-Location).Path
Write-Host "assets directory: $AssetsPath"

New-AssetDirectories -AssetsPath $AssetsPath -Names @("huggingface")
$HuggingFaceAssetsDir = Join-Path $AssetsPath "huggingface"

Invoke-PythonCommand -Arguments @("-m", "pip", "install", "--upgrade", "huggingface_hub>=1,<2")

$HuggingFaceDownloadScript = @'
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2])
'@

foreach ($Model in $HuggingFaceModels) {
    $ModelPath = Join-Path $HuggingFaceAssetsDir $Model
    Invoke-PythonCommand -Arguments @("-c", $HuggingFaceDownloadScript, $Model, $ModelPath)
}
