$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
相対pathまたは絶対pathを絶対pathへ解決する。
.PARAMETER Path
解決するpath。相対pathの場合はBasePathからの相対pathとして扱う。
.PARAMETER BasePath
相対pathを解決する基準directory。
.OUTPUTS
解決済みの絶対path文字列を返す。
#>
function Resolve-AssetPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $BasePath $Path)
}

<#
.SYNOPSIS
repository URLと相対pathを結合する。
.PARAMETER BaseUrl
repository rootのURL。
.PARAMETER RelativePath
repository rootからの相対path。
.OUTPUTS
結合済みURL文字列を返す。
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
区切り文字つき文字列を空要素なしの配列へ変換する。
.PARAMETER Value
カンマ、セミコロン、改行で区切られた文字列。
.OUTPUTS
trim済み文字列の配列を返す。
#>
function Split-ListValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value
    )

    return @($Value -split "[,;`r`n]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

<#
.SYNOPSIS
script配置場所から既定のregistry資材置場を決定する。
.PARAMETER ScriptDirectory
実行中scriptが置かれているdirectory。
.PARAMETER CurrentDirectory
PowerShellの現在directory。
.OUTPUTS
既定のregistry資材置場pathを返す。
#>
function Get-DefaultAssetsPath {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptDirectory,
        [Parameter(Mandatory = $true)][string]$CurrentDirectory
    )

    $ParentDirectory = Split-Path -Parent $ScriptDirectory
    if ((Split-Path -Leaf $ScriptDirectory) -eq "scripts" -and (Split-Path -Leaf $ParentDirectory) -eq "30-developer") {
        return (Join-Path $ParentDirectory "registry")
    }

    return (Join-Path (Join-Path $CurrentDirectory "30-developer") "registry")
}

<#
.SYNOPSIS
環境変数またはscript配置場所からregistry資材置場を決定する。
.PARAMETER ScriptDirectory
呼び出し元scriptが置かれているdirectory。
.PARAMETER CurrentDirectory
PowerShellの現在directory。
.OUTPUTS
registry資材置場pathを返す。
#>
function Get-AssetsPath {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptDirectory,
        [Parameter(Mandatory = $true)][string]$CurrentDirectory
    )

    if ($env:ASSETS_DIR) {
        return (Resolve-AssetPath -Path $env:ASSETS_DIR -BasePath $CurrentDirectory)
    }

    return (Get-DefaultAssetsPath -ScriptDirectory $ScriptDirectory -CurrentDirectory $CurrentDirectory)
}

<#
.SYNOPSIS
registry資材置場の種類別directoryを作成する。
.PARAMETER AssetsPath
registry資材置場path。
.PARAMETER Names
作成する種類別directory名の配列。
.OUTPUTS
値は返さない。
#>
function New-AssetDirectories {
    param(
        [Parameter(Mandatory = $true)][string]$AssetsPath,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($Name in $Names) {
        New-Item -ItemType Directory -Force -Path (Join-Path $AssetsPath $Name) | Out-Null
    }
}

<#
.SYNOPSIS
directoryにfileが存在することを検証する。
.PARAMETER Directory
検証するdirectory。
.PARAMETER Pattern
対象file pattern配列。
.PARAMETER Description
エラー表示用の資材種別。
.OUTPUTS
値は返さない。
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

<#
.SYNOPSIS
HTTPでfileを取得し、既存fileを置き換える。
.PARAMETER Url
取得元URL。
.PARAMETER OutputPath
保存先file path。
.OUTPUTS
値は返さない。
.NOTES
保存先directoryを作成し、同名fileがある場合は上書きする。
#>
function Save-FileFromUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
    Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing
}

<#
.SYNOPSIS
外部commandを実行し、終了codeを検証する。
.PARAMETER FilePath
実行するcommand名またはpath。
.PARAMETER Arguments
commandへ渡すargument配列。
.OUTPUTS
commandの標準出力を返す。
.NOTES
Windows PowerShellは外部commandの非ゼロ終了で自動停止しないため、この関数で明示的に失敗させる。
#>
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        throw "required command was not found: $FilePath"
    }

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

<#
.SYNOPSIS
利用可能なPython 3 commandを検出する。
.OUTPUTS
FilePathとArgumentsを持つcommand情報を返す。
.NOTES
WindowsのApp Execution AliasはGet-Commandで見えても実行できないことがあるため、--version実行まで確認する。
#>
function Get-PythonCommand {
    $Candidates = @()
    if ($env:PYTHON_COMMAND) {
        $Candidates += [pscustomobject]@{ FilePath = $env:PYTHON_COMMAND; Arguments = @() }
    }
    $Candidates += [pscustomobject]@{ FilePath = "python"; Arguments = @() }
    $Candidates += [pscustomobject]@{ FilePath = "py"; Arguments = @("-3") }
    $Candidates += [pscustomobject]@{ FilePath = "python3"; Arguments = @() }

    foreach ($Candidate in $Candidates) {
        if (-not (Get-Command $Candidate.FilePath -ErrorAction SilentlyContinue)) {
            continue
        }

        & $Candidate.FilePath @(@($Candidate.Arguments) + @("--version")) *> $null
        if ($LASTEXITCODE -eq 0) {
            return $Candidate
        }
    }

    throw "required command was not found: Python 3. Install Python 3, enable the py launcher, or set PYTHON_COMMAND to python.exe."
}

<#
.SYNOPSIS
検出済みPython commandでargumentを実行する。
.PARAMETER Arguments
Python commandへ渡すargument配列。
.OUTPUTS
Python commandの標準出力を返す。
#>
function Invoke-PythonCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $PythonCommand = Get-PythonCommand
    Invoke-NativeCommand -FilePath $PythonCommand.FilePath -Arguments (@($PythonCommand.Arguments) + $Arguments)
}

<#
.SYNOPSIS
Visual Studio MarketplaceからVSIXを取得する。
.PARAMETER ExtensionIds
publisher.extension形式のextension ID配列。
.PARAMETER OutputDirectory
vsix fileの保存先directory。
.OUTPUTS
値は返さない。
#>
function Save-VsixExtensions {
    param(
        [Parameter(Mandatory = $true)][string[]]$ExtensionIds,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    foreach ($ExtensionId in $ExtensionIds) {
        $Parts = $ExtensionId.Split([string[]]@("."), 2, [System.StringSplitOptions]::None)
        if ($Parts.Count -ne 2) {
            throw "invalid VSIX extension id: $ExtensionId"
        }

        $Publisher = [System.Uri]::EscapeDataString($Parts[0])
        $ExtensionName = [System.Uri]::EscapeDataString($Parts[1])
        $Url = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/$Publisher/vsextensions/$ExtensionName/latest/vspackage"
        $OutputPath = Join-Path $OutputDirectory "$ExtensionId.vsix"
        try {
            Save-FileFromUrl -Url $Url -OutputPath $OutputPath
        } catch {
            Write-Warning "VSIX download failed: $ExtensionId ($($_.Exception.Message))"
        }
    }
}

<#
.SYNOPSIS
gzip圧縮されたtext fileをHTTPで取得して展開する。
.PARAMETER Url
gzip fileの取得元URL。
.OUTPUTS
展開済みtextを返す。
.NOTES
一時fileを作成し、読み取り後に削除する。
#>
function Read-GzipTextFromUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url
    )

    $TempFile = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $Url -OutFile $TempFile.FullName -UseBasicParsing
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
Debian Packages metadataをpackage名で引けるindexへ変換する。
.PARAMETER PackagesUrl
Packages.gzのURL。
.OUTPUTS
package名をkey、metadata hashtableをvalueにしたhashtableを返す。
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
deb package metadataから依存package名を取り出す。
.PARAMETER Package
Packages metadataの1 package分のhashtable。
.OUTPUTS
依存package名の配列を返す。
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
deb packageと依存packageをHTTP repositoryから取得する。
.PARAMETER PackageNames
取得するroot package名。
.PARAMETER RepositoryBaseUrl
Debian repository rootのURL。
.PARAMETER PackagesUrl
Packages.gzのURL。
.PARAMETER OutputDirectory
deb fileの保存先directory。
.OUTPUTS
値は返さない。
#>
function Save-DebPackagesWithDependencies {
    param(
        [Parameter(Mandatory = $true)][string[]]$PackageNames,
        [Parameter(Mandatory = $true)][string]$RepositoryBaseUrl,
        [Parameter(Mandatory = $true)][string]$PackagesUrl,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    if ($PackageNames.Count -eq 0) {
        return
    }

    $Index = Get-DebPackageIndex -PackagesUrl $PackagesUrl
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
RPM repositoryのrepomd.xmlからprimary metadata URLを取得する。
.PARAMETER RepositoryBaseUrl
RPM repository rootのURL。
.OUTPUTS
primary.xml.gzのURLを返す。
#>
function Get-RpmPrimaryMetadataUrl {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryBaseUrl
    )

    [xml]$RepoMetadata = (Invoke-WebRequest -Uri (Join-RepositoryUrl -BaseUrl $RepositoryBaseUrl -RelativePath "repodata/repomd.xml") -UseBasicParsing).Content
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
RPM primary metadataをpackage indexとprovide indexへ変換する。
.PARAMETER PrimaryMetadataUrl
primary.xml.gzのURL。
.PARAMETER RepositoryBaseUrl
package fileを取得するrepository rootのURL。
.PARAMETER Architecture
取得対象architecture。
.OUTPUTS
PackagesとProvidersを持つhashtableを返す。
#>
function Get-RpmPackageIndex {
    param(
        [Parameter(Mandatory = $true)][string]$PrimaryMetadataUrl,
        [Parameter(Mandatory = $true)][string]$RepositoryBaseUrl,
        [Parameter(Mandatory = $true)][string]$Architecture
    )

    [xml]$PrimaryMetadata = Read-GzipTextFromUrl -Url $PrimaryMetadataUrl
    $Namespace = [System.Xml.XmlNamespaceManager]::new($PrimaryMetadata.NameTable)
    $Namespace.AddNamespace("common", "http://linux.duke.edu/metadata/common")
    $Namespace.AddNamespace("rpm", "http://linux.duke.edu/metadata/rpm")

    $Packages = @{}
    $Providers = @{}
    foreach ($PackageNode in $PrimaryMetadata.SelectNodes("//common:package[@type='rpm']", $Namespace)) {
        $Arch = $PackageNode.SelectSingleNode("common:arch", $Namespace).InnerText
        if ($Arch -ne $Architecture -and $Arch -ne "noarch") {
            continue
        }

        $Name = $PackageNode.SelectSingleNode("common:name", $Namespace).InnerText
        $Location = $PackageNode.SelectSingleNode("common:location", $Namespace).GetAttribute("href")
        $Requires = [System.Collections.Generic.List[string]]::new()
        foreach ($RequireNode in $PackageNode.SelectNodes("common:format/rpm:requires/rpm:entry", $Namespace)) {
            $RequireName = $RequireNode.GetAttribute("name")
            if ($RequireName -and $RequireName -ne $Name) {
                $Requires.Add($RequireName)
            }
        }

        $Provides = [System.Collections.Generic.List[string]]::new()
        $Provides.Add($Name)
        foreach ($ProvideNode in $PackageNode.SelectNodes("common:format/rpm:provides/rpm:entry", $Namespace)) {
            $ProvideName = $ProvideNode.GetAttribute("name")
            if ($ProvideName -and -not $Provides.Contains($ProvideName)) {
                $Provides.Add($ProvideName)
            }
        }

        $Package = [pscustomobject]@{
            Name = $Name
            Arch = $Arch
            RepositoryBaseUrl = $RepositoryBaseUrl
            Location = $Location
            Requires = $Requires.ToArray()
            Provides = $Provides.ToArray()
        }

        if (-not $Packages.ContainsKey($Name) -or $Packages[$Name].Arch -eq "noarch") {
            $Packages[$Name] = $Package
        }

        foreach ($Provide in $Package.Provides) {
            if (-not $Providers.ContainsKey($Provide)) {
                $Providers[$Provide] = [System.Collections.Generic.List[object]]::new()
            }
            $Providers[$Provide].Add($Package)
        }
    }

    return @{
        Packages = $Packages
        Providers = $Providers
    }
}

<#
.SYNOPSIS
RPM require entryを依存解決対象にするか判定する。
.PARAMETER Name
require entryのname。
.OUTPUTS
依存解決対象ならtrue、無視する内部capabilityならfalseを返す。
#>
function Test-RpmRequirementName {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Name.StartsWith("rpmlib(") -or $Name.StartsWith("config(") -or $Name.StartsWith("/")) {
        return $false
    }

    if ($Name.StartsWith("(") -or $Name.Contains(" if ") -or $Name.Contains(" unless ") -or $Name.Contains(" with ") -or $Name.Contains(" without ")) {
        return $false
    }

    return $true
}

<#
.SYNOPSIS
RPM packageと依存packageをHTTP repositoryから取得する。
.PARAMETER PackageNames
取得するroot package名。
.PARAMETER RepositoryBaseUrls
RPM repository rootのURL配列。
.PARAMETER Architecture
取得対象architecture。
.PARAMETER OutputDirectory
rpm fileの保存先directory。
.OUTPUTS
値は返さない。
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

    $Packages = @{}
    $Providers = @{}
    foreach ($RepositoryBaseUrl in $RepositoryBaseUrls) {
        $PrimaryUrl = Get-RpmPrimaryMetadataUrl -RepositoryBaseUrl $RepositoryBaseUrl
        $Index = Get-RpmPackageIndex -PrimaryMetadataUrl $PrimaryUrl -RepositoryBaseUrl $RepositoryBaseUrl -Architecture $Architecture
        foreach ($PackageName in $Index.Packages.Keys) {
            if (-not $Packages.ContainsKey($PackageName) -or $Packages[$PackageName].Arch -eq "noarch") {
                $Packages[$PackageName] = $Index.Packages[$PackageName]
            }
        }
        foreach ($ProviderName in $Index.Providers.Keys) {
            if (-not $Providers.ContainsKey($ProviderName)) {
                $Providers[$ProviderName] = [System.Collections.Generic.List[object]]::new()
            }
            foreach ($ProviderPackage in $Index.Providers[$ProviderName]) {
                $Providers[$ProviderName].Add($ProviderPackage)
            }
        }
    }

    $Queue = [System.Collections.Queue]::new()
    $SeenPackages = @{}
    foreach ($Name in $PackageNames) {
        $Queue.Enqueue($Name)
    }

    while ($Queue.Count -gt 0) {
        $Name = [string]$Queue.Dequeue()
        $Package = $null

        if ($Packages.ContainsKey($Name)) {
            $Package = $Packages[$Name]
        } elseif ($Providers.ContainsKey($Name)) {
            $Package = @($Providers[$Name] | Where-Object { $_.Arch -eq $Architecture } | Select-Object -First 1)[0]
            if (-not $Package) {
                $Package = @($Providers[$Name] | Select-Object -First 1)[0]
            }
        }

        if (-not $Package) {
            Write-Warning "rpm capability not found: $Name"
            continue
        }

        if ($SeenPackages.ContainsKey($Package.Name)) {
            continue
        }

        $SeenPackages[$Package.Name] = $true
        $OutputPath = Join-Path $OutputDirectory (Split-Path -Leaf $Package.Location)
        Save-FileFromUrl -Url (Join-RepositoryUrl -BaseUrl $Package.RepositoryBaseUrl -RelativePath $Package.Location) -OutputPath $OutputPath

        foreach ($Requirement in $Package.Requires) {
            if ((Test-RpmRequirementName -Name $Requirement) -and -not $SeenPackages.ContainsKey($Requirement)) {
                $Queue.Enqueue($Requirement)
            }
        }
    }
}
