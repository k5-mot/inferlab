. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (Skip-DownloadTestIfCommandMissing -Command "npm") {
    exit 0
}

$OutputDir = Join-Path $PSScriptRoot "../../tests/.tmp/download-test-npm-from-project-$([guid]::NewGuid().ToString("N"))"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$ProjectDir = Join-Path $OutputDir "project"
$UserCacheDir = Join-Path $OutputDir "user-cache"
$PreviousCache = $env:NPM_CONFIG_CACHE
try {
    New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
    @'
{
  "private": true,
  "dependencies": {
    "tailwindcss": "4"
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
    Assert-DownloadTestArtifacts -Directory (Join-Path $OutputDir "npm") -Pattern "tailwindcss-4.*.tgz"
    if (Test-Path -LiteralPath $UserCacheDir) {
        throw "user npm cacheが使用されました: $UserCacheDir"
    }

    $LockedProjectDir = Join-Path $OutputDir "locked-project"
    $LockedOutputDir = Join-Path $OutputDir "locked-output"
    New-Item -ItemType Directory -Path $LockedProjectDir -Force | Out-Null
    '{ "private": true }' | Set-Content -LiteralPath (Join-Path $LockedProjectDir "package.json") -Encoding ascii
    Push-Location $LockedProjectDir
    try {
        npm install lodash@4.17.20 --package-lock-only --ignore-scripts --no-audit --no-fund --save-prefix='^' "--cache=$(Join-Path $OutputDir 'fixture-cache')"
        if ($LASTEXITCODE -ne 0) {
            throw "npm lockfile fixtureの作成に失敗しました。"
        }
    }
    finally {
        Pop-Location
    }

    & (Join-Path $PSScriptRoot "../Download-NpmPkgs-from-Project.ps1") `
        -OutputDir $LockedOutputDir `
        -ProjectDir $LockedProjectDir
    $ArchiveNames = @(Get-ChildItem -LiteralPath (Join-Path $LockedOutputDir "npm") -Filter "lodash-*.tgz" -Name)
    if ($ArchiveNames.Count -ne 1 -or $ArchiveNames[0] -ne "lodash-4.17.20.tgz") {
        throw "package-lock.jsonと異なるversionが取得されました: $($ArchiveNames -join ', ')"
    }
}
finally {
    $env:NPM_CONFIG_CACHE = $PreviousCache
    Remove-DownloadTestDirectory -Path $OutputDir
}
