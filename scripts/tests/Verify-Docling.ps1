. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-Docling.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "docling"
}
Assert-DownloadScript @TestParameters
