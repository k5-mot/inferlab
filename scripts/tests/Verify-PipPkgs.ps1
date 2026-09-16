. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-PipPkgs.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "pypi"
}
Assert-DownloadScript @TestParameters

$Source = Get-Content -LiteralPath $TestParameters.ScriptPath -Raw
if ($Source -match [regex]::Escape("[System.IO.Path]::GetTempPath()")) {
    throw "Download-PipPkgs.ps1がuser側の一時directoryを使用しています。"
}
foreach ($Pattern in @(".pip-download-", '"--no-cache-dir"')) {
    if ($Source -notmatch [regex]::Escape($Pattern)) {
        throw "pip作業領域のquota対策がありません: $Pattern"
    }
}
foreach ($PythonVersion in @("3.10", "3.11", "3.12", "3.13", "3.14")) {
    if ($Source -notmatch [regex]::Escape($PythonVersion)) {
        throw "Python version '$PythonVersion' が定義されていません。"
    }
}
if ($Source -match [regex]::Escape('"3.15"')) {
    throw "対象外のPython version '3.15' が定義されています。"
}
if ($Source -notmatch [regex]::Escape('"stopwordsiso"')) {
    throw "PyPI package 'stopwordsiso' が定義されていません。"
}
if ($Source -match [regex]::Escape('"stopwordiso"')) {
    throw "存在しないPyPI package 'stopwordiso' が定義されています。"
}
