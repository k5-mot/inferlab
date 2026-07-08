$OutputDirectory = Join-Path $PSScriptRoot "..\images"
$Platform = "linux/amd64"

$Images = @(
    "docker.io/apache/tika:3.3.0.0",
    "docker.io/carbone/carbone-ee:full-5.4.5",
    "docker.io/carbone/carbone-mcp:1.1.1",
    "docker.io/clickhouse/clickhouse-server:26.3.3.20",
    "docker.io/cloudflare/cloudflared:2026.6.0",
    "docker.io/gotenberg/gotenberg:8",
    "docker.io/infiniflow/ragflow:v0.25.2",
    "docker.io/langfuse/langfuse:3.167.4",
    "docker.io/langgenius/dify-api:1.14.2",
    "docker.io/langgenius/dify-plugin-daemon:0.6.1-local",
    "docker.io/langgenius/dify-sandbox:0.2.15",
    "docker.io/langgenius/dify-web:1.14.2",
    "docker.io/library/busybox:latest",
    "docker.io/library/couchdb:3.5.2.1",
    "docker.io/library/elasticsearch:8.11.3",
    "docker.io/library/mysql:8.0.39",
    "docker.io/library/nginx:latest",
    "docker.io/library/postgres:15-alpine",
    "docker.io/library/postgres:18.3",
    "docker.io/library/redis:6-alpine",
    "docker.io/library/redis:8.6.2",
    "docker.io/litellm/litellm:v1.83.3-stable",
    "docker.io/litellm/litellm:v1.89.6",
    "docker.io/nousresearch/hermes-agent:v2026.7.7.2",
    "docker.io/ollama/ollama:0.31.1",
    "docker.io/pgsty/minio:RELEASE.2026-03-25T00-00-00Z",
    "docker.io/postgres:18.3",
    "docker.io/qdrant/qdrant:v1.18.2",
    "docker.io/redis:8.6.2",
    "docker.io/searxng/searxng:2026.7.3-80c9806de",
    "docker.io/semitechnologies/weaviate:1.27.0",
    "docker.io/travisvn/openai-edge-tts:latest",
    "docker.io/ubuntu/squid:latest",
    "docker.io/valkey/valkey:8",
    "docker.io/vllm/vllm-openai-cpu:v0.19.1",
    "docker.io/vllm/vllm-openai:v0.19.1",
    "docker.io/voicevox/voicevox_engine:cpu-0.25.2",
    "ghcr.io/asyncfuncai/deepwiki-open:latest",
    "ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.3",
    "ghcr.io/k5-mot/docling-serve-jp:v1.26.0",
    "ghcr.io/open-webui/open-webui:0.10.2",
    "ghcr.io/openclaw/openclaw:2026.4.24",
    "ghcr.io/paperless-ngx/paperless-ngx:2.20.14",
    "ghcr.io/sunwood-ai-labs/voicevox-openai-tts:0.2.0",
    "quay.io/keycloak/keycloak:26.6.4",
    "quay.io/oauth2-proxy/oauth2-proxy:v7.15.2"
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

foreach ($Image in $Images) {
    $ArchiveName = ($Image -replace "[/:@]", "_") + ".tar"
    $ArchivePath = Join-Path $OutputDirectory $ArchiveName

    Write-Host "Downloading $Image"
    crane pull --platform $Platform $Image $ArchivePath

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download $Image"
    }
}
