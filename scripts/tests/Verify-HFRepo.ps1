. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-HFRepo.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "hfrepo"
}
Assert-DownloadScript @TestParameters
