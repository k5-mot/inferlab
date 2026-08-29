. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-DEB.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "deb"
}
Assert-DownloadScript @TestParameters
