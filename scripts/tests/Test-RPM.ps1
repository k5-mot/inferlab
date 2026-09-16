. (Join-Path $PSScriptRoot "Invoke-DownloadTest.ps1")

$OutputDir = New-DownloadTestDirectory -Name "rpm"
$RepositoryDirectory = Join-Path $OutputDir "repository"
$PackageDirectory = Join-Path $RepositoryDirectory "packages"
$RepodataDirectory = Join-Path $RepositoryDirectory "repodata"
$PreviousRepositoryBaseUrls = $env:RPM_REPOSITORY_BASE_URLS
try {
    New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $RepodataDirectory -Force | Out-Null

    $Packages = @(
        [pscustomobject]@{ Name = "podman"; Epoch = "2"; Version = "4.0.2"; Release = "1.el9"; Requires = @("iptables", "oci-runtime", "glibc-langpack") },
        [pscustomobject]@{ Name = "podman"; Epoch = "6"; Version = "5.8.2"; Release = "2.el9"; Requires = @("iptables", "oci-runtime", "glibc-langpack") },
        [pscustomobject]@{ Name = "iptables-nft"; Epoch = "0"; Version = "1.8.7"; Release = "1.el9"; Provides = @("iptables") },
        [pscustomobject]@{ Name = "iptables-nft"; Epoch = "0"; Version = "1.8.10"; Release = "1.el9"; Provides = @("iptables") },
        [pscustomobject]@{ Name = "crun"; Epoch = "0"; Version = "1.14"; Release = "1.el9"; Provides = @("oci-runtime") },
        [pscustomobject]@{ Name = "crun"; Epoch = "0"; Version = "1.20"; Release = "1.el9"; Provides = @("oci-runtime") },
        [pscustomobject]@{ Name = "glibc-langpack-en"; Epoch = "0"; Version = "2.34~rc1"; Release = "1.el9"; Provides = @("glibc-langpack") },
        [pscustomobject]@{ Name = "glibc-langpack-en"; Epoch = "0"; Version = "2.34"; Release = "1.el9"; Provides = @("glibc-langpack") }
    )
    $PackageXml = foreach ($Package in $Packages) {
        $FileName = "$($Package.Name)-$($Package.Version)-$($Package.Release).x86_64.rpm"
        Set-Content -LiteralPath (Join-Path $PackageDirectory $FileName) -Value $FileName -Encoding ascii
        $ProvideEntries = @($Package.Name) + @($Package.Provides) |
            ForEach-Object { "<rpm:entry name=`"$_`"/>" }
        $RequireEntries = @($Package.Requires) |
            ForEach-Object { "<rpm:entry name=`"$_`"/>" }
        @"
<package type="rpm">
  <name>$($Package.Name)</name>
  <arch>x86_64</arch>
  <version epoch="$($Package.Epoch)" ver="$($Package.Version)" rel="$($Package.Release)"/>
  <location href="packages/$FileName"/>
  <format>
    <rpm:provides>$($ProvideEntries -join "")</rpm:provides>
    <rpm:requires>$($RequireEntries -join "")</rpm:requires>
  </format>
</package>
"@
    }
    $PrimaryXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<metadata xmlns="http://linux.duke.edu/metadata/common" xmlns:rpm="http://linux.duke.edu/metadata/rpm" packages="$($Packages.Count)">
$($PackageXml -join "")
</metadata>
"@
    $PrimaryPath = Join-Path $RepodataDirectory "primary.xml.gz"
    $PrimaryFile = [System.IO.File]::Create($PrimaryPath)
    try {
        $GzipStream = [System.IO.Compression.GzipStream]::new($PrimaryFile, [System.IO.Compression.CompressionMode]::Compress)
        try {
            $Writer = [System.IO.StreamWriter]::new($GzipStream, [System.Text.UTF8Encoding]::new($false))
            try {
                $Writer.Write($PrimaryXml)
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
        $PrimaryFile.Dispose()
    }
    @"
<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo">
  <data type="primary"><location href="repodata/primary.xml.gz"/></data>
</repomd>
"@ | Set-Content -LiteralPath (Join-Path $RepodataDirectory "repomd.xml") -Encoding utf8

    $env:RPM_REPOSITORY_BASE_URLS = ([System.Uri]::new($RepositoryDirectory.TrimEnd("\") + "\")).AbsoluteUri
    Invoke-DownloadTestScript -ScriptName "Download-RPM.ps1" -OutputDir $OutputDir
    $RpmDirectory = Join-Path $OutputDir "rpm/oracle-linux-9"
    foreach ($Pattern in @(
        "podman-5.8.2-2.el9.x86_64.rpm",
        "iptables-nft-1.8.10-1.el9.x86_64.rpm",
        "crun-1.20-1.el9.x86_64.rpm",
        "glibc-langpack-en-2.34-1.el9.x86_64.rpm"
    )) {
        Assert-DownloadTestArtifacts -Directory $RpmDirectory -Pattern $Pattern
    }
    foreach ($Pattern in @("podman-4.0.2-*.rpm", "iptables-nft-1.8.7-*.rpm", "crun-1.14-*.rpm", "glibc-langpack-en-*rc*.rpm")) {
        if (Get-ChildItem -Path $RpmDirectory -Filter $Pattern -File -ErrorAction SilentlyContinue) {
            throw "Download-RPM.ps1が旧versionのRPMを取得しました: $Pattern"
        }
    }
}
finally {
    $env:RPM_REPOSITORY_BASE_URLS = $PreviousRepositoryBaseUrls
    Remove-DownloadTestDirectory -Path $OutputDir
}
