. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-VSIX.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "vscode"
}
Assert-DownloadScript @TestParameters
