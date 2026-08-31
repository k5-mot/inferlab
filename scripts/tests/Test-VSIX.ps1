. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

$OutputDir = New-DownloadTestDirectory -Name "vsix"
try {
    Invoke-DownloadTestScript -ScriptName "Download-VSIX.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "vscode") -Pattern "*.vsix"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
