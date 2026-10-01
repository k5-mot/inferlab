. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (-not (Test-Python3Command)) {
    Write-Host "Skip download test because runnable Python 3 was not found."
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "pip-from-project"
$ProjectDir = Join-Path $OutputDir "project"
$UserCacheDir = Join-Path $OutputDir "user-cache"
$PreviousCache = $env:PIP_CACHE_DIR
try {
    $env:PIP_CACHE_DIR = $UserCacheDir
    New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
    "six==1.16.0" | Set-Content -LiteralPath (Join-Path $ProjectDir "requirements.txt") -Encoding ascii

    $PreviousValue = $env:DOWNLOAD_TEST
    $env:DOWNLOAD_TEST = "1"
    try {
        & (Join-Path $PSScriptRoot "../Download-PipPkgs-from-Project.ps1") `
            -OutputDir $OutputDir `
            -ProjectDir $ProjectDir
    }
    finally {
        $env:DOWNLOAD_TEST = $PreviousValue
    }
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "pypi") -Pattern @("*.whl", "*.tar.gz", "*.zip")
    if (Test-Path -LiteralPath $UserCacheDir) {
        throw "user pip cacheが使用されました: $UserCacheDir"
    }

    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $LockedProjectDir = Join-Path $OutputDir "locked-project"
        $LockedOutputDir = Join-Path $OutputDir "locked-output"
        New-Item -ItemType Directory -Path $LockedProjectDir -Force | Out-Null
        @'
[project]
name = "pip-lock-fixture"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = ["six>=1.16,<2"]

[tool.uv]
resolution = "lowest-direct"
'@ | Set-Content -LiteralPath (Join-Path $LockedProjectDir "pyproject.toml") -Encoding ascii
        uv lock --project $LockedProjectDir --cache-dir (Join-Path $OutputDir "uv-cache")
        if ($LASTEXITCODE -ne 0) {
            throw "uv lockfile fixtureの作成に失敗しました。"
        }

        $PreviousValue = $env:DOWNLOAD_TEST
        $env:DOWNLOAD_TEST = "1"
        try {
            & (Join-Path $PSScriptRoot "../Download-PipPkgs-from-Project.ps1") `
                -OutputDir $LockedOutputDir `
                -ProjectDir $LockedProjectDir
        }
        finally {
            $env:DOWNLOAD_TEST = $PreviousValue
        }
        $ArchiveNames = @(Get-ChildItem -LiteralPath (Join-Path $LockedOutputDir "pypi") -Filter "six-*.whl" -Name)
        if ($ArchiveNames.Count -ne 1 -or $ArchiveNames[0] -ne "six-1.16.0-py2.py3-none-any.whl") {
            throw "uv.lockと異なるversionが取得されました: $($ArchiveNames -join ', ')"
        }
    }
}
finally {
    $env:PIP_CACHE_DIR = $PreviousCache
    Remove-DownloadTestDirectory -Path $OutputDir
}
