<#
.SYNOPSIS
air-gap検証projectで使用するDEB、Python wheel、npm archiveを取得します。

.NOTES
backend/deb、backend/pypi、frontend/npmへ資材を作成または上書きします。
#>
$ErrorActionPreference = "Stop"
$ScriptsDirectory = Split-Path -Parent $PSScriptRoot
$BackendDirectory = Join-Path $PSScriptRoot "backend"
$FrontendDirectory = Join-Path $PSScriptRoot "frontend"

& (Join-Path $ScriptsDirectory "Download-DEB.ps1") -OutputDir $BackendDirectory
& (Join-Path $ScriptsDirectory "Download-PipPkgs-from-Project.ps1") `
    -ProjectDir $BackendDirectory `
    -OutputDir $BackendDirectory
& (Join-Path $ScriptsDirectory "Download-NpmPkgs-from-Project.ps1") `
    -ProjectDir $FrontendDirectory `
    -OutputDir $FrontendDirectory
