# 20-owui

Open WebUI、Open Terminal、mcpo、SearXNG、OIKB、OIKB用RustFSをまとめたUI/Knowledge stack。

## 起動時初期化

このstackには次の初期化処理がある。

| 対象 | 初期化内容 |
| --- | --- |
| `open-webui` | `open-webui/entrypoint_patch.sh`でDocling向けJSON設定をmultipart form用へ変換し、大容量PDFの分割patchを適用してからOpen WebUIを起動する。 |
| `mcpo` | 設定済みのMCP serverをOpenAPIとしてOpen WebUIへ公開する。 |
| `oikb-rustfs-init` | Compose内のinit commandでRustFSがhealthyになった後、`oikb-bucket`が無ければ作成する。 |
| `oikb` | APIとsource状態を公開し、内蔵schedulerが設定順にsourceを定時同期する。 |

Open WebUIのKeycloak連携は、`OAUTH_CLIENT_SECRET`とKeycloak側`open-webui` client secretの一致が前提になる。

LibreTranslate連携では、`TOOL_SERVER_CONNECTIONS`へ`http://libretranslate:5000/translate`の最小OpenAPI 3仕様を登録する。`owui` profileを起動するとLibreTranslateも起動し、Open WebUIのtool一覧から翻訳APIを利用できる。APIの直接利用方法は[`13-translate/README.md`](../13-translate/README.md)を参照する。

## Docling向けPDF分割

Open WebUIは、`DOCLING_PDF_BATCH_PAGES`を超えるPDFを一時PDFへ分割し、Doclingへ1件ずつ送信する。既定値は100ページで、`0`を指定すると分割を無効化する。Open WebUIとOIKBでは元PDFを1つのfileとして維持し、分割fileはDoclingへのrequestにだけ使用する。

Open WebUIのlogには、各分割の元file名とページ範囲を`Docling PDF batch`として記録する。明示的な`page_range`をDocling parameterへ設定した場合は、その指定を優先して自動分割しない。

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
- OIKB imageのbuildまたはAPI起動に失敗する。

## 確認手順

```bash
# owui profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile owui ps

# Open WebUIのhealth endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32000/health" >/dev/null

# OIKBのhealth endpointを確認する。
curl -fsS "http://${PUBLIC_HOST:-localhost}:32001/health" >/dev/null

# mcpoのOpenAPI定義を確認する。
curl -fsS -H "Authorization: Bearer ${MCPO_API_KEY:-sk-mcpo-api-secret-key}" \
  "http://${PUBLIC_HOST:-localhost}:32004/openapi.json" >/dev/null
```

期待結果:

- `open-webui`と`oikb`がhealthyになる。
- `oikb-rustfs-init`が`exited (0)`になる。
- RustFS上に`oikb-bucket`が存在する。
- mcpoのOpenAPI定義を取得できる。

失敗条件:

- `oikb-rustfs-init`が繰り返し失敗する。
- Open WebUIのOAuth loginがKeycloak client secret不一致で失敗する。
- OIKBがNextcloudまたはRustFS sourceを読み取れない。

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

## Knowledge Baseの定期保守

3つの保守scriptの設定、実行方法、期待結果、失敗条件は、[`scripts/oikb/README.md`](../scripts/oikb/README.md)を参照する。

## Open WebUI Agent SkillsとPi

Open WebUIを業務機能の提供基盤 (Capability Provider) とし、Open Terminal上の[Pi coding agent](https://github.com/earendil-works/pi)が、userごとのAPI keyでOpen WebUIのREST APIをAgent Skills経由で利用する。PiにはKnowledge、Memory、Notesなどのdatabaseを持たせない。設計の背景は[`NEXT.md`](../NEXT.md)を参照する。

### 構成

| file | 役割 |
| --- | --- |
| `open-terminal/Dockerfile` | Pi、[OfficeCLI](https://github.com/iOfficeAI/OfficeCLI)、OfficeCLIのWord/PowerPoint/Excel skill、`skills/`を導入する派生image。build contextは`20-owui`。 |
| `open-terminal/pi/models.json` | PiのLiteLLM provider定義。API keyは`/run/secrets/pi-litellm-api-key`から読む。 |
| `open-terminal/pi/settings.json` | 既定model (`google/gemma4:12b`) とtelemetry無効化。 |
| `open-terminal/pi/AGENTS.md` | Pi全体の指示。Open WebUI連携の規則とOffice生成の短縮手順を持つ。 |
| `open-terminal/pi/inferlab-pi.sh` | Pi起動前に、管理設定とskillをOpen WebUI userごとの`~/.pi/agent`へ同期する。 |
| `skills/open-webui/` | 共通skill。規則、認証、API index、共通client `owui-api`。 |
| `skills/owui-*/` | 機能別skill。`references/api.md`はOpenAPI Schemaから生成する。 |
| `../scripts/owui-skills/` | Schemaの保存先とreference生成script。 |

skillはPi専用の記法を使わない[Agent Skills](https://agentskills.io/specification)形式のため、他のagent harnessへも配布できる。

### 権限境界

| 制御 | 実装 |
| --- | --- |
| userの識別 | Open Terminalのmulti-user modeが、Open WebUI userごとに別OS userでPiを起動する。homeはmode `2770`で、他userからは読めない。 |
| API認証 | 各userが自分のAPI keyを発行し、`owui-api login`で自分のhome (`~/.config/open-webui/api-key`、mode `600`) へ保存する。共通管理者keyは使わない。 |
| データ権限 | Open WebUIのACL。共有されていないKnowledge、Notes、chatは取得できない。 |
| 到達できるAPI | `ENABLE_API_KEYS_ENDPOINT_RESTRICTIONS`と`API_KEYS_ALLOWED_ENDPOINTS`。全API key共通のprefix allowlistで、Hermes、OIKB、skillが使うものだけを含める。 |
| 再帰防止 | chat completions、Anthropic互換messages、terminals、automationsをallowlistから除外する。PiがOpen WebUI経由で自分自身を起動できない。 |
| host権限 | `open-terminal`へ`/var/run/docker.sock`をmountしない。mountすると新規OS userがdocker groupへ自動追加される。 |
| 破壊的操作 | `owui-api`はDELETE、`*/delete`、`*/reset`を`OWUI_CONFIRM=yes`なしで拒否する。これはagentへの指示であり、権限境界ではない。 |

multi-user modeのOS user分離は、上流の説明どおりuser間のsecurity boundaryではない。全userへterminalを開放する前に、container単位の分離を検討する。

Open Terminalの接続 (`TERMINAL_SERVER_CONNECTIONS`) は`access_grants: []`のため、管理者だけが利用できる。一般userへPiを提供する場合は、Open WebUIの管理画面でterminal接続のaccessへ対象userまたはgroupを追加する。

### 導入

```bash
# 派生imageをbuildし、Open WebUIとOpen Terminalを再作成する。
sudo docker compose --env-file .env --profile owui up -d --build --force-recreate open-webui open-terminal
```

期待結果:

- `open-webui`と`open-terminal`が`healthy`になる。
- terminal接続を許可されたuserが、Open WebUIのmodel選択で`pi/inferlab/...`を選べる。
- `open-terminal`のmountに`/var/run/docker.sock`が含まれない。

失敗条件:

- build時にnpm registryまたはOfficeCLIのrelease binaryへ到達できない。
- Piの一覧に`Agent discovery failed`が表示される。

### userごとの初期設定

各userは、Open WebUIの設定 > アカウント > APIキーでkeyを発行し、Open WebUIのterminalで次を実行する。

```bash
# API keyを入力し、自分のhomeへ保存して有効性を確認する。
owui-api login
```

期待結果:

- `~/.config/open-webui/api-key`がmode `600`で作成され、`API keyを...へ保存しました。`と表示される。

失敗条件:

- `features.api_keys`権限が無く、key発行またはAPI呼び出しが403になる。

### API referenceの更新

Open WebUIを更新したときは、検証用containerからSchemaを取得し、referenceを再生成して差分を確認する。本番Open WebUIで`ENV=dev`を有効化しない。

```bash
# 検証用Open WebUIを開発modeで起動する。
docker run -d --name owui-schema -e ENV=dev -e WEBUI_SECRET_KEY=schema-only ghcr.io/open-webui/open-webui:v0.13.4

# OpenAPI Schemaを取得し、検証用containerを削除する。
docker exec owui-schema curl -fsS http://127.0.0.1:8080/openapi.json > /tmp/openapi.json && docker rm -f owui-schema

# 整形して保存し、skillのreferenceとAPI indexを再生成する。
python3 -c "import json,sys;json.dump(json.load(open('/tmp/openapi.json')),open('scripts/owui-skills/openapi/open-webui-v0.13.4.json','w'),indent=1,sort_keys=True,ensure_ascii=False)"
python3 scripts/owui-skills/generate_api_reference.py scripts/owui-skills/openapi/open-webui-v0.13.4.json --version v0.13.4
```

期待結果:

- `20-owui/skills/owui-*/references/api.md`と`20-owui/skills/open-webui/references/api-index.md`が更新される。
- `api-index.md`の未分類operationに、新しくskill化すべきAPIが無い。

失敗条件:

- Schema取得がtimeoutする。起動完了まで待ってから再実行する。
- 新しいrouterがallowlistとskillの両方に無い。`generate_api_reference.py`の`SKILLS`または`EXCLUDED`と`API_KEYS_ALLOWED_ENDPOINTS`を同時に更新する。

### 検証結果

2026-11-25に、一般user 2名 (A、B) とAだけが読める検証用Knowledgeを作り、次を確認した。terminal接続の`access_grants`は検証中だけuser Aへ付与した。

| 確認内容 | 結果 |
| --- | --- |
| user AがOpen WebUIのmodel一覧で`pi/inferlab/...`を選べる | 成功 |
| `owui-api login`でkeyがuserのhomeへmode `600`で保存され、入力がterminalへ表示されない | 成功 |
| `open-terminal`再作成後もkey、Pi session、成果物が残る | 成功 |
| user Bがuser Aのhomeを読めない | 成功 (`Permission denied`) |
| user BがAのKnowledgeを一覧・検索できない | 成功 (一覧に出ず、検索は403) |
| API keyでchat completions、messages、terminals、automations作成、users、configs、code実行を呼べない | 成功 (403) |
| `owui-api`がallowlist外と破壊的操作を事前に拒否する | 成功 |
| skillに記載した全API例 (files、notes、memory、chats、folders、calendar、channels、models、prompts、skills、tools、evaluations、notifications) | 成功 |
| Open WebUI経由でuser AのPi (`google/gemma4:12b`) がKnowledgeを検索し、出典付きのWord設計書を1回の依頼で生成する | 成功。1回目約5分、skill改善後の2回目約1分。`officecli validate`成功、記載内容は根拠文書と一致 |
| 生成したdocxをLibreOfficeでPDF化し日本語を描画する | 成功 |
| 生成物をOpen WebUIのterminal proxy (`/files/view`) からdownloadする | 成功 (元fileと同一) |
| LangfuseでPiのLLM requestを確認する | 成功 (`pi` tag付き14 generation) |
| web search (`owui-web-search`) | 未達。SearXNGの結果取得後、CPU上のembeddingに数分以上かかりtimeoutした |

既知の未対応事項:

- Open WebUIのweb searchは取得pageをembeddingしてから返すため、CPU版vLLMでは実用速度にならない。`BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL`は通常chatの挙動も変えるため、未変更とした。
- `RAG_EXTERNAL_RERANKER_URL`はpathを含まないためrerankが常に失敗し、元の順序で返っている。`/v1/rerank`を指定するとrerankは動くが、CPU版vLLM (2 core) で1 queryに約20分かかるため、未変更とした。
- LiteLLMはdatabaseなしで動作しているため、Pi専用のvirtual keyを発行できず、master keyを共有している。

## References

- [Open WebUI: LibreTranslate Integration](https://docs.openwebui.com/tutorials/integrations/libre-translate/)
- [Open Terminal agents](https://github.com/open-webui/open-terminal/blob/v0.17.22/open_terminal/agents/sessions.py)
- [Pi: Choose a Model](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md)
- [Pi: Configuration](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md)
- [OfficeCLI](https://github.com/iOfficeAI/OfficeCLI)
- [Agent Skills Specification](https://agentskills.io/specification)
- [Open Terminal user isolation](https://github.com/open-webui/open-terminal/blob/v0.17.22/open_terminal/utils/user_isolation.py)
- [Open WebUI API Endpoints](https://docs.openwebui.com/getting-started/api-endpoints/)
