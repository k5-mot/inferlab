. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (Skip-DownloadTestIfCommandMissing -Command "hf") {
    exit 0
}
hf --help *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Skip download test because hf is not runnable."
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "hfrepo"
try {
    Invoke-DownloadTestScript -ScriptName "Download-HFRepo.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "hfrepo") -Pattern "*"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
