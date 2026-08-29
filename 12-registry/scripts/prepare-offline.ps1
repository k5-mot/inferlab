[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot "offline-bundle"),
    [ValidatePattern('^\d+\.\d+$')]
    [string]$PythonVersion = "3.12",
    [ValidateRange(17, 40)]
    [int]$TargetGlibcMinor = 28,
    [ValidateSet("x64")]
    [string]$NpmCpu = "x64"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# パッケージ保守領域
# パッケージの追加や削除では、依存関係の定義をこの領域へ集約する。
# =============================================================================

$NpmDependencies = @(
    [pscustomobject]@{ Name = "@serendie/design-token"; Version = "^1.4.6" },
    [pscustomobject]@{ Name = "@serendie/symbols";      Version = "^1.0.3" },
    [pscustomobject]@{ Name = "@serendie/ui";           Version = "^3.7.0" },
    [pscustomobject]@{ Name = "keycloak-js";            Version = "^26.2.0" },
    [pscustomobject]@{ Name = "react";                  Version = "^19.0.0" },
    [pscustomobject]@{ Name = "react-dom";              Version = "^19.0.0" },

    # 製品名のNext.jsに対応する公式npmパッケージ名はnextである。
    # 指定要件にversionがないため、実行時のlatestをpackage-lock.jsonで固定する。
    [pscustomobject]@{ Name = "next";                   Version = "latest" }
)

$NpmDevDependencies = @(
    [pscustomobject]@{ Name = "@fission-ai/openspec";          Version = "^1.7.0" },
    [pscustomobject]@{ Name = "@playwright/test";              Version = "^1.62.1" },
    [pscustomobject]@{ Name = "oxfmt";                         Version = "^0.61.0" },
    [pscustomobject]@{ Name = "oxlint";                        Version = "^1.76.0" },
    [pscustomobject]@{ Name = "skills";                        Version = "^1.5.21" },
    [pscustomobject]@{ Name = "@vitejs/plugin-react";          Version = "^5.0.0" },
    [pscustomobject]@{ Name = "vite";                          Version = "^7.0.0" },
    [pscustomobject]@{ Name = "@pandacss/dev";                 Version = "^1.12.0" },
    [pscustomobject]@{ Name = "@testing-library/jest-dom";     Version = "^7.0.0" },
    [pscustomobject]@{ Name = "@testing-library/react";        Version = "^16.3.2" },
    [pscustomobject]@{ Name = "@testing-library/user-event";   Version = "^14.6.1" },
    [pscustomobject]@{ Name = "@types/react";                  Version = "^19.0.0" },
    [pscustomobject]@{ Name = "@types/react-dom";              Version = "^19.0.0" },
    [pscustomobject]@{ Name = "@vitest/coverage-v8";           Version = "^4.1.10" },
    [pscustomobject]@{ Name = "jsdom";                         Version = "^30.0.1" },
    [pscustomobject]@{ Name = "msw";                           Version = "^2.15.0" },
    [pscustomobject]@{ Name = "typescript";                    Version = "^5.7.0" },
    [pscustomobject]@{ Name = "vite-plus";                     Version = "^0.2.1" },
    [pscustomobject]@{ Name = "vitest";                        Version = "^4.1.10" },

    # shadcn CLIも指定要件にversionがないため、解決結果をpackage-lock.jsonで固定する。
    [pscustomobject]@{ Name = "shadcn";                        Version = "latest" }
)

$PythonPackages = @(
    "alembic>=1.14.0",
    "boto3>=1.43.78",
    "cohere>=5.21.1",
    "docling>=2.117.0,<3.0.0",
    "fastapi[standard]>=0.115.0",
    "httpx>=0.27.0",
    "langchain>=0.3.0",
    "langchain-cohere>=0.6.0",
    "langchain-ollama",
    "ollama",
    "langchain-community>=0.3.0",
    "langchain-core>=0.3.0",
    "langchain-openai>=1.6.0",
    "langchain-qdrant>=1.1.0",
    "langchain-text-splitters>=0.3.0",
    "langfuse>=3.0.0",
    "openai>=2.52.0",
    "psycopg[binary]>=3.2.0",
    "pydantic-settings>=2.6.0",
    "python-jose[cryptography]>=3.3.0",
    "python-multipart>=0.0.12",
    "qdrant-client>=1.12.0",
    "rq>=2.0.0",
    "sqlalchemy>=2.0.36",
    "torch>=2.2.2,<3.0.0",
    "torchvision>=0.17.2,<1.0.0",
    "uvicorn[standard]>=0.32.0",
    "valkey>=6.1.1",

    # 開発用依存関係
    "pytest>=8.3.0",
    "pytest-cov>=7.1.0",
    "ruff>=0.8.0"
)

# アプリケーション依存ではないが、オフラインでvenvを構築・修復できるように同梱する。
$PythonBootstrapPackages = @(
    "pip",
    "setuptools",
    "wheel"
)

# =============================================================================
# 対象環境の設定
# =============================================================================

$PytorchCpuIndex = "https://download.pytorch.org/whl/cpu"
$PythonAbi = "cp" + ($PythonVersion -replace '\.', '')

# RHEL 8互換性のため、PEP 600のglibc tagを2.28から2.17までと
# manylinux2014 aliasまで許可する。
$PipPlatforms = @()
for ($minor = $TargetGlibcMinor; $minor -ge 17; $minor--) {
    $PipPlatforms += "manylinux_2_${minor}_x86_64"
}
$PipPlatforms += "manylinux2014_x86_64"

# =============================================================================
# 補助関数
# =============================================================================

<#
.SYNOPSIS
UTF-8（BOMなし）でテキストファイルを書き込む。
.PARAMETER Path
書き込み先のファイルパス。
.PARAMETER Content
書き込む文字列。
.OUTPUTS
なし。
#>
function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

<#
.SYNOPSIS
外部コマンドを実行し、終了コードが0であることを保証する。
.PARAMETER Command
実行するコマンド名。
.PARAMETER Arguments
コマンドへ渡す引数。
.OUTPUTS
外部コマンドが出力したオブジェクト。
.NOTES
終了コードが0以外の場合は例外を送出する。
#>
function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    Write-Host "> $Command $($Arguments -join ' ')" -ForegroundColor Cyan
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE: $Command"
    }
}

<#
.SYNOPSIS
パッケージ定義の配列をJSON生成用の順序付きmapへ変換する。
.PARAMETER Packages
NameとVersionを持つパッケージ定義の配列。
.OUTPUTS
パッケージ名をkey、versionをvalueとする順序付きmap。
#>
function Convert-PackageArrayToOrderedMap {
    param([object[]]$Packages)
    $map = [ordered]@{}
    foreach ($pkg in $Packages) {
        $map[$pkg.Name] = $pkg.Version
    }
    return $map
}

# =============================================================================
# 前提条件の検証
# =============================================================================

foreach ($cmd in @("py", "node", "npm")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $cmd"
    }
}

$npmVersion = (& npm --version).Trim()
$npmMajor = [int]($npmVersion.Split('.')[0])
if ($npmMajor -lt 10) {
    throw "npm 10 or newer is required for --os/--cpu/--libc target overrides. Current: $npmVersion"
}

Write-Host "Windows Python launcher: $((& py --version) -join '')"
Write-Host "Node.js: $((& node --version) -join '')"
Write-Host "npm: $npmVersion"
Write-Host "Target: CPython $PythonVersion / $PythonAbi / Linux x86_64 / glibc >= 2.$TargetGlibcMinor"

# =============================================================================
# ディレクトリ構成
# =============================================================================

$BundleRoot = [System.IO.Path]::GetFullPath($OutputDir)
$PythonDir = Join-Path $BundleRoot "python"
$WheelDir = Join-Path $PythonDir "wheelhouse"
$NpmDir = Join-Path $BundleRoot "npm"
$NpmCache = Join-Path $NpmDir "cache"

if (Test-Path $BundleRoot) {
    Write-Host "Removing existing bundle: $BundleRoot" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $BundleRoot
}

New-Item -ItemType Directory -Force -Path $WheelDir | Out-Null
New-Item -ItemType Directory -Force -Path $NpmCache | Out-Null

# =============================================================================
# Python: 要件一覧の生成とLinux wheelの取得
# =============================================================================

$RequirementsPath = Join-Path $PythonDir "requirements.in"
Write-Utf8NoBom -Path $RequirementsPath -Content (($PythonPackages -join "`n") + "`n")

$BootstrapPath = Join-Path $PythonDir "bootstrap-requirements.in"
Write-Utf8NoBom -Path $BootstrapPath -Content (($PythonBootstrapPackages -join "`n") + "`n")

$pipArgs = @(
    "-m", "pip", "download",
    "--dest", $WheelDir,
    "--only-binary=:all:",
    "--prefer-binary",
    "--implementation", "cp",
    "--python-version", $PythonVersion,
    "--abi", $PythonAbi,
    "--abi", "abi3",
    "--abi", "none",
    "--extra-index-url", $PytorchCpuIndex
)
foreach ($platform in $PipPlatforms) {
    $pipArgs += @("--platform", $platform)
}
$pipArgs += @("-r", $RequirementsPath, "-r", $BootstrapPath)

Invoke-Checked -Command "py" -Arguments $pipArgs

# PyTorch CPU indexのwheelは通常+cpu suffixを持つが、配布形式の変更を考慮して
# suffixがない場合は失敗させず警告する。
foreach ($pattern in @("torch-*.whl", "torchvision-*.whl")) {
    $wheelFiles = @(Get-ChildItem -Path $WheelDir -Filter $pattern -File)
    if ($wheelFiles.Count -eq 0) {
        throw "Expected wheel not found: $pattern"
    }
    if (-not ($wheelFiles.Name -match '\+cpu-')) {
        Write-Warning "CPU suffix (+cpu) was not found in $pattern. Verify the downloaded PyTorch wheel before transfer."
    }
}

# 転送内容を監査できるよう、取得したwheelの正確な一覧を記録する。
$wheelManifest = Get-ChildItem -Path $WheelDir -File |
    Sort-Object Name |
    ForEach-Object { $_.Name }
Write-Utf8NoBom -Path (Join-Path $PythonDir "downloaded-wheels.txt") -Content (($wheelManifest -join "`n") + "`n")

# =============================================================================
# npm: package.jsonとLinux向けlockの生成、可搬cacheの準備
# =============================================================================

$packageJson = [ordered]@{
    name            = "offline-linux-bundle"
    version         = "1.0.0"
    private         = $true
    description     = "Generated manifest for offline Linux installation"
    dependencies    = Convert-PackageArrayToOrderedMap $NpmDependencies
    devDependencies = Convert-PackageArrayToOrderedMap $NpmDevDependencies
}

$PackageJsonPath = Join-Path $NpmDir "package.json"
Write-Utf8NoBom -Path $PackageJsonPath -Content (($packageJson | ConvertTo-Json -Depth 10) + "`n")

Push-Location $NpmDir
try {
    Invoke-Checked -Command "npm" -Arguments @(
        "install",
        "--package-lock-only",
        "--ignore-scripts",
        "--include=optional",
        "--os=linux",
        "--cpu=$NpmCpu",
        "--libc=glibc",
        "--cache=$NpmCache",
        "--audit=false",
        "--fund=false"
    )

    # Linux binaryを実行せずoptional dependencyのtarballをcacheへ取得するため、
    # Windows上でLinux対象を明示し、scriptを無効化してnpm ciを実行する。
    Invoke-Checked -Command "npm" -Arguments @(
        "ci",
        "--ignore-scripts",
        "--include=optional",
        "--os=linux",
        "--cpu=$NpmCpu",
        "--libc=glibc",
        "--cache=$NpmCache",
        "--audit=false",
        "--fund=false"
    )

    if (Test-Path (Join-Path $NpmDir "node_modules")) {
        Remove-Item -Recurse -Force (Join-Path $NpmDir "node_modules")
    }

    Invoke-Checked -Command "npm" -Arguments @("cache", "verify", "--cache=$NpmCache")
}
finally {
    Pop-Location
}

# =============================================================================
# バンドルのmetadataと完全性manifest
# =============================================================================

$targetEnv = @(
    "BUNDLE_FORMAT_VERSION=1",
    "PYTHON_VERSION=$PythonVersion",
    "PYTHON_ABI=$PythonAbi",
    "TARGET_GLIBC_MAJOR=2",
    "TARGET_GLIBC_MINOR=$TargetGlibcMinor",
    "NPM_OS=linux",
    "NPM_CPU=$NpmCpu",
    "NPM_LIBC=glibc"
) -join "`n"
Write-Utf8NoBom -Path (Join-Path $BundleRoot "target.env") -Content ($targetEnv + "`n")

$hashLines = @()
Get-ChildItem -Path $BundleRoot -Recurse -File |
    Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($BundleRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        $hash = (Get-FileHash -Algorithm SHA256 -Path $_.FullName).Hash.ToLowerInvariant()
        $hashLines += "$hash  $relative"
    }
Write-Utf8NoBom -Path (Join-Path $BundleRoot "SHA256SUMS.txt") -Content (($hashLines -join "`n") + "`n")

Write-Host ""
Write-Host "Offline bundle created successfully:" -ForegroundColor Green
Write-Host "  $BundleRoot"
Write-Host ""
Write-Host "Copy the whole directory to the offline Linux host together with install-offline.sh."
