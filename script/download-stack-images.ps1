$OutputDirectory = Join-Path $PSScriptRoot "..\images"
$Platform = "linux/amd64"
$Overwrite = $true

$Images = @(
    "docker.io/litellm/litellm:1.92.0",
    "docker.io/ollama/ollama:0.31.2",
    "ghcr.io/huggingface/text-embeddings-inference:1.9.3",
    "ghcr.io/open-webui/open-webui:0.10.2-slim",
    "ghcr.io/k5-mot/docling-serve-jp:v1.26.0",
    "docker.io/searxng/searxng:2026.7.11-62a1ab7ed",
    "docker.io/voicevox/voicevox_engine:cpu-0.25.2",
    "ghcr.io/sunwood-ai-labs/voicevox-openai-tts:0.2.0",
    "docker.io/qdrant/qdrant:v1.18.2",
    "ghcr.io/open-webui/computer:0.9.4",
    "quay.io/keycloak/keycloak:26.7.0",
    "docker.io/library/postgres:18.4-trixie",
    "ghcr.io/gethomepage/homepage:v1.13.2",
    "docker.io/cloudflare/cloudflared:2026.7.1",
    "docker.io/library/couchdb:3.5.2.1",
    "docker.io/library/nextcloud:34.0.1-apache",
    "docker.io/library/mariadb:12.3.2-noble",
    "docker.io/library/redis:8.8.0-trixie",
    "ghcr.io/open-webui/oikb:0.3.6",
    "docker.io/nousresearch/hermes-agent:v2026.7.7.2",
    "docker.io/langfuse/langfuse-worker:3.212.0",
    "docker.io/langfuse/langfuse:3.212.0",
    "docker.io/clickhouse/clickhouse-server:25.8.28.1",
    "cgr.dev/chainguard/minio:0.20260604"
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
