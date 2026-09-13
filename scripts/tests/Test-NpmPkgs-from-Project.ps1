. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (Skip-DownloadTestIfCommandMissing -Command "npm") {
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "npm-from-project"
$ProjectDir = Join-Path $OutputDir "project"
$UserCacheDir = Join-Path $OutputDir "user-cache"
$PreviousCache = $env:NPM_CONFIG_CACHE
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

    $PreviousValue = $env:DOWNLOAD_TEST
    $env:DOWNLOAD_TEST = "1"
    $env:NPM_CONFIG_CACHE = $UserCacheDir
    try {
        & (Join-Path $PSScriptRoot "../Download-NpmPkgs-from-Project.ps1") `
            -OutputDir $OutputDir `
            -ProjectDir $ProjectDir
    }
    finally {
        $env:DOWNLOAD_TEST = $PreviousValue
    }
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "npm") -Pattern "*.tgz"
    if (Test-Path -LiteralPath $UserCacheDir) {
        throw "user npm cacheが使用されました: $UserCacheDir"
    }
}
finally {
    $env:NPM_CONFIG_CACHE = $PreviousCache
    Remove-DownloadTestDirectory -Path $OutputDir
}
