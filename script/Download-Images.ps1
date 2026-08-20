<#
.SYNOPSIS
airgap環境へ持ち込むcontainer image archiveを取得します。

.DESCRIPTION
root stackの全profileで参照されるcontainer imageを指定directoryへ`.tar`として保存します。
registry imageは`crane pull`で取得し、local build imageはDocker CLIでbuildしてから`docker save`で保存します。

.PARAMETER ImageDirectory
container image archiveを保存するdirectoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\script\Download-Images.ps1

root stackに必要なcontainer image archiveを`/srv/oci-archive/`へ取得します。

.EXAMPLE
.\script\Download-Images.ps1 -ImageDirectory .\airgap-images

root stackに必要なcontainer image archiveを`airgap-images/`へ取得します。

.EXAMPLE
.\script\Download-Images.ps1 -Help

scriptの詳細helpを表示します。

.NOTES
副作用として指定directoryへfileを作成または上書きします。
実行にはPowerShell、crane、Docker CLIが必要です。
#>
[CmdletBinding()]
param (
    [string]$ImageDirectory = "/srv/oci-archive",

    [Alias("h")]
    [switch]$Help
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}

$OutputDirectory = $ImageDirectory
$Platform = "linux/amd64"
$Overwrite = $true

$Images = @(
    "docker.io/adorsys/keycloak-config-cli:6.5.1-26",
    "docker.io/agentscope/qwenpaw:v2.1.0",
    "public.ecr.aws/aws-cli/aws-cli:2.36.27",
    "docker.io/clickhouse/clickhouse-server:26.7.4",
    "docker.io/cloudflare/cloudflared:2026.8.2",
    "docker.io/eilandert/reprepro@sha256:96dbd4cdbbb5c26893a7270c8949393211aaa0ec3ff05bf1ebd22da35347e64c",
    "docker.io/grafana/grafana:13.2.0",
    "ghcr.io/langfuse/langfuse-worker:4.15.0",
    "ghcr.io/langfuse/langfuse:4.15.0",
    "docker.io/langgenius/dify-agent-backend:1.16.1",
    "docker.io/langgenius/dify-agent-local-sandbox:1.16.1",
    "docker.io/langgenius/dify-api:1.16.1",
    "docker.io/langgenius/dify-plugin-daemon:0.6.8-local",
    "docker.io/langgenius/dify-sandbox:0.2.15",
    "docker.io/langgenius/dify-web:1.16.1",
    "docker.io/library/busybox:1.38.0",
    "docker.io/library/couchdb:3.5.2.1",
    "docker.io/library/memcached:1.6.45-alpine",
    "docker.io/library/nextcloud:34.0.3-apache",
    "docker.io/library/nginx:1.31.4-alpine",
    "docker.io/library/postgres:15.19-alpine",
    "docker.io/library/postgres:16.15-alpine",
    "docker.io/library/postgres:17.11-alpine",
    "docker.io/library/postgres:18.6-trixie",
    "docker.io/library/rabbitmq:4.2.9",
    "docker.io/library/redis:8.10.0-alpine",
    "docker.io/library/registry:3.1.1",
    "docker.io/litellm/litellm:v1.97.0",
    "docker.io/nousresearch/hermes-agent:v2026.8.18",
    "docker.io/ollama/ollama:0.32.15",
    "docker.io/openitcockpit/createrepo_c:bullseye-0.17.0",
    "docker.io/prom/prometheus:v3.14.0",
    "docker.io/qdrant/qdrant:v1.19.0",
    "docker.io/rustfs/rustfs:1.0.0-beta.12",
    "docker.io/searxng/searxng:2026.8.20-8d3dd0cd4",
    "docker.io/traefik/whoami:v1.12.0",
    "docker.io/ubuntu/squid@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029",
    "docker.io/valkey/valkey:8.1.9-alpine3.24",
    "docker.io/valkey/valkey:9.1.1-alpine3.24",
    "ghcr.io/coder/code-marketplace:v2.4.2",
    "ghcr.io/gethomepage/homepage:v2.0.0",
    "ghcr.io/google/cadvisor:v0.60.5",
    "ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.3",
    "ghcr.io/k5-mot/docling-serve-jp:v1.30.0",
    "ghcr.io/open-webui/mcpo:main@sha256:1e82c9555c19e50b80745705f32b47a2647589f35279527b5118ecd3a71bd467",
    "ghcr.io/open-webui/open-terminal:0.11.35",
    "ghcr.io/open-webui/open-webui:0.11.0",
    "ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.0",
    "ghcr.io/requarks/wiki:2.5.314",
    "ghcr.io/usekaneo/kaneo:2.20.0",
    "ghcr.io/zulip/zulip-server:12.2-0",
    "gitlab/gitlab-ce:19.2.4-ce.0",
    "gitlab/gitlab-runner:alpine-v19.2.2",
    "nginxinc/nginx-unprivileged:1.31.4-alpine",
    "node:22.22.3-alpine",
    "pypiserver/pypiserver:v2.4.1",
    "quay.io/keycloak/keycloak:26.7.2",
    "quay.io/prometheus/blackbox-exporter:v0.28.0",
    "quay.io/prometheus/node-exporter:v1.12.1",
    "verdaccio/verdaccio:6.10.0",
    "zulip/zulip-postgresql:14"
)

$LocalImages = @(
    @{
        Image = "local/llm-wiki-platform:0.1.0"
        Context = Join-Path $PSScriptRoot "..\41-openkb"
        Dockerfile = "Dockerfile"
    },
    @{
        Image = "local/oikb:0.4.0"
        Context = Join-Path $PSScriptRoot "..\20-owui\oikb"
        Dockerfile = "Containerfile"
    },
    @{
        Image = "local/openclaw:2026.7.1-2-browser"
        Context = Join-Path $PSScriptRoot "..\10-inference\openclaw\custom-image"
        Dockerfile = "Dockerfile"
    },
    @{
        Image = "local/openkb:0.5.0rc1"
        Context = Join-Path $PSScriptRoot "..\41-openkb"
        Dockerfile = "Dockerfile.openkb"
    }
)

<#
.SYNOPSIS
コンテナイメージ参照から保存用アーカイブ名を生成します。

.DESCRIPTION
レジストリ名、リポジトリ名、タグ、digestをファイル名へ安全に埋め込むため、区切り文字をアンダースコアへ置換します。

.PARAMETER Image
変換対象のコンテナイメージ参照です。

.OUTPUTS
生成した .tar ファイル名を文字列として返します。

.NOTES
副作用はありません。
#>
function Get-ImageArchiveName {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Image
    )

    return ($Image -replace "[/:@]", "_") + ".tar"
}

if (-not (Get-Command crane -ErrorAction SilentlyContinue)) {
    throw "crane が見つかりません。https://github.com/google/go-containerregistry を参照して crane をインストールしてください。"
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker が見つかりません。local build imageを保存するため、Docker CLIをインストールしてください。"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

foreach ($Image in $Images) {
    $ArchivePath = Join-Path $OutputDirectory (Get-ImageArchiveName -Image $Image)

    if ((Test-Path $ArchivePath) -and -not $Overwrite) {
        Write-Host "Skip $Image"
        continue
    }

    Write-Host "Download $Image"
    crane pull --platform $Platform $Image $ArchivePath

    if ($LASTEXITCODE -ne 0) {
        throw "ダウンロードに失敗しました: $Image"
    }
}

foreach ($LocalImage in $LocalImages) {
    $Image = $LocalImage["Image"]
    $Context = $LocalImage["Context"]
    $DockerfileName = $LocalImage["Dockerfile"]
    $Dockerfile = Join-Path $Context $DockerfileName
    $ArchivePath = Join-Path $OutputDirectory (Get-ImageArchiveName -Image $Image)

    if ((Test-Path $ArchivePath) -and -not $Overwrite) {
        Write-Host "Skip $Image"
        continue
    }

    Write-Host "Build $Image"
    docker build --platform $Platform -t $Image -f $Dockerfile $Context

    if ($LASTEXITCODE -ne 0) {
        throw "ビルドに失敗しました: $Image"
    }

    Write-Host "Save $Image"
    docker save -o $ArchivePath $Image

    if ($LASTEXITCODE -ne 0) {
        throw "保存に失敗しました: $Image"
    }
}
