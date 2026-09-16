. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-DEB.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "deb"
}
Assert-DownloadScript @TestParameters

$Source = Get-Content -Raw -Path $TestParameters.ScriptPath
if ($Source -match "New-TemporaryFile") {
    throw "Download-DEB.ps1 must not use the user profile temporary directory."
}
if ($Source -notmatch "\.deb-packages-") {
    throw "Download-DEB.ps1 must create Packages metadata under OutputDir."
}
foreach ($DirectoryName in @("debian-13", "ubuntu-24.04", "ubuntu-22.04")) {
    if ($Source -notmatch [regex]::Escape("DirectoryName = `"$DirectoryName`"")) {
        throw "Download-DEB.ps1にdistribution別directory '$DirectoryName' がありません。"
    }
}
foreach ($Pocket in @("noble-updates", "noble-security", "jammy-updates", "jammy-security")) {
    if ($Source -notmatch [regex]::Escape($Pocket)) {
        throw "Download-DEB.ps1にrepository pocket '$Pocket' がありません。"
    }
}
