$OutputDirectory = Join-Path $PSScriptRoot "..\images"
$Platform = "linux/amd64"
$Overwrite = $true

$Images = @(
    "cgr.dev/chainguard/minio:latest",
    "docker.gitea.com/gitea:1.27.0",
    "docker.io/clickhouse/clickhouse-server:25.8.28.1",
    "docker.io/cloudflare/cloudflared:2026.6.0",
    "docker.io/grafana/grafana:13.1.1",
    "docker.io/langfuse/langfuse-worker:3.212.0",
    "docker.io/langfuse/langfuse:3.212.0",
    "docker.io/langgenius/dify-agent-backend:1.16.0-rc1",
    "docker.io/langgenius/dify-agent-local-sandbox:1.16.0-rc1",
    "docker.io/langgenius/dify-api:1.16.0-rc1",
    "docker.io/langgenius/dify-plugin-daemon:0.6.3-local",
    "docker.io/langgenius/dify-sandbox:0.2.15",
    "docker.io/langgenius/dify-web:1.16.0-rc1",
    "docker.io/leantime/leantime:3.9.8",
    "docker.io/library/busybox:latest",
    "docker.io/library/couchdb:3.5.2.1",
    "docker.io/library/mariadb:12.3.2-noble",
    "docker.io/library/memcached:1.6.45-alpine",
    "docker.io/library/mysql:8.4.10",
    "docker.io/library/nextcloud:34.0.1-apache",
    "docker.io/library/nginx:latest",
    "docker.io/library/postgres:15-alpine",
    "docker.io/library/postgres:16",
    "docker.io/library/postgres:18.4-trixie",
    "docker.io/library/rabbitmq:4.2",
    "docker.io/library/redis:8.8.0-alpine",
    "docker.io/library/redis:8.8.0-trixie",
    "docker.io/litellm/litellm:v1.91.0",
    "docker.io/nousresearch/hermes-agent:main",
    "docker.io/ollama/ollama:0.31.1",
    "docker.io/prom/prometheus:v3.13.1",
    "docker.io/qdrant/qdrant:v1.18.2",
    "docker.io/searxng/searxng:2026.7.3-80c9806de",
    "docker.io/ubuntu/squid:latest",
    "docker.io/voicevox/voicevox_engine:cpu-0.25.2",
    "ghcr.io/gethomepage/homepage:v1.13.2",
    "ghcr.io/google/cadvisor:v0.60.5",
    "ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.3",
    "ghcr.io/k5-mot/docling-serve-jp:v1.26.0",
    "ghcr.io/open-webui/oikb:0.3.6",
    "ghcr.io/open-webui/open-terminal:0.11.33",
    "ghcr.io/open-webui/open-webui:0.10.2",
    "ghcr.io/sunwood-ai-labs/voicevox-openai-tts:0.2.0",
    "ghcr.io/zulip/zulip-server:12.1-0",
    "lscr.io/linuxserver/bookstack:26.05.2",
    "lscr.io/linuxserver/mariadb:11.4.12",
    "quay.io/keycloak/keycloak:26.7.0",
    "quay.io/prometheus/blackbox-exporter:v0.28.0",
    "quay.io/prometheus/node-exporter:v1.12.1",
    "zulip/zulip-postgresql:14"
)

<#
.SYNOPSIS
コンテナイメージ参照から保存用アーカイブ名を生成します。

.DESCRIPTION
レジストリ名、リポジトリ名、タグをファイル名へ安全に埋め込むため、区切り文字をアンダースコアへ置換します。

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
