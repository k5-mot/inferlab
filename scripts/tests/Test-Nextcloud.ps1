. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

$OutputDir = New-DownloadTestDirectory -Name "nextcloud"
try {
    Invoke-DownloadTestScript -ScriptName "Download-Nextcloud.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "nextcloud") -Pattern "*.tar.gz"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
