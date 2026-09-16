. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

<#
.SYNOPSIS
文字列をgzip fileとして保存します。
.PARAMETER Path
保存先file pathです。
.PARAMETER Content
圧縮する文字列です。
.OUTPUTS
値は返しません。
#>
function Write-GzipText {
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $OutputStream = [System.IO.File]::Create($Path)
    try {
        $GzipStream = [System.IO.Compression.GzipStream]::new(
            $OutputStream,
            [System.IO.Compression.CompressionMode]::Compress
        )
        try {
            $Writer = [System.IO.StreamWriter]::new($GzipStream, [System.Text.UTF8Encoding]::new($false))
            try {
                $Writer.Write($Content)
            }
            finally {
                $Writer.Dispose()
            }
        }
        finally {
            $GzipStream.Dispose()
        }
    }
    finally {
        $OutputStream.Dispose()
    }
}

$OutputDir = New-DownloadTestDirectory -Name "deb"
$RepositoryDirectory = Join-Path $OutputDir "repository"
$PoolDirectory = Join-Path $RepositoryDirectory "pool"
$DownloadDirectory = Join-Path $OutputDir "download"
try {
    New-Item -ItemType Directory -Path $PoolDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
    foreach ($FileName in @(
        "python3_3.10.4-0ubuntu2_amd64.deb",
        "python3_3.10.12-1~22.04.12_amd64.deb",
        "mawk_1.3.4_amd64.deb"
    )) {
        Set-Content -LiteralPath (Join-Path $PoolDirectory $FileName) -Value $FileName -Encoding ascii
    }

    Write-GzipText -Path (Join-Path $RepositoryDirectory "release.gz") -Content @"
Package: python3
Version: 3.10.4-0ubuntu2
Architecture: amd64
Filename: pool/python3_3.10.4-0ubuntu2_amd64.deb
Depends: awk

Package: mawk
Version: 1.3.4
Architecture: amd64
Filename: pool/mawk_1.3.4_amd64.deb
Provides: awk

"@
    Write-GzipText -Path (Join-Path $RepositoryDirectory "updates.gz") -Content @"
Package: python3
Version: 3.10.12-1~22.04.12
Architecture: amd64
Filename: pool/python3_3.10.12-1~22.04.12_amd64.deb
Depends: awk

"@

    $ScriptPath = Join-Path $PSScriptRoot "../Download-DEB.ps1"
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath,
        [ref]$Tokens,
        [ref]$ParseErrors
    )
    if ($ParseErrors.Count -gt 0) {
        throw "Download-DEB.ps1 にPowerShell構文errorがあります: $($ParseErrors.Message -join '; ')"
    }
    $Ast.FindAll({
        param ($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | ForEach-Object { Invoke-Expression $_.Extent.Text }

    $RepositoryUri = ([System.Uri]::new($RepositoryDirectory.TrimEnd("\") + "\")).AbsoluteUri
    Save-DebPackagesWithDependencies `
        -PackageNames @("python3") `
        -PackageSources @(
            [pscustomobject]@{
                BaseUrl = $RepositoryUri
                PackagesUrl = ([System.Uri]::new((Join-Path $RepositoryDirectory "release.gz"))).AbsoluteUri
            },
            [pscustomobject]@{
                BaseUrl = $RepositoryUri
                PackagesUrl = ([System.Uri]::new((Join-Path $RepositoryDirectory "updates.gz"))).AbsoluteUri
            }
        ) `
        -OutputDirectory $DownloadDirectory `
        -TemporaryDirectory $OutputDir

    Assert-DownloadTestArtifacts -Directory $DownloadDirectory -Pattern @(
        "python3_3.10.12-1~22.04.12_amd64.deb",
        "mawk_1.3.4_amd64.deb"
    )
    if (Get-ChildItem -Path $DownloadDirectory -Filter "python3_3.10.4-*.deb" -File -ErrorAction SilentlyContinue) {
        throw "Download-DEB.ps1が旧versionのDEBを取得しました。"
    }
}
finally {
    Remove-DownloadTestDirectory -Path $OutputDir
}
