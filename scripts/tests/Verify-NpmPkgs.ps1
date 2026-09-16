. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-NpmPkgs.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "npm"
}
Assert-DownloadScript @TestParameters
