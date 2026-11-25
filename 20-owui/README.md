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
| `open-terminal/pi/models.json` | PiのLiteLLM provider定義。`owui-broker` (`127.0.0.1:8765/litellm`) 経由で呼び、master keyを持たない。 |
| `open-terminal/pi/settings.json` | 既定model (`google/gemma4:12b`) とtelemetry無効化。 |
| `open-terminal/pi/AGENTS.md` | Pi全体の指示。Open WebUI連携の規則とOffice生成の短縮手順を持つ。 |
| `open-terminal/pi/inferlab-pi.sh` | Pi起動前に、管理設定とskillをOpen WebUI userごとの`~/.pi/agent`へ同期する。 |
| `open-terminal/broker/owui_broker.py` | `owui-broker`。userごとのOpen WebUI API keyとLiteLLM master keyを保持し、Open WebUI、LiteLLM、tool serverへ中継する。 |
| `open-terminal/broker/inferlab-entrypoint.sh` | `owui-broker`を専用OS userで起動してからOpen Terminalを起動する。どちらかが終了するとcontainerを終了する。 |
| `skills/open-webui/` | 共通skill。規則、認証、API index、共通client `owui-api`。 |
| `skills/owui-*/` | 機能別skill。`references/api.md`はOpenAPI Schemaから生成する。 |
| `../scripts/owui-skills/` | Schemaの保存先とreference生成script。 |

skillはPi専用の記法を使わない[Agent Skills](https://agentskills.io/specification)形式のため、他のagent harnessへも配布できる。

### 権限境界

| 制御 | 実装 |
| --- | --- |
| userの識別 | Open Terminalのmulti-user modeが、Open WebUI userごとに別OS userでPiを起動する。homeはmode `2770`で、他userからは読めない。 |
| API認証 | 各userが自分のAPI keyを発行し、`owui-api login`で`owui-broker`へ登録する。keyは`open-terminal-broker` volume (mode `700`、owner `owui-broker`) に保存され、user本人のshellとPiからも読めない。共通管理者keyは使わない。 |
| 呼び出し元の判定 | `owui-broker`は`127.0.0.1:8765`で待ち受け、接続元socketの所有uidを`/proc/net/tcp`から得てOS userを判定する。clientは識別子を送らないため詐称できない。brokerが停止するとcontainerごと終了し、user processがportを奪う隙を作らない。 |
| LiteLLM | master keyは`owui-broker`だけが持つ。brokerはchat completionsとmodel一覧だけを中継し、`langfuse_trace_user_id`にOS user名を付ける。 |
| tool server | `owui-api tool`はbroker経由で`TOOL_SERVER_CONNECTIONS`のOpenAPI serverを呼ぶ。brokerはOpen WebUIの`GET /api/v1/tools/`で当該userに見えるserverだけを中継する。LibreTranslateは全user、mcpoは管理者だけが使える。 |
| データ権限 | Open WebUIのACL。共有されていないKnowledge、Notes、chatは取得できない。 |
| 到達できるAPI | `ENABLE_API_KEYS_ENDPOINT_RESTRICTIONS`と`API_KEYS_ALLOWED_ENDPOINTS`。全API key共通のprefix allowlistで、Hermes、OIKB、skillが使うものだけを含める。 |
| 再帰防止 | chat completions、Anthropic互換messages、terminals、automationsをallowlistから除外する。PiがOpen WebUI経由で自分自身を起動できない。 |
| host権限 | `open-terminal`へ`/var/run/docker.sock`をmountしない。mountすると新規OS userがdocker groupへ自動追加される。 |
| 破壊的操作 | `owui-api`はDELETE、`*/delete`、`*/reset`を`OWUI_CONFIRM=yes`なしで拒否する。これはagentへの指示であり、権限境界ではない。 |
| 監査 | `owui-broker`はuser、method、path (query stringを除く)、statusを`docker logs`へ記録する。keyとbodyは記録しない。 |

Open Terminalの接続 (`TERMINAL_SERVER_CONNECTIONS`) は、`access_grants`に`principal_id: "*"`を指定し、全userへ提供する。特定のuserやgroupだけへ絞る場合は、`principal_type`を`user`または`group`にし、`principal_id`へそのIDを指定する。`access_grants`を空にすると管理者専用になる。

multi-user modeのOS user分離は、上流の説明どおりuser間のsecurity boundaryではない。本構成は個人や小規模チームでの利用を前提とし、全社展開や機密業務ではcontainer単位の分離を検討する。

### 導入

```bash
# 派生imageをbuildし、Open WebUIとOpen Terminalを再作成する。
sudo docker compose --env-file .env --profile owui up -d --build --force-recreate open-webui open-terminal
```

期待結果:

- `open-webui`と`open-terminal`が`healthy`になる。
- terminal接続を許可されたuserが、Open WebUIのmodel選択で`pi/inferlab/...`を選べる。
- `open-terminal`のmountに`/var/run/docker.sock`が含まれない。
- `docker logs inferlab-open-terminal`に`owui-broker INFO listening on 127.0.0.1:8765`が出る。

失敗条件:

- build時にnpm registryまたはOfficeCLIのrelease binaryへ到達できない。
- Piの一覧に`Agent discovery failed`が表示される。
- `inferlab-entrypoint: owui-brokerが起動しませんでした。`が出てcontainerが再起動を繰り返す。`OWUI_BROKER_LITELLM_API_KEY`が空でないか確認する。
- `open-webui`のlogが`Initialized 0 terminal server(s)`で、terminalを選んでも`pi/`modelが出ない。Open WebUIは起動時にだけterminal serverを登録するため、`open-terminal`が`healthy`になってから次を実行する。

```bash
# open-terminalの起動後にOpen WebUIを再起動し、terminal serverを登録し直す。
sudo docker compose --env-file .env --profile owui restart open-webui
```

### userごとの初期設定

各userは、Open WebUIの設定 > アカウント > APIキーでkeyを発行し、Open WebUIのterminalで次を実行する。

```bash
# API keyを入力し、owui-brokerへ登録する。入力したkeyは画面に表示されない。
owui-api login

# 登録状態とkeyの有効性を確認する。
owui-api whoami
```

期待結果:

- `API keyをowui-brokerへ登録しました。`と表示される。
- `owui-api whoami`が`"api_key_registered": true`と`API keyは有効です。`を表示する。
- 旧構成で`~/.config/open-webui/api-key`へ保存したkeyがある場合、`owui-api login`はそのkeyをbrokerへ移し、fileを削除する。

失敗条件:

- `features.api_keys`権限が無く、key発行またはAPI呼び出しが403になる。
- `Open WebUIがAPI keyを受け付けません`と表示される。keyを発行し直す。

### keyの削除 (rollback)

```bash
# owui-brokerから自分のkeyを削除する。Open WebUIの設定でkey自体も削除する。
owui-api logout
```

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
- `api-index.md`の未分類operationが`なし。`である。

失敗条件:

- Schema取得がtimeoutする。起動完了まで待ってから再実行する。
- 生成scriptが`未分類: N operations`で終了code 1になる。新しいrouterを`generate_api_reference.py`の`SKILLS`または`EXCLUDED`へ追加し、skill化する場合は`API_KEYS_ALLOWED_ENDPOINTS`と`owui-api`の`ALLOWED_PREFIXES`も同時に更新する。

### Contract Test

Open WebUIの更新後やallowlistの変更後に、一般userのAPI keyで実機のresponse形状と拒否を確認する。

```bash
# 一般userのAPI keyをmode 600のfileへ保存してから、稼働中のOpen WebUIに対して実行する。
OWUI_CONTRACT_BASE_URL=http://localhost:32000 OWUI_CONTRACT_API_KEY_FILE=/path/to/api-key \
  python3 -m unittest tests.test_owui_contract -v
```

期待結果:

- 2件のtestが成功する。Skillのendpointは200で想定どおりの形状を返し、再帰起動、管理、認証、code実行のAPIは403になる。

失敗条件:

- 形状が変わったendpointがある。該当skillの`SKILL.md`の例と`tests/test_owui_contract.py`の`SHAPES`を更新する。
- 403を期待したAPIが到達可能になっている。`API_KEYS_ALLOWED_ENDPOINTS`を見直す。

### 検証結果

2026-11-25に、一般user 2名 (A、B) と、Aだけが読める検証用Knowledgeを作って確認した。初回の検証 (owui-brokerの導入前) では、terminal接続の`access_grants`を検証中だけuser Aへ付与した。2回目の検証 (owui-broker導入後) は、全userへ開放した状態で行った。Piのmodelは`google/gemma4:12b` (LM Studio) である。

権限境界とkeyの扱い:

| 確認内容 | 結果 |
| --- | --- |
| terminalを選んだ一般userに`pi/inferlab/...`の3 modelが表示される | 成功 |
| `owui-api login`の入力がterminalへ表示されず、keyがowui-brokerへ登録される。userのhomeにkey fileが残らない | 成功 |
| user本人のshellから`/var/lib/owui-broker`を読めない | 成功 (`Permission denied`) |
| LiteLLM master keyがOpen Terminal serverのprocess環境に無く、brokerのprocessだけが持つ | 成功 |
| brokerがLiteLLMの管理API (`/key/generate`) を中継しない | 成功 (403) |
| `open-terminal`を再作成しても、keyの登録、Pi session、成果物が残る | 成功 |
| user Bがuser Aのhomeを読めない | 成功 (`Permission denied`) |
| user BがAのKnowledgeを一覧・検索できない | 成功 (一覧に出ず、検索は403) |
| API keyでchat completions、messages、terminals、automations作成、auths、users、configs、code実行、appsを呼べない | 成功 (403。`tests/test_owui_contract.py`) |
| `owui-api tool`で、一般userがLibreTranslateを呼べ、管理者専用のmcpoは呼べない | 成功 (mcpoは403) |
| LangfuseでPiのrequestにOS user名 (`langfuse_trace_user_id`) が付く | 成功 |

Piへの依頼 (Open WebUIから1回の依頼で実行):

| シナリオ | 結果 |
| --- | --- |
| Knowledgeを検索し、出典付きのWord設計書を作る | 成功 (約1〜5分)。`officecli validate`成功、内容は根拠文書と一致 |
| Notesのアクションアイテムから、SUMIF数式と棒グラフ付きのExcelを作る | 成功 (約2分)。数式と、集計範囲を参照する棒グラフを確認 |
| Memoryの好みに従ってNotesを要約し、関連chatのtitleを添えて新しいNoteへ保存する | 一部成功 (下記の改善後、約2分)。Memoryの形式に従い、Noteは1件だけ保存された。ただし本文の改行が`\n`の文字のまま残り、担当者名1件を誤記した (高橋→高寺) |
| Knowledgeから、編集可能な図形の構成図を含む3枚のPowerPointを作り、はみ出しを確認する | 成功 (約2分)。`pptx-check`がOK、`officecli validate`成功 |
| web search (`owui-web-search`) | 成功 (13分14秒)。結果のcollectionは`"hybrid":false`で読める |
| 生成物をLibreOfficeでPDF化し日本語を描画する、terminal proxyからdownloadする | 成功 |

検証中に見つかり、修正した問題:

- 存在しないpathを呼ぶと、Open WebUIは画面のHTMLを200で返す。Piがこれを受け取ってcontextを使い切ったため、`owui-api`はHTMLを検出して失敗させる。
- Piはqueryを含むpathのquote忘れ、改行を含むJSONの手書き、空のbodyの送信をした。`owui-api`は、GETに付いたbody、bodyの位置のoption、空の標準入力を拒否する。JSONは`jq`で組み立てて`@-`で渡すよう、skillとAGENTS.mdに記載した。
- 失敗した書き込みを、Piが成功と報告した。書き込み後に読み戻して確認する規則をAGENTS.mdへ追加した。
- PowerPointの文字のはみ出しを、Piはrender画像で見落とした。描画されない行を機械的に報告する`pptx-check`を追加した。
- URL encodeされていない日本語のpathで、owui-brokerが応答せずに接続を切った。path全体をencodeして中継し、想定外の例外では500を返すよう修正した。

既知の未対応事項:

- Open WebUIのweb searchは、取得pageをembeddingしてから返すため、CPU版vLLMでは1回に10分以上かかる。当面は許容し、skillのtimeoutを30分にした。
- `RAG_EXTERNAL_RERANKER_URL`はpathを含まないためrerankが常に失敗し、元の順序で返っている。web searchのcollectionでは、このためにhybrid searchが400になる。`/v1/rerank`を指定するとrerankは動くが、CPU版vLLM (2 core) では1 queryに約20分かかるため、GPUを用意するまで変更しない。
- LiteLLMはdatabaseなしで動作しているため、user別のvirtual keyと利用上限は無い。master keyはowui-brokerだけが持つ。
- `google/gemma4:12b`は、Noteの本文に`\n`の文字を残す、固有名詞を誤記するなど、生成内容の誤りがある。成果物はuserが確認する。
- `google/gemma4:12b`は、手順を誤って同じ書き込みを繰り返すことがある。`owui-api`の拒否で大半は防げるが、誤って作られたdataはuserが確認して削除する。

## References

- [Open WebUI: LibreTranslate Integration](https://docs.openwebui.com/tutorials/integrations/libre-translate/)
- [Open Terminal agents](https://github.com/open-webui/open-terminal/blob/v0.17.22/open_terminal/agents/sessions.py)
- [Pi: Choose a Model](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md)
- [Pi: Configuration](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md)
- [OfficeCLI](https://github.com/iOfficeAI/OfficeCLI)
- [Agent Skills Specification](https://agentskills.io/specification)
- [Open Terminal user isolation](https://github.com/open-webui/open-terminal/blob/v0.17.22/open_terminal/utils/user_isolation.py)
- [Open WebUI API Endpoints](https://docs.openwebui.com/getting-started/api-endpoints/)
