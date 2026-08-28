. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-NpmPkgs-from-Project.ps1"
    ExpectedParameters = @("OutputDir", "ProjectDir", "Help")
    ExpectedOutputDirectory = "npm"
}
Assert-DownloadScript @TestParameters
