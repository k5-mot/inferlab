. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

if (Skip-DownloadTestIfCommandMissing -Command "uv") {
    exit 0
}

$OutputDir = New-DownloadTestDirectory -Name "refine-pip"
$ProjectDir = Join-Path $OutputDir "project"
$RequirementsFixturePath = Join-Path $PSScriptRoot "../../tests/pypi-legacy/requirements.txt"
try {
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
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
