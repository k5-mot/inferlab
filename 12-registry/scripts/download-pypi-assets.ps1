$ErrorActionPreference = "Stop"

# PyPIから依存込みで取得するpackageを定義する。
$PypiPackages = @(
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
)

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDirectory "download-assets-common.ps1")

$AssetsPath = Get-AssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory (Get-Location).Path
Write-Host "assets directory: $AssetsPath"

New-AssetDirectories -AssetsPath $AssetsPath -Names @("pypi")
$PypiAssetsDir = Join-Path $AssetsPath "pypi"

Invoke-PythonCommand -Arguments (@("-m", "pip", "download", "--dest", $PypiAssetsDir) + $PypiPackages)
Assert-AssetFilesExist -Directory $PypiAssetsDir -Pattern @("*.whl", "*.tar.gz", "*.zip") -Description "PyPI"
