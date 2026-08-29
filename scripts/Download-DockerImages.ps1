<#
.SYNOPSIS
airgap環境へ持ち込むcontainer image archiveを取得します。

.DESCRIPTION
root stackの全profileで参照されるcontainer imageを指定directoryへ`.tar`として保存します。
registry imageを`crane pull`で取得します。

.PARAMETER OutputDir
READMEで定義した出力treeのbase directoryです。

.PARAMETER Help
scriptのhelpを表示して終了します。

.EXAMPLE
.\scripts\Download-DockerImages.ps1 -OutputDir C:\airgap

root stackに必要なcontainer image archiveを`C:\airgap\docker`へ取得します。

.NOTES
副作用として指定directoryへfileを作成または上書きします。
実行にはPowerShellとcraneが必要です。
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

$OutputDirectory = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "docker"
$Platform = "linux/amd64"
$Overwrite = $true

$Registries = @(
    "docker.elastic.co",
    "docker.io",
    "ghcr.io",
    "gitlab",
    "nginxinc",
    "public.ecr.aws",
    "quay.io"
)
$Packages = @(
    "docker.io/library/postgres:18.6-alpine3.24",
    "docker.io/rustfs/rustfs:1.0.0-beta.12",
    "docker.io/aws-cli/aws-cli:2.36.34",
    "docker.io/valkey/valkey:9.1.1-alpine3.24",
    "docker.io/library/nginx:1.31.4-alpine",
    ### 00-common
    "ghcr.io/gethomepage/homepage:v2.1.2",
    "docker.io/traefik/whoami:v1.12.0",
    ### 01-keycloak
    "quay.io/keycloak/keycloak:26.7.2",
    "docker.io/adorsys/keycloak-config-cli:6.5.1-26"
    ### 02-pubnet
    "docker.io/cloudflare/cloudflared:2026.8.2",
    ### 10-inference
    "docker.io/litellm/litellm:v1.98.0",
    "docker.io/ollama/ollama:0.33.2",
    "ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.3",
    "docker.io/vllm/vllm-openai:v0.28.0-x86_64",
    "docker.io/vllm/vllm-openai-cpu:v0.28.0-x86_64",
    "ghcr.io/remsky/kokoro-fastapi-cpu:v0.8.1",
    # "ghcr.io/remsky/kokoro-fastapi-gpu:v0.8.1",
    "docker.io/nousresearch/hermes-agent:v2026.8.27"
    "ghcr.io/openclaw/openclaw:2026.7.1-2-browser",
    "docker.io/agentscope/qwenpaw:v2.1.0",
    ### 11-rag
    "quay.io/docling-project/docling-serve-cpu:v1.31.0",
    # "quay.io/docling-project/docling-serve:v1.31.0",
    "docker.io/qdrant/qdrant:v1.19.0",
    ### 12-registry
    "docker.io/library/registry:3.1.1",
    "docker.io/pypiserver/pypiserver:v2.4.1",
    "docker.io/verdaccio/verdaccio:6.10.1",
    "ghcr.io/coder/code-marketplace:v2.4.2",
    "docker.io/library/node:24.20.0-alpine3.24",
    "docker.io/openitcockpit/createrepo_c:bullseye-0.17.0",
    # "docker.io/library/nginx:1.31.4-alpine",
    "docker.io/eilandert/reprepro@latest"
    ### 20-owui
    "ghcr.io/open-webui/open-webui:0.11.1",
    "ghcr.io/open-webui/open-terminal:0.12.3",
    "ghcr.io/open-webui/mcpo:main",
    "ghcr.io/searxng/searxng:2026.8.29-d226b78bc",
    "ghcr.io/open-webui/oikb:0.4.0",
    ### 21-dify
    "docker.io/langgenius/dify-api:1.17.0",
    "docker.io/langgenius/dify-web:1.17.0",
    "docker.io/langgenius/dify-plugin-daemon:0.6.10-local",
    "docker.io/langgenius/dify-sandbox:0.2.15",
    "docker.io/langgenius/dify-agent-local-sandbox:1.17.0",
    "docker.io/langgenius/dify-agent-backend:1.17.0",
    # "docker.io/library/postgres:18.6-alpine3.24",
    # "docker.io/rustfs/rustfs:1.0.0-beta.12",
    # "docker.io/aws-cli/aws-cli:2.36.34",
    # "docker.io/valkey/valkey:9.1.1-alpine3.24",
    # "docker.io/qdrant/qdrant:v1.19.0",
    # "docker.io/library/nginx:1.31.4-alpine",
    ### 22-ragflow
    # opensearch,mysql,cpu,rustfs,valkey8→valkey9
    "docker.io/infiniflow/ragflow:v0.27.1",
    "docker.io/opensearchproject/opensearch:2.19.1",
    "docker.io/library/mysql:8.0.39",
    # "docker.io/rustfs/rustfs:1.0.0-beta.12",
    # "docker.io/valkey/valkey:8.1.9-alpine3.24",
    ### 30-nextcloud
    # postgres18-trixie→18-alpine,valkey8→valkey9
    "docker.io/library/nextcloud:34.0.3-apache",
    # "docker.io/library/postgres:18.6-trixie",
    # "docker.io/valkey/valkey:8.1.9-alpine3.24",
    ### 31-xwiki
    # postgres18-trixie→18-alpine
    "docker.io/library/xwiki:18.6.0-postgres-tomcat",
    # "docker.io/library/postgres:18.6-trixie",
    ### 32-kaneo
    # postgres16-alpine→18-alpine
    "ghcr.io/usekaneo/kaneo:2.22.0",
    ### 33-zulip
    # valkey8→valkey9
    "ghcr.io/zulip/zulip-server:12.2-0",
    "docker.io/zulip/zulip-postgresql:14",
    "docker.io/library/memcached:1.6.45-alpine",
    "docker.io/library/rabbitmq:4.3.5",
    # "docker.io/library/redis:8.10.0-alpine",
    ### 34-gitlab
    "docker.io/gitlab/gitlab-ce:19.3.1-ce.0",
    "docker.io/gitlab/gitlab-runner:alpine-v19.3.1",
    ### 40-obsidian
    "docker.io/library/couchdb:3.5.2.1",
    ### 41-llmwiki
    "docker.io/library/node:24.20.0-bookworm-slim",
    ### 42-openkb
    "docker.io/library/python:3.12.14-slim-bookworm",
    ### 50-o11y
    "docker.io/grafana/grafana:13.2.0",
    "docker.io/prom/prometheus:v3.14.0",
    "quay.io/prometheus/node-exporter:v1.12.1",
    "ghcr.io/google/cadvisor:0.60.5",
    "quay.io/prometheus/blackbox-exporter:v0.28.0",
    ### 51-langfuse
    # postgres18-trixie→18-alpine
    "ghcr.io/langfuse/langfuse-worker:4.24.0",
    "ghcr.io/langfuse/langfuse:4.24.0",
    "docker.io/clickhouse/clickhouse-server:26.7.5.10",
    # "docker.io/valkey/valkey:9.1.1-alpine3.24",
    # "docker.io/rustfs/rustfs:1.0.0-beta.12",
    # "docker.io/library/postgres:18.6-trixie",
)

if ($env:INFERLAB_DOWNLOAD_TEST) {
    $Packages = @("docker.io/library/busybox:1.36.1")
}

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

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

foreach ($Image in $Packages) {
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
