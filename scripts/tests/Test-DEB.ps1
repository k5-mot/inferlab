. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

$OutputDir = New-DownloadTestDirectory -Name "deb"
try {
    Invoke-DownloadTestScript -ScriptName "Download-DEB.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "deb") -Pattern "*.deb"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
