. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$ScriptPath = Join-Path $PSScriptRoot "../Download-PipPkgs-from-Project.ps1"
$TestParameters = @{
    ScriptPath = $ScriptPath
    ExpectedParameters = @("OutputDir", "ProjectDir", "Help")
    ExpectedOutputDirectory = "pypi"
}
Assert-DownloadScript @TestParameters

$Source = Get-Content -LiteralPath $ScriptPath -Raw
foreach ($PythonVersion in @("3.12", "3.13", "3.14", "3.15")) {
    if ($Source -notmatch [regex]::Escape($PythonVersion)) {
        throw "Python version '$PythonVersion' が定義されていません。"
    }
}
foreach ($Platform in @(
    "any",
    "win32",
    "win_amd64",
    "manylinux_2_34_x86_64",
    "manylinux_2_28_x86_64",
    "manylinux_2_24_x86_64",
    "manylinux_2_17_x86_64",
    "manylinux2014_x86_64"
)) {
    if ($Source -notmatch [regex]::Escape($Platform)) {
        throw "Python platform '$Platform' が定義されていません。"
    }
}
