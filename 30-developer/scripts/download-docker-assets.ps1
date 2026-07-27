$ErrorActionPreference = "Stop"

# tarとして取得するcontainer imageを定義する。
$ContainerImages = @(
    [pscustomobject]@{ Source = "docker.io/library/hello-world:latest"; File = "hello-world_latest.tar" },
    [pscustomobject]@{ Source = "docker.io/ollama/ollama:latest"; File = "ollama_ollama_latest.tar" }
)

$ScriptDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDirectory "download-assets-common.ps1")

$AssetsPath = Get-AssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory (Get-Location).Path
Write-Host "assets directory: $AssetsPath"

New-AssetDirectories -AssetsPath $AssetsPath -Names @("docker")
$DockerAssetsDir = Join-Path $AssetsPath "docker"

foreach ($Image in $ContainerImages) {
    Invoke-NativeCommand -FilePath "crane" -Arguments @("pull", $Image.Source, (Join-Path $DockerAssetsDir $Image.File))
}

Assert-AssetFilesExist -Directory $DockerAssetsDir -Pattern "*.tar" -Description "Docker"
