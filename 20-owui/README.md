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

## Open TerminalでのOffice作成とPi

Open WebUIのchatでterminal (Open-Terminal) を選ぶと、modelはOpen WebUI userごとのOS userとしてOpen Terminal上でcommandを実行し、Word、Excel、PowerPointを作成できる。用途で次の2つを使い分ける。設計の背景は[`NEXT.md`](../NEXT.md)を参照する。

| 用途 | model | 社内data (Knowledge、Notes、Memory、chat) の使い方 |
| --- | --- | --- |
| 標準: 業務の依頼 | 通常model (例: `google/gemma4:12b`) | Open WebUIの組み込みtool (`query_knowledge_bases`、`search_notes`、`recall_memories`など) がuser本人の権限で呼ぶ |
| 特化: coding agentでの作業 | `pi/inferlab/...` ([Pi coding agent](https://github.com/earendil-works/pi)) | Piは社内dataへ直接触れない。同じchatで先に通常modelへKnowledgeを付けて質問し、modelをPiへ切り替えて依頼すると、その回答が前の会話としてPiへ渡る |

どちらの方式でも、Open WebUIのAPI keyをOpen Terminalへ置かない。Open WebUIとOpen Terminalには改修を加えず、上流の機能 (組み込みtool、terminal tool、home directoryの`AGENTS.md`とskill) だけを使う。

### 構成

| file | 役割 |
| --- | --- |
| `open-terminal/Dockerfile` | OfficeCLI、OfficeCLIのWord/PowerPoint/Excel skill、共通の`AGENTS.md`、`pptx-check`、Piを追加する派生image。上流のentrypointと動作は変えない。build contextは`20-owui`。 |
| `open-terminal/agent/AGENTS.md` | 通常modelとPiが共通で読む指示。社内dataの扱いと、検証済みのOffice作成手順 (docx、xlsx、pptx) を持つ。 |
| `open-terminal/agent/pptx_check.py` | `pptx-check`。PowerPointをPDFへ描画し、slideからはみ出して表示されない行を報告する。 |
| `open-terminal/pi/models.json`、`settings.json` | PiのLiteLLM provider定義と既定model。LiteLLMのkeyはcomposeのsecret (`/run/secrets/pi-litellm-api-key`) から読む。 |
| `open-terminal/pi/inferlab-pi.sh` | Pi起動前にmodel定義をuserの`~/.pi/agent`へ配布する。 |

`AGENTS.md`とskillは、imageの`/etc/inferlab/agent`へ置く。Open Terminalがuserを作るとき (`useradd -m`)、`/etc/skel`から`~/AGENTS.md`と`~/.agents/skills`へのsymbolic linkがhomeへ作られる。このimageより前に作られたhomeにはlinkが無いため、必要ならuserが同じlinkを作る。Open TerminalはこのhomeのファイルをOpen WebUIへ渡し、Piも同じ場所を読む。imageを更新すると、全userの指示とskillが更新される。

### 権限境界

| 制御 | 実装 |
| --- | --- |
| userの識別 | Open Terminalのmulti-user modeが、Open WebUI userごとに別OS userでcommandとPiを実行する。homeはmode `2770`で、他userからは読めない。 |
| 社内data | 通常modelの組み込みtoolは、Open WebUI内でuser本人のsessionとACLで動く。PiはOpen WebUIのAPIを呼ばない。 |
| LiteLLM | Piは`/run/secrets/pi-litellm-api-key`のmaster keyでLiteLLMを呼ぶ。閉域での利用を前提に、全OS userがkeyを読めることを許容する。 |
| host権限 | `open-terminal`へ`/var/run/docker.sock`をmountしない。mountすると新規OS userがdocker groupへ自動追加される。 |
| terminalの提供範囲 | `TERMINAL_SERVER_CONNECTIONS`の`access_grants`に`principal_id: "*"`を指定し、全userへ提供する。特定のuserやgroupだけへ絞る場合は、`principal_type`を`user`または`group`にし、`principal_id`へそのIDを指定する。`access_grants`を空にすると管理者専用になる。 |

multi-user modeのOS user分離は、上流の説明どおりuser間のsecurity boundaryではない。本構成は個人や小規模チームでの利用を前提とし、全社展開や機密業務ではcontainer単位の分離を検討する。

### 前提条件

- 一般userが通常modelを使うには、管理者がOpen WebUIの管理者パネル > モデルで、対象modelをuserまたはgroupへ公開する。
- 通常modelがterminal toolと組み込みtoolを使うには、modelのfunction callingが`native` (既定値) である必要がある。
- Memoryを使う依頼では、userが設定 > パーソナライズでMemoryを有効にする。

### 導入

```bash
# 派生imageをbuildし、Open Terminalを再作成する。
sudo docker compose --env-file .env --profile owui up -d --build --force-recreate open-terminal

# Open Terminalがhealthyになってから、Open WebUIを再起動してterminal serverを登録し直す。
sudo docker compose --env-file .env --profile owui restart open-webui
```

期待結果:

- `open-webui`と`open-terminal`が`healthy`になる。
- `open-webui`のlogに`Initialized 1 terminal server(s)`が出る。
- chatでterminalを選ぶと、model一覧に`pi/inferlab/...`が表示される。

失敗条件:

- build時にnpm registryまたはOfficeCLIのrelease binaryへ到達できない。閉域環境では、事前にbuildしたimageを持ち込む。
- Piが`401`を返す。`.env`の`LITELLM_MASTER_KEY`が空でないか確認する。
- `open-webui`のlogが`Initialized 0 terminal server(s)`になる。Open WebUIは起動時にだけterminal serverを登録するため、`open-terminal`の起動後に上記の`restart open-webui`を実行する。

### rollback

```bash
# 派生imageを導入する前のcommitのcomposeへ戻す (<commit>は導入前のcommit)。
git checkout <commit> -- 20-owui/docker-compose.yml

# 上流imageのOpen TerminalとOpen WebUIを再作成する。
sudo docker compose --env-file .env --profile owui up -d --force-recreate open-terminal open-webui
```

期待結果: `open-terminal`が上流image (`ghcr.io/open-webui/open-terminal`) で起動する。user homeは`open-terminal-homes` volumeに残る。

失敗条件: 戻したcomposeに`open-terminal-homes` volumeが無い場合、user homeはcontainer内だけになり、再作成で失われる。

### 検証結果

2026-11-25に、一般user 2名 (A、B)、Aだけが読めるKnowledge、AのNoteとMemoryを作って確認した。modelは`google/gemma4:12b` (LM Studio) である。検証中だけ`BYPASS_MODEL_ACCESS_CONTROL`で通常modelを一般userへ公開し、検証後に元の設定へ戻した。

| 確認内容 | 結果 |
| --- | --- |
| 標準: 通常modelがKnowledgeを組み込みtoolで検索し、出典付きのWord設計書をterminalに作る | 成功 (45秒)。`officecli validate`成功、内容は根拠文書と一致 |
| 標準: 通常modelがMemoryの好みとNoteを読み、SUMIF数式と棒グラフ付きのExcelを作る | 成功 (約2分)。初回は集計表の数式範囲が誤っていたため、`AGENTS.md`へ検証済みの集計表とgraphの手順を追加した後の結果 |
| 特化: 同じchatで通常modelがKnowledgeをRAGで要約し、Piへ切り替えて出典付きのWordを作る | 成功 (要約15秒、Word 45秒)。Piは前の回答だけを根拠にした |
| 新規userのhomeに`~/AGENTS.md`と`~/.agents/skills`が作られ、Open Terminalのskill一覧に出る | 成功 |
| user BがAのhomeを読めない | 成功 (`Permission denied`) |
| user BがAのKnowledgeを一覧・検索できない | 成功 (一覧に出ず、検索は403) |
| PiがcomposeのsecretのkeyでLiteLLMを呼べる (LiteLLM用の中継を廃止した後の確認) | 成功 |
| LangfuseでLLM requestを確認する | 成功。通常modelはOpen WebUI user IDで記録される。PiはLiteLLMを共通keyで呼ぶため、userは区別されない |
| PowerPointの図形による構成図とはみ出し検査 (Pi、前回の検証) | 成功。`pptx-check`はslideからはみ出した行を検出する |

既知の未対応事項:

- 組み込みtoolは、Open WebUIの画面から送ったchat (socket sessionあり) でだけ有効になる。APIから直接呼ぶ場合は使えない。
- `google/gemma4:12b`は、手順に無い作業 (例: 集計表の数式範囲) を誤り、誤った結果を正しいと報告することがある。成果物はuserが確認する。
- Open WebUIのweb searchは、取得pageをCPU版vLLMでembeddingするため1回に10分以上かかる。`RAG_EXTERNAL_RERANKER_URL`はpathを含まないためrerankが常に失敗している。どちらもGPUを用意するまで変更しない。

## References

- [Open WebUI: LibreTranslate Integration](https://docs.openwebui.com/tutorials/integrations/libre-translate/)
- [Open Terminal agents](https://github.com/open-webui/open-terminal/blob/v0.17.22/open_terminal/agents/sessions.py)
- [Open Terminal user isolation](https://github.com/open-webui/open-terminal/blob/v0.17.22/open_terminal/utils/user_isolation.py)
- [Pi: Choose a Model](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md)
- [Pi: Configuration](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md)
- [OfficeCLI](https://github.com/iOfficeAI/OfficeCLI)
- [Agent Skills Specification](https://agentskills.io/specification)
