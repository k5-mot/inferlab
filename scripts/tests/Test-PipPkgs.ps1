. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (-not (Test-Python3Command)) {
    Write-Host "Skip download test because runnable Python 3 was not found."
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "pip"
try {
    Invoke-DownloadTestScript -ScriptName "Download-PipPkgs.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "pypi") -Pattern @("*.whl", "*.tar.gz", "*.zip")
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
