. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (Skip-DownloadTestIfCommandMissing -Command "uv") {
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "refine-pip"
$ProjectDir = Join-Path $OutputDir "project"
$RequirementsFixturePath = Join-Path $PSScriptRoot "pypi-legacy/requirements.txt"
$TransitiveFixturePath = Join-Path $PSScriptRoot "pypi-legacy/requirements3.txt"
try {
    if (-not ((Get-Content -LiteralPath $RequirementsFixturePath) -match "^cffi==1\.17\.1$")) {
        throw "test fixtureにはPython 3.14用wheelがないcffi 1.17.1を固定してください。"
    }
    if ((Get-Content -LiteralPath $RequirementsFixturePath) -match "^pycparser(?:[<=>!~].*)?$") {
        throw "test fixtureにはcffiの推移依存pycparserを記載しないでください。"
    }
    New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
    Copy-Item `
        -LiteralPath $RequirementsFixturePath `
        -Destination (Join-Path $ProjectDir "requirements.txt")

    & (Join-Path $PSScriptRoot "../Refine-PipPkgs.ps1") -ProjectDir $ProjectDir

    $Full = Get-Content -LiteralPath (Join-Path $ProjectDir "requirements-full.txt")
    $Next = Get-Content -LiteralPath (Join-Path $ProjectDir "requirements-next.txt")
    if (-not ($Full -match "^cffi==2\.")) {
        throw "requirements-full.txtでsource build不要なcffi 2系が選択されませんでした。"
    }
    if (-not ($Full -match "^pycparser==")) {
        throw "requirements-full.txtに推移依存pycparserがありません。"
    }
    if (-not ($Full -match "^six==1\.16\.0$")) {
        throw "requirements-full.txtが元のversion制約を維持していません。"
    }
    if (-not ($Next -match "^six==") -or $Next -match "^six==1\.16\.0$") {
        throw "requirements-next.txtでsixがupgradeされませんでした。"
    }

    if (-not ((Get-Content -LiteralPath $TransitiveFixturePath) -match "^dbt-core==1\.7\.20$")) {
        throw "推移依存test fixtureにはdbt-core 1.7.20を固定してください。"
    }
    $TransitiveProjectDir = Join-Path $OutputDir "transitive-project"
    New-Item -ItemType Directory -Path $TransitiveProjectDir -Force | Out-Null
    Copy-Item `
        -LiteralPath $TransitiveFixturePath `
        -Destination (Join-Path $TransitiveProjectDir "requirements.txt")

    & (Join-Path $PSScriptRoot "../Refine-PipPkgs.ps1") -ProjectDir $TransitiveProjectDir

    $TransitiveFull = Get-Content -LiteralPath (Join-Path $TransitiveProjectDir "requirements-full.txt")
    if (-not ($TransitiveFull -match "^dbt-core==") -or $TransitiveFull -match "^dbt-core==1\.7\.20$") {
        throw "wheel非対応の推移依存を持つdbt-coreがupgradeされませんでした。"
    }
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
