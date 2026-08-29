. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (-not (Test-Python3Command)) {
    Write-Host "Skip download test because runnable Python 3 was not found."
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "pip-from-project"
$ProjectDir = Join-Path $OutputDir "project"
try {
    New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
    "six==1.16.0" | Set-Content -LiteralPath (Join-Path $ProjectDir "requirements.txt") -Encoding ascii

    $PreviousValue = $env:INFERLAB_DOWNLOAD_TEST
    $env:INFERLAB_DOWNLOAD_TEST = "1"
    try {
        & (Join-Path $PSScriptRoot "../Download-PipPkgs-from-Project.ps1") `
            -OutputDir $OutputDir `
            -ProjectDir $ProjectDir
    }
    finally {
        $env:INFERLAB_DOWNLOAD_TEST = $PreviousValue
    }
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "pypi") -Pattern @("*.whl", "*.tar.gz", "*.zip")
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
