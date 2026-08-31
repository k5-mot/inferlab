. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (Skip-DownloadTestIfCommandMissing -Command "npm") {
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "npm-from-project"
$ProjectDir = Join-Path $OutputDir "project"
try {
    New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
    @'
{
  "private": true,
  "dependencies": {
    "is-number": "7.0.0"
  }
}
'@ | Set-Content -LiteralPath (Join-Path $ProjectDir "package.json") -Encoding ascii

    $PreviousValue = $env:INFERLAB_DOWNLOAD_TEST
    $env:INFERLAB_DOWNLOAD_TEST = "1"
    try {
        & (Join-Path $PSScriptRoot "../Download-NpmPkgs-from-Project.ps1") `
            -OutputDir $OutputDir `
            -ProjectDir $ProjectDir
    }
    finally {
        $env:INFERLAB_DOWNLOAD_TEST = $PreviousValue
    }
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "npm") -Pattern "*.tgz"
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
