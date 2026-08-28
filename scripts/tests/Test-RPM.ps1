. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-RPM.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "rpm"
}
Assert-DownloadScript @TestParameters
