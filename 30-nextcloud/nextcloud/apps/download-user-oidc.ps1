$ErrorActionPreference = "Stop"

$Version = if ($env:USER_OIDC_VERSION) {
    $env:USER_OIDC_VERSION
} else {
    "8.10.1"
}

$DestinationDirectory = Join-Path $PSScriptRoot "apps"
$DestinationFile = Join-Path `
    $DestinationDirectory `
    "user_oidc-v$Version.tar.gz"

$Url = "https://github.com/nextcloud-releases/user_oidc/releases/download/v$Version/user_oidc-v$Version.tar.gz"

New-Item `
    -ItemType Directory `
    -Path $DestinationDirectory `
    -Force | Out-Null

Write-Host "Downloading user_oidc v$Version..."

Invoke-WebRequest `
    -Uri $Url `
    -OutFile $DestinationFile

Write-Host "Downloaded: $DestinationFile"
