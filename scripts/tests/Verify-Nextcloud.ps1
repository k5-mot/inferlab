. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-Nextcloud.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "nextcloud"
}
Assert-DownloadScript @TestParameters
