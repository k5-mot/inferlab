. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

$OutputDir = New-DownloadTestDirectory -Name "rpm"
try {
    Invoke-DownloadTestScript -ScriptName "Download-RPM.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "rpm") -Pattern "*.rpm"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
