<#
.SYNOPSIS
このrepositoryのair-gap運用に必要なPython package資材を取得します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-PipPkgs.ps1 -OutputDir C:\airgap

Dify plugin、private-chat、OpenKBのPython依存を`C:\airgap\pypi`へ取得します。

.NOTES
download対象はこのscriptの`$Packages`で固定します。
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
    "https://download.pytorch.org/whl/cpu"
)
$Packages = @(
    "annotated-doc==0.0.5",
    "annotated-types==0.8.0",
    "alembic>=1.14.0",
    "anyio==4.14.2",
    "apscheduler==3.11.3",
    "boto3>=1.43.78",
    "certifi==2026.7.22",
    "click==8.4.2",
    "cohere>=5.21.1",
    "colorama==0.4.6",
    "docling>=2.117.0,<3.0.0",
    "fastapi[standard]==0.141.1",
    "h11==0.16.0",
    "httpcore==1.0.9",
    "httptools==0.8.0",
    "httpx==0.28.1",
    "idna==3.19",
    "langchain>=0.3.0",
    "langchain-cohere>=0.6.0",
    "langchain-community>=0.3.0",
    "langchain-core>=0.3.0",
    "langchain-openai>=1.6.0",
    "langchain-qdrant>=1.1.0",
    "langchain-text-splitters>=0.3.0",
    "langfuse>=3.0.0",
    "openai>=2.52.0",
    "psycopg[binary]>=3.2.0",
    "pydantic-core==2.46.4",
    "pydantic-settings>=2.6.0",
    "pydantic==2.13.4",
    "python-dotenv==1.2.3",
    "python-jose[cryptography]>=3.3.0",
    "python-multipart>=0.0.12",
    "pyyaml==6.0.3",
    "qdrant-client>=1.12.0",
    "rq>=2.0.0",
    "sqlalchemy>=2.0.36",
    "starlette==1.6.0",
    "torch>=2.2.2,<3.0.0",
    "torchvision>=0.17.2,<1.0.0",
    "typing-extensions==4.16.0",
    "typing-inspection==0.4.4",
    "tzdata==2026.3",
    "tzlocal==5.4.4",
    "uvicorn[standard]==0.52.3",
    "uvloop==0.22.1; sys_platform != 'win32'",
    "valkey>=6.1.1",
    "watchfiles==1.2.0",
    "websockets==17.0.1"
)
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Packages = @("six==1.16.0")
}

<#
.SYNOPSIS
script内のpackage listを共通download処理へ渡します。
.PARAMETER Packages
requirements.txtへ書き出すrequirement spec配列です。
.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。
.OUTPUTS
値を返しません。
.NOTES
一時directoryへrequirements.txtを作成し、downloadに失敗した場合は例外を送出します。
#>
function Invoke-PackageListDownload {
    param (
        [Parameter(Mandatory = $true)][string[]]$Packages,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    $DownloaderPath = Join-Path $PSScriptRoot "Download-PipPkgs-from-Project.ps1"
    $ProjectDir = Join-Path ([System.IO.Path]::GetTempPath()) ("repository-pip-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
        $Packages | Set-Content -LiteralPath (Join-Path $ProjectDir "requirements.txt") -Encoding ascii
        & $DownloaderPath -ProjectDir $ProjectDir -OutputDir $OutputDir
    }
    finally {
        Remove-Item -LiteralPath $ProjectDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
Invoke-PackageListDownload -Packages $Packages -OutputDir $OutputDir
