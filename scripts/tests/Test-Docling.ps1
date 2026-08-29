. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

$OutputDir = New-DownloadTestDirectory -Name "docling"
try {
    Invoke-DownloadTestScript -ScriptName "Download-Docling.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "docling") -Pattern "*.traineddata"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
