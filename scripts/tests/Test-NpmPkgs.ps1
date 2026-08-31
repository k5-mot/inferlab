. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (Skip-DownloadTestIfCommandMissing -Command "npm") {
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "npm"
try {
    Invoke-DownloadTestScript -ScriptName "Download-NpmPkgs.ps1" -OutputDir $OutputDir
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "npm") -Pattern "*.tgz"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
