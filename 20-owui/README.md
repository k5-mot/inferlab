# 20-owui

Open WebUI、Open Terminal、mcpo、SearXNG、OIKB、OIKB用RustFSをまとめたUI/Knowledge stack。

## 起動時初期化

このstackには次の初期化処理がある。

| 対象 | 初期化内容 |
| --- | --- |
| `open-webui` | `open-webui/entrypoint_patch.sh`でDocling向けJSON設定をmultipart form用の文字列へ変換してからOpen WebUIを起動する。 |
| `mcpo` | Docker socket経由でllmwiki containerのstdio MCPを起動し、OpenAPIとしてOpen WebUIへ公開する。 |
| `oikb-rustfs-init` | Compose内のinit commandでRustFSがhealthyになった後、`oikb-bucket`が無ければ作成する。 |
| `oikb` | Nextcloud volumeとRustFS bucketをsourceとしてOpen WebUI Knowledgeへ同期する。 |

Open WebUIのKeycloak連携は、`OAUTH_CLIENT_SECRET`とKeycloak側`open-webui` client secretの一致が前提になる。

llmwiki連携では、`mcpo`がDocker socketへアクセスして`${STACK_NAME}-llmwiki`内でMCPプロセスを起動する。Docker socketへアクセスできるcontainerはホスト上のDockerを操作できるため、信頼できる設定とイメージだけを使用すること。

## 起動

### Open WebUI stackのみを起動

```bash
# Open WebUI stackを起動する。
sudo docker compose --env-file .env --profile owui up -d
```

期待結果:

- `searxng`、`open-terminal`、`mcpo`がhealthyになる。
- `open-webui`が`http://${PUBLIC_HOST}:32000`で応答する。
- `oikb-rustfs-init`が正常終了する。
- `oikb`が`http://${PUBLIC_HOST}:32001`で応答する。

失敗条件:

- `open-webui/entrypoint_patch.sh`がDocling設定を生成できない。
- RustFS bucket作成が認証エラーになる。
- `OPEN_WEBUI_API_KEY`またはKnowledge IDが未設定のためOIKB同期が失敗する。

### llmwiki連携を含めて起動

llmwikiのtoolをOpen WebUIから使用する場合は、llmwiki profileも同時に起動する。

```bash
# Open WebUIとllmwikiを起動し、mcpo経由のMCP接続を有効にする。
sudo docker compose --env-file .env --profile owui --profile llmwiki up -d
```

期待結果:

- `mcpo`の`/llmwiki/openapi.json`がllmwikiのtool定義を返す。
- Open WebUIのtool server一覧で`llmwiki`接続が有効になる。

失敗条件:

- `${STACK_NAME}-llmwiki`が起動しておらず、mcpoがMCPプロセスを開始できない。
- Docker socketへのアクセスが拒否される。
- llmwikiに必要なLiteLLMまたはembeddingの認証情報が不足している。

## 確認手順

```bash
# owui profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile owui ps

# Open WebUIのhealth endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32000/health" >/dev/null

# OIKBのhealth endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32001/health" >/dev/null

# mcpoが公開するllmwikiのOpenAPI定義を確認する。
curl -fsS -H "Authorization: Bearer ${MCPO_API_KEY:-sk-mcpo-api-secret-key}" \
  "http://${PUBLIC_HOST:-localhost}:32004/llmwiki/openapi.json" >/dev/null
```

期待結果:

- `open-webui`と`oikb`がhealthyになる。
- `oikb-rustfs-init`が`exited (0)`になる。
- RustFS上に`oikb-bucket`が存在する。
- llmwikiのOpenAPI定義を取得できる。

失敗条件:

- `oikb-rustfs-init`が繰り返し失敗する。
- Open WebUIのOAuth loginがKeycloak client secret不一致で失敗する。
- OIKBがNextcloudまたはRustFS sourceを読み取れない。
- mcpoからllmwikiのMCPプロセスを起動できない。

## 再初期化

OIKB用RustFS bucketを作り直す場合は、OIKB用RustFS volumeを削除する。

```bash
# owui stackを停止する。
sudo docker compose --env-file .env --profile owui down

# OIKB用RustFSの永続volumeを削除する。
sudo docker volume rm "${STACK_NAME}_oikb-rustfs-data"

# owui stackを再作成し、bucket作成を再実行する。
sudo docker compose --env-file .env --profile owui up -d
```

期待結果:

- RustFS data volumeが再作成される。
- `oikb-rustfs-init`が`oikb-bucket`を再作成する。

失敗条件:

- volumeが使用中で削除できない。
- OIKBが既存Knowledge IDの対象sourceと不整合になる。
