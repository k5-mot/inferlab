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

root stackに必要なcontainer image archiveを`images/`へ取得します。

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
    [string]$ImageDirectory = (Join-Path (Get-Location).Path "images"),

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
    "alpine:3.24.1",
    "docker.io/amazon/aws-cli:2.36.14",
    "docker.io/clickhouse/clickhouse-server:25.8.28.1",
    "docker.io/cloudflare/cloudflared:2026.7.3",
    "docker.io/eilandert/reprepro@sha256:7e448608d5ff4d22e6ddf2ddcdc2102f2f8abefa59c4324a6dc345881b1a586f",
    "docker.io/grafana/grafana:13.1.1",
    "docker.io/gitlab/gitlab-ce:19.2.1-ce.0",
    "docker.io/gitlab/gitlab-runner:alpine-v19.2.1",
    "docker.io/langfuse/langfuse-worker:4.1.0",
    "docker.io/langfuse/langfuse:4.1.0",
    "docker.io/langgenius/dify-agent-backend:1.16.1",
    "docker.io/langgenius/dify-agent-local-sandbox:1.16.1",
    "docker.io/langgenius/dify-api:1.16.1",
    "docker.io/langgenius/dify-plugin-daemon:0.6.8-local",
    "docker.io/langgenius/dify-sandbox:0.2.15",
    "docker.io/langgenius/dify-web:1.16.1",
    "docker.io/leantime/leantime:3.9.8",
    "docker.io/library/busybox:1.38.0",
    "docker.io/library/couchdb:3.5.2.1",
    "docker.io/library/memcached:1.6.45-alpine",
    "docker.io/library/mysql:8.4.10",
    "docker.io/library/nextcloud:34.0.2-apache",
    "docker.io/library/nginx:1.31.3-alpine",
    "docker.io/library/postgres:15-alpine",
    "docker.io/library/postgres:16-alpine",
    "docker.io/library/postgres:18.4-trixie",
    "docker.io/library/rabbitmq:4.2",
    "docker.io/library/redis:8.8.0-alpine",
    "docker.io/library/registry:3.1.1",
    "docker.io/litellm/litellm:v1.94.1",
    "docker.io/ollama/ollama:0.32.5",
    "docker.io/openitcockpit/createrepo_c:bullseye-0.17.0",
    "docker.io/prom/prometheus:v3.13.2",
    "docker.io/qdrant/qdrant:v1.18.3",
    "docker.io/rustfs/rustfs:1.0.0-beta.12",
    "docker.io/searxng/searxng:2026.7.3-80c9806de",
    "docker.io/traefik/whoami:v1.11",
    "docker.io/ubuntu/squid@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029",
    "docker.io/valkey/valkey:8.1.9-alpine3.24",
    "ghcr.io/coder/code-marketplace:v2.4.2",
    "ghcr.io/gethomepage/homepage:v1.13.2",
    "ghcr.io/google/cadvisor:v0.60.5",
    "ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.3",
    "ghcr.io/k5-mot/docling-serve-jp:v1.26.0",
    "ghcr.io/open-webui/mcpo:main",
    "ghcr.io/open-webui/open-terminal:0.11.33",
    "ghcr.io/open-webui/open-webui:0.11.0",
    "ghcr.io/remsky/kokoro-fastapi-cpu:v0.7.0",
    "ghcr.io/usekaneo/kaneo:2.12.1",
    "ghcr.io/zulip/zulip-server:12.1-0",
    "lscr.io/linuxserver/bookstack:26.05.2",
    "lscr.io/linuxserver/mariadb:11.4.12",
    "nginxinc/nginx-unprivileged:1.31.3-alpine",
    "node:22-alpine",
    "pypiserver/pypiserver:v2.4.1",
    "quay.io/keycloak/keycloak:26.7.0",
    "quay.io/prometheus/blackbox-exporter:v0.28.0",
    "quay.io/prometheus/node-exporter:v1.12.1",
    "verdaccio/verdaccio:6.9.0",
    "zulip/zulip-postgresql:14"
)

$LocalImages = @(
    @{
        Image = "inferlab-oikb"
        Context = Join-Path $PSScriptRoot "..\20-owui\oikb"
        Dockerfile = "Containerfile"
    },
    @{
        Image = "inferlab/hermes-agent:v2026.7.30-uid"
        Context = Join-Path $PSScriptRoot "..\10-inference\hermes-agent-custom-image"
        Dockerfile = "Dockerfile"
    },
    @{
        Image = "inferlab/openclaw:2026.7.1-browser"
        Context = Join-Path $PSScriptRoot "..\10-inference\openclaw\custom-image"
        Dockerfile = "Dockerfile"
    },
    @{
        Image = "inferlab/llm-wiki:v0.5.5"
        Context = Join-Path $PSScriptRoot "..\41-knowledge\llm-wiki"
        Dockerfile = "Dockerfile"
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
