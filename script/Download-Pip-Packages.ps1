<#
.SYNOPSIS
Linux x86_64向けのPyPI package archiveを取得します。

.DESCRIPTION
`pip download`を使い、指定したPyPI packageと依存packageをLinux x86_64向けに取得します。
既定ではInferLabのbackend開発と実行に必要なCPython 3.12向けの`manylinux2014_x86_64` wheelを`pip/`へ保存します。

.PARAMETER DestinationDirectory
取得したPyPI package archiveを保存するdirectoryです。

.PARAMETER Packages
取得するPyPI package specの配列です。

.PARAMETER Platform
pipへ渡すtarget platformです。

.PARAMETER PythonVersion
pipへ渡すtarget Python versionです。

.PARAMETER Implementation
pipへ渡すtarget Python implementationです。

.PARAMETER Abi
pipへ渡すtarget ABIです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Pip-Packages.ps1

既定のPyPI packageをLinux x86_64向けに取得します。

.EXAMPLE
.\script\Download-Pip-Packages.ps1 -DestinationDirectory .\wheelhouse -Packages python-docx,pypdf

指定したPyPI packageを`wheelhouse/`へ取得します。

.NOTES
副作用として指定directoryへfileを作成または上書きします。
実行にはPowerShellとPython 3のpipが必要です。
#>
[CmdletBinding()]
param (
    [string]$DestinationDirectory = (Join-Path (Get-Location).Path "pip"),

    [string[]]$Packages = @(
        "alembic>=1.14.0",
        "boto3",
        "fastapi[standard]>=0.115.0",
        "httpx>=0.27.0",
        "langchain>=0.3.0",
        "langchain-community>=0.3.0",
        "langchain-core>=0.3.0",
        "langchain-text-splitters>=0.3.0",
        "langfuse>=3.0.0",
        "minio>=7.2.0",
        "openai>=2.52.0",
        "psycopg[binary]>=3.2.0",
        "pydantic-settings>=2.6.0",
        "pytest>=8.3.0",
        "pytest-cov>=7.1.0",
        "python-docx",
        "python-jose[cryptography]>=3.3.0",
        "python-multipart>=0.0.12",
        "pypdf",
        "pypandoc",
        "qdrant-client>=1.12.0",
        "redis>=5.1.0",
        "rq>=2.0.0",
        "ruff>=0.8.0",
        "sqlalchemy>=2.0.36",
        "uvicorn[standard]>=0.32.0"
    ),

    [string]$Platform = "manylinux2014_x86_64",

    [string]$PythonVersion = "312",

    [string]$Implementation = "cp",

    [string]$Abi = "cp312",

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$ErrorActionPreference = "Stop"

if ($Packages.Count -eq 0) {
    throw "取得するPyPI packageが指定されていません。"
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "python が見つかりません。Python 3とpipをインストールしてください。"
}

$DestinationDirectory = [System.IO.Path]::GetFullPath($DestinationDirectory)
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null

$PipArguments = @(
    "-m",
    "pip",
    "download",
    "--dest",
    $DestinationDirectory,
    "--platform",
    $Platform,
    "--python-version",
    $PythonVersion,
    "--implementation",
    $Implementation,
    "--abi",
    $Abi,
    "--only-binary=:all:"
) + $Packages

Write-Host "Download PyPI packages: $($Packages -join ', ')"
python @PipArguments

if ($LASTEXITCODE -ne 0) {
    throw "pip download に失敗しました。"
}

$DownloadedFiles = @(
    Get-ChildItem -Path $DestinationDirectory -File -Include "*.whl", "*.tar.gz", "*.zip" -Recurse -ErrorAction SilentlyContinue
)

if ($DownloadedFiles.Count -eq 0) {
    throw "PyPI package archiveが作成されませんでした: $DestinationDirectory"
}
