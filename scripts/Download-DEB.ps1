<#
.SYNOPSIS
Debian 13およびUbuntu 24.04 LTS x86_64向けのdeb packageを取得します。

.DESCRIPTION
Debian 13（trixie）とUbuntu 24.04 LTS（noble）のrepositoryから、指定したdeb packageと依存packageを取得します。

既定では`/srv/12-registry/deb/`へ保存します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-DEB.ps1 -OutputDir C:\airgap

指定directoryの`deb`配下へpackageを依存込みで取得します。

.NOTES
副作用として指定directoryへ`.deb` fileを作成または上書きします。

実行にはPowerShellと外部repositoryへのHTTP接続が必要です。

Save-DebPackagesWithDependenciesのPackagesUrl parameterは、
複数のURLを受け取れる必要があります。
#>
[CmdletBinding()]
param (
    [string]$OutputDir,
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}
if (-not $OutputDir) {
    throw "OutputDir is required."
}

$ErrorActionPreference = "Stop"
$Packages = @(
        "bash",
        "zsh",
        "curl",
        "git",
        "jq",
        "tmux",
        "neovim",
        "vim",
        "build-essential",
        "pkg-config",
        "libreadline-dev",
        "libncurses-dev",
        "clang",
        "ncdu"
)
$Registries = @(
    [pscustomobject]@{
        Name = "Debian 13 (trixie)"
        BaseUrl = "https://deb.debian.org/debian/"
        PackagePaths = @(
            "dists/trixie/main/binary-amd64/Packages.gz"
        )
    },
    [pscustomobject]@{
        Name = "Ubuntu 24.04 LTS (noble)"
        BaseUrl = "https://archive.ubuntu.com/ubuntu/"
        PackagePaths = @(
            "dists/noble/main/binary-amd64/Packages.gz",
            "dists/noble/universe/binary-amd64/Packages.gz"
        )
    }
)
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Packages = @("hello")
}

$Packages = @(
    $Packages |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Unique
)

if ($Packages.Count -eq 0) {
    throw "取得するdeb packageが指定されていません。"
}

<#
.SYNOPSIS
repository URLと相対pathを結合します。
.PARAMETER BaseUrl
repository rootのURLです。
.PARAMETER RelativePath
repository rootからの相対pathです。
.OUTPUTS
結合済みURL文字列を返します。
#>
function Join-RepositoryUrl {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    return $BaseUrl.TrimEnd("/") + "/" + $RelativePath.TrimStart("/")
}

<#
.SYNOPSIS
HTTPでfileを取得し、既存fileを置き換えます。
.PARAMETER Url
取得元URLです。
.PARAMETER OutputPath
保存先file pathです。
.OUTPUTS
値は返しません。
.NOTES
Windows PowerShell 5.1のInvoke-WebRequest進捗表示を避けるためWebClientを使用します。
#>
function Save-FileFromUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
    $WebClient = [System.Net.WebClient]::new()
    try {
        $WebClient.DownloadFile($Url, $OutputPath)
    } finally {
        $WebClient.Dispose()
    }
}

<#
.SYNOPSIS
gzip圧縮されたtext fileをHTTPで取得して展開します。
.PARAMETER Url
gzip fileの取得元URLです。
.OUTPUTS
展開済みtextを返します。
.NOTES
一時fileを作成し、読み取り後に削除します。
#>
function Read-GzipTextFromUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url
    )

    $TempFile = New-TemporaryFile
    try {
        Save-FileFromUrl -Url $Url -OutputPath $TempFile.FullName
        $InputStream = [System.IO.File]::OpenRead($TempFile.FullName)
        try {
            $GzipStream = [System.IO.Compression.GzipStream]::new($InputStream, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $Reader = [System.IO.StreamReader]::new($GzipStream, [System.Text.Encoding]::UTF8)
                try {
                    return $Reader.ReadToEnd()
                } finally {
                    $Reader.Dispose()
                }
            } finally {
                $GzipStream.Dispose()
            }
        } finally {
            $InputStream.Dispose()
        }
    } finally {
        Remove-Item -Force $TempFile.FullName
    }
}

<#
.SYNOPSIS
Debian Packages metadataをpackage名で引けるindexへ変換します。
.PARAMETER PackagesUrl
Packages.gzのURLです。
.OUTPUTS
package名をkey、metadata hashtableをvalueにしたhashtableを返します。
#>
function Get-DebPackageIndex {
    param(
        [Parameter(Mandatory = $true)][string]$PackagesUrl
    )

    $Index = @{}
    $Text = Read-GzipTextFromUrl -Url $PackagesUrl
    foreach ($Entry in ($Text -split "(?:`r?`n){2,}")) {
        if ([string]::IsNullOrWhiteSpace($Entry)) {
            continue
        }

        $Fields = @{}
        $CurrentField = $null
        foreach ($Line in ($Entry -split "`r?`n")) {
            if ($Line -match "^([^:]+):\s*(.*)$") {
                $CurrentField = $Matches[1]
                $Fields[$CurrentField] = $Matches[2]
            } elseif ($Line -match "^\s+(.*)$" -and $CurrentField) {
                $Fields[$CurrentField] = $Fields[$CurrentField] + " " + $Matches[1]
            }
        }

        if ($Fields.ContainsKey("Package") -and -not $Index.ContainsKey($Fields["Package"])) {
            $Index[$Fields["Package"]] = $Fields
        }
    }

    return $Index
}

<#
.SYNOPSIS
deb package metadataから依存package名を取り出します。
.PARAMETER Package
Packages metadataの1 package分のhashtableです。
.OUTPUTS
依存package名の配列を返します。
#>
function Get-DebDependencyNames {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Package
    )

    $Dependencies = [System.Collections.Generic.List[string]]::new()
    foreach ($FieldName in @("Pre-Depends", "Depends")) {
        if (-not $Package.ContainsKey($FieldName)) {
            continue
        }

        foreach ($Part in ($Package[$FieldName] -split ",")) {
            $Candidate = (($Part -split "\|")[0]).Trim()
            $Name = ($Candidate -replace "\s*\(.*?\)", "" -replace ":[A-Za-z0-9][A-Za-z0-9-]*", "").Trim()
            if ($Name -and -not $Dependencies.Contains($Name)) {
                $Dependencies.Add($Name)
            }
        }
    }

    return $Dependencies.ToArray()
}

<#
.SYNOPSIS
deb packageと依存packageをHTTP repositoryから取得します。
.PARAMETER PackageNames
取得するroot package名です。
.PARAMETER RepositoryBaseUrl
Debian repository rootのURLです。
.PARAMETER PackagesUrl
Packages.gzのURLです。
.PARAMETER OutputDirectory
deb fileの保存先directoryです。
.OUTPUTS
値は返しません。
#>
function Save-DebPackagesWithDependencies {
    param(
        [Parameter(Mandatory = $true)][string[]]$PackageNames,
        [Parameter(Mandatory = $true)][string]$RepositoryBaseUrl,
        [Parameter(Mandatory = $true)][string[]]$PackagesUrl,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    if ($PackageNames.Count -eq 0) {
        return
    }

    $Index = @{}
    foreach ($Url in $PackagesUrl) {
        $PartialIndex = Get-DebPackageIndex -PackagesUrl $Url
        foreach ($Name in $PartialIndex.Keys) {
            if (-not $Index.ContainsKey($Name)) {
                $Index[$Name] = $PartialIndex[$Name]
            }
        }
    }

    $Queue = [System.Collections.Queue]::new()
    $Seen = @{}
    foreach ($Name in $PackageNames) {
        $Queue.Enqueue($Name)
    }

    while ($Queue.Count -gt 0) {
        $Name = [string]$Queue.Dequeue()
        if ($Seen.ContainsKey($Name)) {
            continue
        }

        $Seen[$Name] = $true
        if (-not $Index.ContainsKey($Name)) {
            Write-Warning "deb package not found: $Name"
            continue
        }

        $Package = $Index[$Name]
        $FileName = Split-Path -Leaf $Package["Filename"]
        $OutputPath = Join-Path $OutputDirectory $FileName
        Save-FileFromUrl -Url (Join-RepositoryUrl -BaseUrl $RepositoryBaseUrl -RelativePath $Package["Filename"]) -OutputPath $OutputPath

        foreach ($Dependency in (Get-DebDependencyNames -Package $Package)) {
            if (-not $Seen.ContainsKey($Dependency)) {
                $Queue.Enqueue($Dependency)
            }
        }
    }
}

<#
.SYNOPSIS
directoryにfileが存在することを検証します。
.PARAMETER Directory
検証するdirectoryです。
.PARAMETER Pattern
対象file pattern配列です。
.PARAMETER Description
エラー表示用の資材種別です。
.OUTPUTS
値は返しません。
#>
function Assert-AssetFilesExist {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $Files = @()
    foreach ($ItemPattern in $Pattern) {
        $Files += @(Get-ChildItem -Path $Directory -Filter $ItemPattern -File -ErrorAction SilentlyContinue)
    }

    if ($Files.Count -eq 0) {
        throw "$Description assets were not created: $Directory"
    }
}

$DestinationDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "deb"

New-Item `
    -ItemType Directory `
    -Path $DestinationDirectory `
    -Force |
    Out-Null

Write-Host "Debian and Ubuntu deb packages:"
Write-Host "  Packages: $($Packages -join ', ')"
Write-Host "  Destination: $DestinationDirectory"

foreach ($Registry in $Registries) {
    $PackagesUrls = @(
        foreach ($PackagesPath in $Registry.PackagePaths) {
            Join-RepositoryUrl `
                -BaseUrl $Registry.BaseUrl `
                -RelativePath $PackagesPath
        }
    )

    Write-Host "  Repository: $($Registry.Name)"
    foreach ($PackagesUrl in $PackagesUrls) {
        Write-Host "    $PackagesUrl"
    }

    Save-DebPackagesWithDependencies `
        -PackageNames $Packages `
        -PackagesUrl $PackagesUrls `
        -RepositoryBaseUrl $Registry.BaseUrl `
        -OutputDirectory $DestinationDirectory
}

Assert-AssetFilesExist `
    -Directory $DestinationDirectory `
    -Pattern "*.deb" `
    -Description "Debian/Ubuntu deb"
