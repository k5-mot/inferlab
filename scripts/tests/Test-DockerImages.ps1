. (Join-Path $PSScriptRoot "Assert-DownloadScript.ps1")

$TestParameters = @{
    ScriptPath = Join-Path $PSScriptRoot "../Download-DockerImages.ps1"
    ExpectedParameters = @("OutputDir", "Help")
    ExpectedOutputDirectory = "docker"
}
Assert-DownloadScript @TestParameters

$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../.."))
$ScriptSource = Get-Content -LiteralPath $TestParameters.ScriptPath -Raw
$ComposePaths = @(& git -C $RepositoryRoot ls-files "*compose*.yml" "*compose*.yaml")
if ($LASTEXITCODE -ne 0) {
    throw "Compose file一覧を取得できません。"
}
foreach ($ComposePath in $ComposePaths) {
    foreach ($Line in Get-Content -LiteralPath (Join-Path $RepositoryRoot $ComposePath)) {
        if ($Line -notmatch '^\s*image:\s*[''"]?([^''"\s]+)') {
            continue
        }
        $Image = $Matches[1]
        if ($Image.Contains("$")) {
            continue
        }
        if ($ScriptSource -notmatch [regex]::Escape($Image)) {
            throw "Compose image '$Image' がPackagesまたはlocal imageに定義されていません。"
        }
    }
}
