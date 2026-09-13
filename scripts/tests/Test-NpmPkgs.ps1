. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (Skip-DownloadTestIfCommandMissing -Command "npm") {
    exit 0
}

$OutputDir = Join-Path $PSScriptRoot "../../tests/.tmp/download-test-npm-$([guid]::NewGuid().ToString("N"))"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$UserCacheDir = Join-Path $OutputDir "user-cache"
$PreviousCache = $env:NPM_CONFIG_CACHE
try {
    $env:NPM_CONFIG_CACHE = $UserCacheDir
    Invoke-DownloadTestScript -ScriptName "Download-NpmPkgs.ps1" -OutputDir $OutputDir
    foreach ($Pattern in @(
        "types-react-18.*.tgz",
        "types-react-dom-19.*.tgz",
        "is-number-6.0.0.tgz",
        "is-number-7.0.0.tgz"
    )) {
        Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "npm") -Pattern $Pattern
    }
    if (Test-Path -LiteralPath $UserCacheDir) {
        throw "user npm cacheが使用されました: $UserCacheDir"
    }
}
finally {
    $env:NPM_CONFIG_CACHE = $PreviousCache
    Remove-DownloadTestDirectory -Path $OutputDir
}
