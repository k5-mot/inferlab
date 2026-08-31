. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-Difypkg.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "dify"
}
Assert-DownloadScript @TestParameters
