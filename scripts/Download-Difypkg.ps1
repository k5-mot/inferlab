<#
.SYNOPSIS
Difyのair-gap運用に必要なplugin packageを取得します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-Difypkg.ps1 -OutputDir C:\airgap

指定directoryの`dify`配下へplugin packageを取得します。
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
$Registries = @(
    "https://marketplace.dify.ai"
)
$Packages = @(
    [pscustomobject]@{ Id = "langgenius/openai_api_compatible"; Version = "0.0.64" },
    [pscustomobject]@{ Id = "langgenius/ollama"; Version = "1.0.0" },
    [pscustomobject]@{ Id = "langgenius/huggingface_tei"; Version = "0.1.10" },
    [pscustomobject]@{ Id = "langgenius/cohere"; Version = "0.0.17" },
    [pscustomobject]@{ Id = "langgenius/json_process"; Version = "0.0.7" },
    [pscustomobject]@{ Id = "langgenius/mineru"; Version = "0.5.7" },
    [pscustomobject]@{ Id = "langgenius/firecrawl"; Version = "0.2.2" },
    [pscustomobject]@{ Id = "langgenius/regex"; Version = "0.0.8" },
    [pscustomobject]@{ Id = "langgenius/dify_extractor"; Version = "0.1.0" },
    [pscustomobject]@{ Id = "langgenius/general_chunker"; Version = "0.0.13" },
    [pscustomobject]@{ Id = "langgenius/parentchild_chunker"; Version = "0.0.13" },
    [pscustomobject]@{ Id = "langgenius/comfyui"; Version = "0.3.11" },
    [pscustomobject]@{ Id = "langgenius/searxng"; Version = "0.0.12" },
    [pscustomobject]@{ Id = "langgenius/chart"; Version = "0.0.8" },
    [pscustomobject]@{ Id = "langgenius/qa_chunk"; Version = "0.0.13" },
    [pscustomobject]@{ Id = "langgenius/stablediffusion"; Version = "0.0.7" },
    [pscustomobject]@{ Id = "langgenius/qrcode"; Version = "0.1.6" },
    [pscustomobject]@{ Id = "langgenius/podcast_generator"; Version = "0.0.11" },
    [pscustomobject]@{ Id = "langgenius/gitlab"; Version = "0.0.13" },
    [pscustomobject]@{ Id = "langgenius/devdocs"; Version = "0.0.8" },
    [pscustomobject]@{ Id = "langgenius/unstructured"; Version = "0.0.11" },
    [pscustomobject]@{ Id = "langgenius/oracle_ai_db"; Version = "0.0.8" },
    [pscustomobject]@{ Id = "langgenius/firecrawl_datasource"; Version = "0.2.13" },
    [pscustomobject]@{ Id = "langgenius/gitlab_datasource"; Version = "0.3.12" },
    [pscustomobject]@{ Id = "langgenius/github_datasource"; Version = "0.4.7" },
    [pscustomobject]@{ Id = "langgenius/aws_s3_storage"; Version = "0.3.12" },
    [pscustomobject]@{ Id = "langgenius/brightdata_datasource"; Version = "0.1.10" },
    [pscustomobject]@{ Id = "shenfor/minio_s3_storage"; Version = "0.0.1" },
    [pscustomobject]@{ Id = "langgenius/github_trigger"; Version = "1.5.0" },
    [pscustomobject]@{ Id = "langgenius/rsshub_trigger"; Version = "0.1.0" },
    [pscustomobject]@{ Id = "langgenius/agent"; Version = "0.0.47" },
    [pscustomobject]@{ Id = "langgenius/self_refine_agent"; Version = "0.0.2" },
    [pscustomobject]@{ Id = "langgenius/oaicompat_dify_app"; Version = "0.0.15" },
    [pscustomobject]@{ Id = "langgenius/oaicompat_dify_model"; Version = "0.0.10" }
)

<#
.SYNOPSIS
Marketplace pageから指定versionの一意なpackage識別子を取得します。
.PARAMETER Registry
Dify Marketplaceのbase URLです。
.PARAMETER Package
IdとVersionを持つ取得対象packageです。
.OUTPUTS
Marketplace download APIへ渡す識別子を返します。
.NOTES
指定versionが公開されていない場合は例外を送出します。
#>
function Get-DifyPackageIdentifier {
    param (
        [Parameter(Mandatory = $true)][string]$Registry,
        [Parameter(Mandatory = $true)][pscustomobject]$Package
    )

    $Page = Invoke-WebRequest -Uri "$Registry/plugin/$($Package.Id)"
    $Prefix = "{0}:{1}@" -f $Package.Id, $Package.Version
    $Match = [regex]::Match($Page.Content, [regex]::Escape($Prefix) + "[0-9a-f]{64}")
    if (-not $Match.Success) {
        throw "Dify plugin package identifierが見つかりません: $($Package.Id) $($Package.Version)"
    }
    return $Match.Value
}

<#
.SYNOPSIS
Dify plugin packageをMarketplaceから保存します。
.PARAMETER Registry
Dify Marketplaceのbase URLです。
.PARAMETER Package
IdとVersionを持つ取得対象packageです。
.PARAMETER DestinationDirectory
packageの保存先directoryです。
.OUTPUTS
保存したpackage fileの絶対pathを返します。
.NOTES
保存先fileを作成または上書きします。
#>
function Save-DifyPackage {
    param (
        [Parameter(Mandatory = $true)][string]$Registry,
        [Parameter(Mandatory = $true)][pscustomobject]$Package,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $Identifier = Get-DifyPackageIdentifier -Registry $Registry -Package $Package
    $FileName = "$($Package.Id.Replace('/', '-'))_$($Package.Version).difypkg"
    $Destination = Join-Path $DestinationDirectory $FileName
    Write-Host "Download Dify plugin: $Identifier"
    Invoke-WebRequest -Uri "$Registry/api/v1/plugins/download?unique_identifier=$Identifier" -OutFile $Destination
    return $Destination
}

$DestinationDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "dify"
New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
$Registry = $Registries[0]
foreach ($Package in $Packages) {
    Save-DifyPackage -Registry $Registry -Package $Package -DestinationDirectory $DestinationDirectory | Out-Null
}

$ChecksumLines = Get-ChildItem -LiteralPath $DestinationDirectory -Filter "*.difypkg" -File |
    Sort-Object -Property Name |
    ForEach-Object { "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name }
if ($ChecksumLines.Count -ne $Packages.Count) {
    throw "Dify plugin package数が一致しません: expected=$($Packages.Count) actual=$($ChecksumLines.Count)"
}
$ChecksumLines | Set-Content -LiteralPath (Join-Path $DestinationDirectory "SHA256SUMS") -Encoding ascii
