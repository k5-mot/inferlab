<#
.SYNOPSIS
Linux x86_64向けのRPM packageを取得します。

.DESCRIPTION
Rocky Linux 9互換repositoryから、指定したRPM packageと依存packageを取得します。
既定ではBaseOS、AppStream、CRB、EPELを参照し、`/srv/12-registry/rpm/`へ保存します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-RPM.ps1 -OutputDir C:\airgap

指定directoryの`rpm`配下へpackageを依存込みで取得します。

.NOTES
副作用として指定directoryへ`.rpm` fileを作成または上書きします。
実行にはPowerShellと外部repositoryへのHTTP接続が必要です。
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
        "vim-enhanced",
        "ncdu",
        "pkgconf-pkg-config",
        "readline-devel",
        "ncurses-devel",
        "clang-libs"
)
$Registries = @(
        ### Oracle Linux 9
        "https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/",
        "https://yum.oracle.com/repo/OracleLinux/OL9/appstream/x86_64/",
        "https://yum.oracle.com/repo/OracleLinux/OL9/codeready/builder/x86_64/",
        "https://yum.oracle.com/repo/OracleLinux/OL9/developer/EPEL/x86_64/"
        ### Rocky Linux 9
        # "https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/",
        # "https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/",
        # "https://dl.rockylinux.org/pub/rocky/9/CRB/x86_64/os/",
        # "https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/"
        ### RedHat Enterprise Linux 9
        # "https://cdn.redhat.com/content/dist/rhel9/9/x86_64/baseos/os/",
        # "https://cdn.redhat.com/content/dist/rhel9/9/x86_64/appstream/os/",
        # "https://cdn.redhat.com/content/dist/rhel9/9/x86_64/codeready-builder/os/",
        # "https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/"
)
$Architecture = "x86_64"
if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Registries = @(
        "https://download.docker.com/linux/centos/8/x86_64/stable/"
    )
    $Packages = @("docker-scan-plugin")
}

if ($Packages.Count -eq 0) {
    throw "取得するRPM packageが指定されていません。"
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
HTTPでtextを取得します。
.PARAMETER Url
取得元URLです。
.OUTPUTS
取得したtextを返します。
.NOTES
Windows PowerShell 5.1のInvoke-WebRequest進捗表示を避けるためWebClientを使用します。
#>
function Read-TextFromUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url
    )

    $WebClient = [System.Net.WebClient]::new()
    try {
        return $WebClient.DownloadString($Url)
    } finally {
        $WebClient.Dispose()
    }
}

<#
.SYNOPSIS
XML文字列をXmlDocumentとして読み込みます。
.PARAMETER Content
読み込むXML文字列です。
.OUTPUTS
読み込んだXmlDocumentを返します。
.NOTES
repomd.xmlの読み取りに使用します。DTDは無効化します。
#>
function ConvertTo-AssetXmlDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Content
    )

    $Settings = [System.Xml.XmlReaderSettings]::new()
    $Settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $Settings.MaxCharactersInDocument = 1073741824

    $StringReader = [System.IO.StringReader]::new($Content)
    try {
        $XmlReader = [System.Xml.XmlReader]::Create($StringReader, $Settings)
        try {
            $Document = [System.Xml.XmlDocument]::new()
            $Document.Load($XmlReader)
            return $Document
        } finally {
            $XmlReader.Dispose()
        }
    } finally {
        $StringReader.Dispose()
    }
}

<#
.SYNOPSIS
RPM repositoryのrepomd.xmlからprimary metadata URLを取得します。
.PARAMETER RepositoryBaseUrl
RPM repository rootのURLです。
.OUTPUTS
primary.xml.gzのURLを返します。
#>
function Get-RpmPrimaryMetadataUrl {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryBaseUrl
    )

    $RepoMetadata = ConvertTo-AssetXmlDocument -Content (Read-TextFromUrl -Url (Join-RepositoryUrl -BaseUrl $RepositoryBaseUrl -RelativePath "repodata/repomd.xml"))
    $Namespace = [System.Xml.XmlNamespaceManager]::new($RepoMetadata.NameTable)
    $Namespace.AddNamespace("repo", "http://linux.duke.edu/metadata/repo")
    $Location = $RepoMetadata.SelectSingleNode("//repo:data[@type='primary']/repo:location", $Namespace)
    if (-not $Location) {
        throw "primary metadata was not found: $RepositoryBaseUrl"
    }

    $Href = $Location.GetAttribute("href")
    if (-not $Href.EndsWith(".gz")) {
        throw "unsupported RPM primary metadata compression: $Href. Set RPM_REPOSITORY_BASE_URLS to repositories that provide primary.xml.gz."
    }

    return (Join-RepositoryUrl -BaseUrl $RepositoryBaseUrl -RelativePath $Href)
}

<#
.SYNOPSIS
RPM primary metadataのpackage要素をpackage情報へ変換します。
.PARAMETER PackageReader
package要素を指しているXmlReaderです。
.PARAMETER RepositoryBaseUrl
package fileを取得するrepository rootのURLです。
.PARAMETER TargetNames
探索対象のpackage名を保持するhashtableです。
.PARAMETER MatchPackageNameOnly
package名が探索対象外の場合にsubtree読み取りを早期終了します。
.OUTPUTS
package情報のpscustomobjectを返します。
.NOTES
巨大なprimary metadataをDOM化しないよう、package要素のsubtreeだけを読み取ります。
#>
function ConvertFrom-RpmPackageElement {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlReader]$PackageReader,
        [Parameter(Mandatory = $true)][string]$RepositoryBaseUrl,
        [hashtable]$TargetNames,
        [switch]$MatchPackageNameOnly
    )

    $CommonNamespace = "http://linux.duke.edu/metadata/common"
    $RpmNamespace = "http://linux.duke.edu/metadata/rpm"
    $Name = $null
    $Arch = $null
    $Location = $null
    $Requires = [System.Collections.Generic.List[string]]::new()
    $Provides = [System.Collections.Generic.List[string]]::new()
    $RpmSection = $null

    $Subtree = $PackageReader.ReadSubtree()
    try {
        while ($Subtree.Read()) {
            if ($Subtree.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                if ($Subtree.NamespaceURI -eq $CommonNamespace) {
                    if ($Subtree.LocalName -eq "name") {
                        $Name = $Subtree.ReadElementContentAsString()
                        if ($MatchPackageNameOnly -and $TargetNames -and -not $TargetNames.ContainsKey($Name)) {
                            return $null
                        }
                    } elseif ($Subtree.LocalName -eq "arch") {
                        $Arch = $Subtree.ReadElementContentAsString()
                    } elseif ($Subtree.LocalName -eq "location") {
                        $Location = $Subtree.GetAttribute("href")
                    }
                } elseif ($Subtree.NamespaceURI -eq $RpmNamespace) {
                    if ($Subtree.LocalName -eq "requires" -and -not $Subtree.IsEmptyElement) {
                        $RpmSection = "requires"
                    } elseif ($Subtree.LocalName -eq "provides" -and -not $Subtree.IsEmptyElement) {
                        $RpmSection = "provides"
                    } elseif ($Subtree.LocalName -eq "entry") {
                        $EntryName = $Subtree.GetAttribute("name")
                        if ($EntryName -and $RpmSection -eq "requires" -and $EntryName -ne $Name) {
                            $Requires.Add($EntryName)
                        } elseif ($EntryName -and $RpmSection -eq "provides" -and -not $Provides.Contains($EntryName)) {
                            $Provides.Add($EntryName)
                        }
                    }
                }
            } elseif (
                $Subtree.NodeType -eq [System.Xml.XmlNodeType]::EndElement -and
                $Subtree.NamespaceURI -eq $RpmNamespace -and
                ($Subtree.LocalName -eq "requires" -or $Subtree.LocalName -eq "provides")
            ) {
                $RpmSection = $null
            }
        }
    } finally {
        $Subtree.Dispose()
    }

    if (-not $Name -or -not $Arch -or -not $Location) {
        return $null
    }
    if (-not $Provides.Contains($Name)) {
        $Provides.Insert(0, $Name)
    }

    return [pscustomobject]@{
        Name = $Name
        Arch = $Arch
        RepositoryBaseUrl = $RepositoryBaseUrl
        Location = $Location
        Requires = $Requires.ToArray()
        Provides = $Provides.ToArray()
    }
}

<#
.SYNOPSIS
RPM primary metadataから指定capabilityを提供するpackageを探します。
.PARAMETER PrimaryMetadataPath
primary.xml.gzを保存したlocal file pathです。
.PARAMETER RepositoryBaseUrl
package fileを取得するrepository rootのURLです。
.PARAMETER Architecture
取得対象architectureです。
.PARAMETER CapabilityNames
探索するpackage名またはcapability名のhashtableです。
.PARAMETER MatchPackageNameOnly
package名だけを探索対象にします。
.OUTPUTS
capability名をkey、package情報をvalueにしたhashtableを返します。
#>
function Find-RpmPackageMatches {
    param(
        [Parameter(Mandatory = $true)][string]$PrimaryMetadataPath,
        [Parameter(Mandatory = $true)][string]$RepositoryBaseUrl,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][hashtable]$CapabilityNames,
        [switch]$MatchPackageNameOnly
    )

    $MatchesByCapability = @{}
    if ($CapabilityNames.Count -eq 0) {
        return $MatchesByCapability
    }

    $InputStream = [System.IO.File]::OpenRead($PrimaryMetadataPath)
    try {
        $GzipStream = [System.IO.Compression.GzipStream]::new($InputStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $Settings = [System.Xml.XmlReaderSettings]::new()
            $Settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $Settings.MaxCharactersInDocument = 1073741824
            $Reader = [System.Xml.XmlReader]::Create($GzipStream, $Settings)
            try {
                while ($Reader.Read()) {
                    if (
                        $Reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or
                        $Reader.NamespaceURI -ne "http://linux.duke.edu/metadata/common" -or
                        $Reader.LocalName -ne "package" -or
                        $Reader.GetAttribute("type") -ne "rpm"
                    ) {
                        continue
                    }

                    $Package = ConvertFrom-RpmPackageElement `
                        -PackageReader $Reader `
                        -RepositoryBaseUrl $RepositoryBaseUrl `
                        -TargetNames $CapabilityNames `
                        -MatchPackageNameOnly:$MatchPackageNameOnly
                    $Reader.Skip()
                    if (-not $Package) {
                        continue
                    }
                    if ($Package.Arch -ne $Architecture -and $Package.Arch -ne "noarch") {
                        continue
                    }

                    if ($CapabilityNames.ContainsKey($Package.Name) -and -not $MatchesByCapability.ContainsKey($Package.Name)) {
                        $MatchesByCapability[$Package.Name] = $Package
                    }
                    if (-not $MatchPackageNameOnly) {
                        foreach ($Provide in $Package.Provides) {
                            if ($CapabilityNames.ContainsKey($Provide) -and -not $MatchesByCapability.ContainsKey($Provide)) {
                                $MatchesByCapability[$Provide] = $Package
                            }
                        }
                    }

                    if ($MatchesByCapability.Count -ge $CapabilityNames.Count) {
                        break
                    }
                }
            } finally {
                $Reader.Dispose()
            }
        } finally {
            $GzipStream.Dispose()
        }
    } finally {
        $InputStream.Dispose()
    }

    return $MatchesByCapability
}

<#
.SYNOPSIS
RPM require entryを依存解決対象にするか判定します。
.PARAMETER Name
require entryのnameです。
.OUTPUTS
依存解決対象ならtrue、無視する内部capabilityならfalseを返します。
#>
function Test-RpmRequirementName {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Name.StartsWith("rpmlib(") -or $Name.StartsWith("config(") -or $Name.StartsWith("/") -or $Name.StartsWith("rtld(")) {
        return $false
    }

    if ($Name -match '\.so(?:\.|\(|$)') {
        return $false
    }

    if ($Name.Contains("(") -or $Name.Contains(" if ") -or $Name.Contains(" unless ") -or $Name.Contains(" with ") -or $Name.Contains(" without ")) {
        return $false
    }

    return $true
}

<#
.SYNOPSIS
RPM packageと依存packageをHTTP repositoryから取得します。
.PARAMETER PackageNames
取得するroot package名です。
.PARAMETER RepositoryBaseUrls
RPM repository rootのURL配列です。
.PARAMETER Architecture
取得対象architectureです。
.PARAMETER OutputDirectory
rpm fileの保存先directoryです。
.OUTPUTS
値は返しません。
#>
function Save-RpmPackagesWithDependencies {
    param(
        [Parameter(Mandatory = $true)][string[]]$PackageNames,
        [Parameter(Mandatory = $true)][string[]]$RepositoryBaseUrls,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    if ($PackageNames.Count -eq 0) {
        return
    }

    $Repositories = @()
    foreach ($RepositoryBaseUrl in $RepositoryBaseUrls) {
        $PrimaryUrl = Get-RpmPrimaryMetadataUrl -RepositoryBaseUrl $RepositoryBaseUrl
        $PrimaryMetadataFile = New-TemporaryFile
        Save-FileFromUrl -Url $PrimaryUrl -OutputPath $PrimaryMetadataFile.FullName
        $Repositories += [pscustomobject]@{
            BaseUrl = $RepositoryBaseUrl
            PrimaryMetadataPath = $PrimaryMetadataFile.FullName
        }
    }

    $SeenPackages = @{}
    $ResolvedCapabilities = @{}
    $PendingCapabilities = @{}
    foreach ($Name in $PackageNames) {
        $PendingCapabilities[$Name] = $true
    }

    try {
        while ($PendingCapabilities.Count -gt 0) {
            $Batch = @{}
            foreach ($Name in $PendingCapabilities.Keys) {
                if (-not $ResolvedCapabilities.ContainsKey($Name)) {
                    $Batch[$Name] = $true
                    $ResolvedCapabilities[$Name] = $true
                }
            }
            $PendingCapabilities = @{}
            if ($Batch.Count -eq 0) {
                break
            }

            $Matches = @{}
            foreach ($Repository in $Repositories) {
                $RepositoryMatches = Find-RpmPackageMatches `
                    -PrimaryMetadataPath $Repository.PrimaryMetadataPath `
                    -RepositoryBaseUrl $Repository.BaseUrl `
                    -Architecture $Architecture `
                    -CapabilityNames $Batch `
                    -MatchPackageNameOnly
                foreach ($CapabilityName in $RepositoryMatches.Keys) {
                    if (-not $Matches.ContainsKey($CapabilityName)) {
                        $Matches[$CapabilityName] = $RepositoryMatches[$CapabilityName]
                    }
                }
            }

            foreach ($CapabilityName in $Batch.Keys) {
                if (-not $Matches.ContainsKey($CapabilityName)) {
                    Write-Warning "rpm capability not found: $CapabilityName"
                }
            }

            $PackagesToDownload = @{}
            foreach ($Package in $Matches.Values) {
                if (-not $PackagesToDownload.ContainsKey($Package.Name)) {
                    $PackagesToDownload[$Package.Name] = $Package
                }
            }

            foreach ($Package in $PackagesToDownload.Values) {
                if (-not $SeenPackages.ContainsKey($Package.Name)) {
                    $SeenPackages[$Package.Name] = $true
                    $OutputPath = Join-Path $OutputDirectory (Split-Path -Leaf $Package.Location)
                    Save-FileFromUrl -Url (Join-RepositoryUrl -BaseUrl $Package.RepositoryBaseUrl -RelativePath $Package.Location) -OutputPath $OutputPath
                }

                foreach ($Requirement in $Package.Requires) {
                    if (
                        (Test-RpmRequirementName -Name $Requirement) -and
                        -not $SeenPackages.ContainsKey($Requirement) -and
                        -not $ResolvedCapabilities.ContainsKey($Requirement)
                    ) {
                        $PendingCapabilities[$Requirement] = $true
                    }
                }
            }
        }
    } finally {
        foreach ($Repository in $Repositories) {
            Remove-Item -Force $Repository.PrimaryMetadataPath -ErrorAction SilentlyContinue
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

$DestinationDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "rpm"
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null

Write-Host "Download RPM packages: $($Packages -join ', ')"
Save-RpmPackagesWithDependencies `
    -PackageNames $Packages `
    -RepositoryBaseUrls $Registries `
    -Architecture $Architecture `
    -OutputDirectory $DestinationDirectory

Assert-AssetFilesExist -Directory $DestinationDirectory -Pattern "*.rpm" -Description "RPM"
