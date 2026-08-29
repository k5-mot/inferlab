. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

$OutputDir = New-DownloadTestDirectory -Name "difypkg"
try {
    Invoke-DownloadTestScript -ScriptName "Download-Difypkg.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "dify") -Pattern "*.difypkg"
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "dify") -Pattern "SHA256SUMS"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
