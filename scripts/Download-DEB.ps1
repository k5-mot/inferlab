<#
.SYNOPSIS
Debian 13、Ubuntu 24.04 LTS、Ubuntu 22.04 LTS x86_64向けのdeb packageを取得します。

.DESCRIPTION
DebianのmainとUbuntuのrelease、updates、security repositoryから、指定したdeb packageと依存packageを取得します。

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

Packages metadataの一時fileは`OutputDir`配下に作成し、user profileの一時directoryは使用しません。

実行にはPowerShellと外部repositoryへのHTTP接続が必要です。

packageは`deb/<distribution>/`へ分けて保存します。
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
$OutputRoot = [System.IO.Path]::GetFullPath($OutputDir)
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
        "ncdu",
        "python3",
        "python3-pip"
)
$Registries = @(
    [pscustomobject]@{
        Name = "Debian 13 (trixie)"
        DirectoryName = "debian-13"
        Sources = @(
            [pscustomobject]@{
                BaseUrl = "https://deb.debian.org/debian/"
                PackagePaths = @(
                    "dists/trixie/main/binary-amd64/Packages.gz"
                )
            }
        )
    },
    [pscustomobject]@{
        Name = "Ubuntu 24.04 LTS (noble)"
        DirectoryName = "ubuntu-24.04"
        Sources = @(
            [pscustomobject]@{
                BaseUrl = "https://archive.ubuntu.com/ubuntu/"
                PackagePaths = @(
                    "dists/noble/main/binary-amd64/Packages.gz",
                    "dists/noble/universe/binary-amd64/Packages.gz",
                    "dists/noble-updates/main/binary-amd64/Packages.gz",
                    "dists/noble-updates/universe/binary-amd64/Packages.gz"
                )
            },
            [pscustomobject]@{
                BaseUrl = "https://security.ubuntu.com/ubuntu/"
                PackagePaths = @(
                    "dists/noble-security/main/binary-amd64/Packages.gz",
                    "dists/noble-security/universe/binary-amd64/Packages.gz"
                )
            }
        )
    },
    [pscustomobject]@{
        Name = "Ubuntu 22.04 LTS (jammy)"
        DirectoryName = "ubuntu-22.04"
        Sources = @(
            [pscustomobject]@{
                BaseUrl = "https://archive.ubuntu.com/ubuntu/"
                PackagePaths = @(
                    "dists/jammy/main/binary-amd64/Packages.gz",
                    "dists/jammy/universe/binary-amd64/Packages.gz",
                    "dists/jammy-updates/main/binary-amd64/Packages.gz",
                    "dists/jammy-updates/universe/binary-amd64/Packages.gz"
                )
            },
            [pscustomobject]@{
                BaseUrl = "https://security.ubuntu.com/ubuntu/"
                PackagePaths = @(
                    "dists/jammy-security/main/binary-amd64/Packages.gz",
                    "dists/jammy-security/universe/binary-amd64/Packages.gz"
                )
            }
        )
    }
)
if ($env:DOWNLOAD_TEST) {
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
.PARAMETER TemporaryDirectory
gzip fileを一時保存するdirectoryです。
.OUTPUTS
展開済みtextを返します。
.NOTES
一時fileを作成し、読み取り後に削除します。
#>
function Read-GzipTextFromUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$TemporaryDirectory
    )

    New-Item -ItemType Directory -Force -Path $TemporaryDirectory | Out-Null
    $TempPath = Join-Path $TemporaryDirectory ".deb-packages-$([guid]::NewGuid().ToString('N')).gz"
    try {
        Save-FileFromUrl -Url $Url -OutputPath $TempPath
        $InputStream = [System.IO.File]::OpenRead($TempPath)
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
        Remove-Item -Force -ErrorAction SilentlyContinue $TempPath
    }
}

<#
.SYNOPSIS
Debian package versionを比較します。
.PARAMETER Left
比較する左辺のversionです。
.PARAMETER Right
比較する右辺のversionです。
.OUTPUTS
左辺が新しければ1、同じなら0、右辺が新しければ-1を返します。
#>
function Compare-DebVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $LeftEpoch = "0"
    $RightEpoch = "0"
    $LeftRemainder = $Left
    $RightRemainder = $Right
    if ($Left -match "^(?<epoch>\d+):(?<remainder>.*)$") {
        $LeftEpoch = $Matches.epoch
        $LeftRemainder = $Matches.remainder
    }
    if ($Right -match "^(?<epoch>\d+):(?<remainder>.*)$") {
        $RightEpoch = $Matches.epoch
        $RightRemainder = $Matches.remainder
    }

    $LeftEpochNumber = [System.Numerics.BigInteger]::Parse($LeftEpoch)
    $RightEpochNumber = [System.Numerics.BigInteger]::Parse($RightEpoch)
    if ($LeftEpochNumber -gt $RightEpochNumber) { return 1 }
    if ($LeftEpochNumber -lt $RightEpochNumber) { return -1 }

    $LeftRevision = "0"
    $RightRevision = "0"
    $LeftRevisionIndex = $LeftRemainder.LastIndexOf("-")
    $RightRevisionIndex = $RightRemainder.LastIndexOf("-")
    if ($LeftRevisionIndex -ge 0) {
        $LeftRevision = $LeftRemainder.Substring($LeftRevisionIndex + 1)
        $LeftRemainder = $LeftRemainder.Substring(0, $LeftRevisionIndex)
    }
    if ($RightRevisionIndex -ge 0) {
        $RightRevision = $RightRemainder.Substring($RightRevisionIndex + 1)
        $RightRemainder = $RightRemainder.Substring(0, $RightRevisionIndex)
    }

    $LeftParts = @($LeftRemainder, $LeftRevision)
    $RightParts = @($RightRemainder, $RightRevision)
    for ($PartIndex = 0; $PartIndex -lt $LeftParts.Count; $PartIndex += 1) {
        $LeftPart = $LeftParts[$PartIndex]
        $RightPart = $RightParts[$PartIndex]
        $LeftIndex = 0
        $RightIndex = 0
        while ($LeftIndex -lt $LeftPart.Length -or $RightIndex -lt $RightPart.Length) {
            while (
                ($LeftIndex -lt $LeftPart.Length -and -not [char]::IsDigit($LeftPart[$LeftIndex])) -or
                ($RightIndex -lt $RightPart.Length -and -not [char]::IsDigit($RightPart[$RightIndex]))
            ) {
                $LeftOrder = 0
                $RightOrder = 0
                if ($LeftIndex -lt $LeftPart.Length -and -not [char]::IsDigit($LeftPart[$LeftIndex])) {
                    $LeftCharacter = $LeftPart[$LeftIndex]
                    $LeftOrder = if ($LeftCharacter -eq "~") {
                        -1
                    } elseif ([char]::IsLetter($LeftCharacter)) {
                        [int][char]$LeftCharacter
                    } else {
                        [int][char]$LeftCharacter + 256
                    }
                    $LeftIndex += 1
                }
                if ($RightIndex -lt $RightPart.Length -and -not [char]::IsDigit($RightPart[$RightIndex])) {
                    $RightCharacter = $RightPart[$RightIndex]
                    $RightOrder = if ($RightCharacter -eq "~") {
                        -1
                    } elseif ([char]::IsLetter($RightCharacter)) {
                        [int][char]$RightCharacter
                    } else {
                        [int][char]$RightCharacter + 256
                    }
                    $RightIndex += 1
                }
                if ($LeftOrder -gt $RightOrder) { return 1 }
                if ($LeftOrder -lt $RightOrder) { return -1 }
            }

            while ($LeftIndex -lt $LeftPart.Length -and $LeftPart[$LeftIndex] -eq "0") { $LeftIndex += 1 }
            while ($RightIndex -lt $RightPart.Length -and $RightPart[$RightIndex] -eq "0") { $RightIndex += 1 }
            $FirstDifference = 0
            while (
                $LeftIndex -lt $LeftPart.Length -and [char]::IsDigit($LeftPart[$LeftIndex]) -and
                $RightIndex -lt $RightPart.Length -and [char]::IsDigit($RightPart[$RightIndex])
            ) {
                if ($FirstDifference -eq 0) {
                    $FirstDifference = [int][char]$LeftPart[$LeftIndex] - [int][char]$RightPart[$RightIndex]
                }
                $LeftIndex += 1
                $RightIndex += 1
            }
            if ($LeftIndex -lt $LeftPart.Length -and [char]::IsDigit($LeftPart[$LeftIndex])) { return 1 }
            if ($RightIndex -lt $RightPart.Length -and [char]::IsDigit($RightPart[$RightIndex])) { return -1 }
            if ($FirstDifference -gt 0) { return 1 }
            if ($FirstDifference -lt 0) { return -1 }
        }
    }

    return 0
}

<#
.SYNOPSIS
Debian Packages metadataをpackage名で引けるindexへ変換します。
.PARAMETER PackagesUrl
Packages.gzのURLです。
.PARAMETER RepositoryBaseUrl
package fileを取得するrepository rootのURLです。
.PARAMETER TemporaryDirectory
Packages.gzを一時保存するdirectoryです。
.OUTPUTS
package名をkey、metadata hashtableをvalueにしたhashtableを返します。
#>
function Get-DebPackageIndex {
    param(
        [Parameter(Mandatory = $true)][string]$PackagesUrl,
        [Parameter(Mandatory = $true)][string]$RepositoryBaseUrl,
        [Parameter(Mandatory = $true)][string]$TemporaryDirectory
    )

    $Index = @{}
    $Text = Read-GzipTextFromUrl -Url $PackagesUrl -TemporaryDirectory $TemporaryDirectory
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

        if ($Fields.ContainsKey("Package") -and $Fields.ContainsKey("Version")) {
            $Fields["_RepositoryBaseUrl"] = $RepositoryBaseUrl
            $Name = $Fields["Package"]
            if (
                -not $Index.ContainsKey($Name) -or
                (Compare-DebVersion -Left $Fields["Version"] -Right $Index[$Name]["Version"]) -gt 0
            ) {
                $Index[$Name] = $Fields
            }
        }
    }

    return $Index
}

<#
.SYNOPSIS
deb package metadataから依存package名を取り出します。
.PARAMETER Package
Packages metadataの1 package分のhashtableです。
.PARAMETER PackageIndex
package名とvirtual package名をkeyにしたindexです。
.OUTPUTS
依存package名の配列を返します。
#>
function Get-DebDependencyNames {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Package,
        [Parameter(Mandatory = $true)][hashtable]$PackageIndex
    )

    $Dependencies = [System.Collections.Generic.List[string]]::new()
    foreach ($FieldName in @("Pre-Depends", "Depends")) {
        if (-not $Package.ContainsKey($FieldName)) {
            continue
        }

        foreach ($Part in ($Package[$FieldName] -split ",")) {
            $Names = @(
                foreach ($Candidate in ($Part -split "\|")) {
                    ($Candidate `
                        -replace "\s*\(.*?\)", "" `
                        -replace "\s*\[.*?\]", "" `
                        -replace "\s*<.*?>", "" `
                        -replace ":[A-Za-z0-9][A-Za-z0-9-]*", "").Trim()
                }
            )
            $Name = @($Names | Where-Object { $PackageIndex.ContainsKey($_) } | Select-Object -First 1)
            if ($Name.Count -eq 0) {
                $Name = @($Names | Select-Object -First 1)
            }
            $Name = [string]$Name[0]
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
.PARAMETER PackageSources
Packages.gzのURLとrepository root URLを持つsource配列です。
.PARAMETER OutputDirectory
deb fileの保存先directoryです。
.PARAMETER TemporaryDirectory
Packages.gzを一時保存するdirectoryです。
.OUTPUTS
値は返しません。
#>
function Save-DebPackagesWithDependencies {
    param(
        [Parameter(Mandatory = $true)][string[]]$PackageNames,
        [Parameter(Mandatory = $true)][pscustomobject[]]$PackageSources,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][string]$TemporaryDirectory
    )

    if ($PackageNames.Count -eq 0) {
        return
    }

    $PackagesByName = @{}
    foreach ($Source in $PackageSources) {
        $PartialIndex = Get-DebPackageIndex `
            -PackagesUrl $Source.PackagesUrl `
            -RepositoryBaseUrl $Source.BaseUrl `
            -TemporaryDirectory $TemporaryDirectory
        foreach ($Name in $PartialIndex.Keys) {
            if (
                -not $PackagesByName.ContainsKey($Name) -or
                (Compare-DebVersion -Left $PartialIndex[$Name]["Version"] -Right $PackagesByName[$Name]["Version"]) -gt 0
            ) {
                $PackagesByName[$Name] = $PartialIndex[$Name]
            }
        }
    }

    $Index = @{}
    foreach ($Name in $PackagesByName.Keys) {
        $Index[$Name] = $PackagesByName[$Name]
    }
    foreach ($Package in $PackagesByName.Values) {
        if (-not $Package.ContainsKey("Provides")) {
            continue
        }
        foreach ($Provide in ($Package["Provides"] -split ",")) {
            $Name = ($Provide -replace "\s*\(.*?\)", "" -replace ":[A-Za-z0-9][A-Za-z0-9-]*", "").Trim()
            if ($Name -and -not $Index.ContainsKey($Name)) {
                $Index[$Name] = $Package
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
        Save-FileFromUrl `
            -Url (Join-RepositoryUrl -BaseUrl $Package["_RepositoryBaseUrl"] -RelativePath $Package["Filename"]) `
            -OutputPath $OutputPath

        foreach ($Dependency in (Get-DebDependencyNames -Package $Package -PackageIndex $Index)) {
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

$DestinationRoot = Join-Path $OutputRoot "deb"

New-Item `
    -ItemType Directory `
    -Path $DestinationRoot `
    -Force |
    Out-Null

Write-Host "Debian and Ubuntu deb packages:"
Write-Host "  Packages: $($Packages -join ', ')"
Write-Host "  Destination: $DestinationRoot"

foreach ($Registry in $Registries) {
    $DestinationDirectory = Join-Path $DestinationRoot $Registry.DirectoryName
    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    $PackageSources = @(
        foreach ($Source in $Registry.Sources) {
            foreach ($PackagesPath in $Source.PackagePaths) {
                [pscustomobject]@{
                    BaseUrl = $Source.BaseUrl
                    PackagesUrl = Join-RepositoryUrl `
                        -BaseUrl $Source.BaseUrl `
                        -RelativePath $PackagesPath
                }
            }
        }
    )

    Write-Host "  Repository: $($Registry.Name)"
    foreach ($Source in $PackageSources) {
        Write-Host "    $($Source.PackagesUrl)"
    }

    Save-DebPackagesWithDependencies `
        -PackageNames $Packages `
        -PackageSources $PackageSources `
        -OutputDirectory $DestinationDirectory `
        -TemporaryDirectory $OutputRoot

    Assert-AssetFilesExist `
        -Directory $DestinationDirectory `
        -Pattern "*.deb" `
        -Description $Registry.Name
}
