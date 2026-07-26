$ErrorActionPreference = "Stop"

# このscriptは作業directoryから実行する。
$AssetsDir = if ($env:ASSETS_DIR) { $env:ASSETS_DIR } else { "assets" }
$RootDir = (Get-Location).Path
$AssetsPath = if ([System.IO.Path]::IsPathRooted($AssetsDir)) { $AssetsDir } else { Join-Path $RootDir $AssetsDir }

# LIST.mdで管理する資材を定義する。
$PypiPackages = @("python-docx", "pypdf", "pypandoc")
$NpmPackages = @("cowsay")
$ContainerImages = @(
    @{ Source = "docker.io/library/hello-world:latest"; File = "hello-world_latest.tar" },
    @{ Source = "docker.io/ollama/ollama:latest"; File = "ollama_ollama_latest.tar" }
)
$HuggingFaceModels = @("cl-nagoya/ruri-v3-310m", "cl-nagoya/ruri-v3-reranker-310m")

# 資材置場を作成する。
foreach ($Name in @("pypi", "npm", "docker", "rpm", "deb", "huggingface", "vsix")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $AssetsPath $Name) | Out-Null
}

# PyPI資材を依存package込みで取得する。
python -m pip download --dest (Join-Path $AssetsPath "pypi") @PypiPackages

# npm資材を依存package込みでtgz取得する。
$NpmWorkDir = Join-Path "work" "npm-assets"
New-Item -ItemType Directory -Force -Path $NpmWorkDir | Out-Null
Push-Location $NpmWorkDir
npm init -y | Out-Null
npm install --package-lock-only --ignore-scripts @NpmPackages
node -e "const lock=require('./package-lock.json'); for (const [k,p] of Object.entries(lock.packages)) { if (k && p.resolved && p.version) console.log(k.split('node_modules/').pop()+'@'+p.version); }" | ForEach-Object {
    $NpmAssetsDir = Join-Path $AssetsPath "npm"
    npm pack $_ --pack-destination $NpmAssetsDir | Out-Null
}
Pop-Location

# container imageをtarとして取得する。
foreach ($Image in $ContainerImages) {
    $DockerAssetsDir = Join-Path $AssetsPath "docker"
    crane pull $Image.Source (Join-Path $DockerAssetsDir $Image.File)
}

# Hugging Face modelを取得する。
python -m pip install --upgrade "huggingface_hub>=1,<2"
foreach ($Model in $HuggingFaceModels) {
    $ModelPath = Join-Path (Join-Path $AssetsPath "huggingface") $Model
    hf download $Model --local-dir $ModelPath
}

Write-Host "download completed: $AssetsPath"
