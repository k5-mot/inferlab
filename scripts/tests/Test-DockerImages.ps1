. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (Skip-DownloadTestIfCommandMissing -Command "crane") {
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "docker"
try {
    Invoke-DownloadTestScript -ScriptName "Download-DockerImages.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "docker") -Pattern "*.tar"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
