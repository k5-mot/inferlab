. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-RPM.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "rpm"
}
Assert-DownloadScript @TestParameters

$Source = Get-Content -LiteralPath $TestParameters.ScriptPath -Raw
if ($Source -notmatch [regex]::Escape('DirectoryName = "oracle-linux-9"')) {
    throw "Download-RPM.ps1がdistribution別directoryを定義していません。"
}
