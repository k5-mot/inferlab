# InferLab Phase 1-2 User Verification Manual

この手順は `task.md` の PoC スコープのうち、Phase 1 から Phase 2 までをユーザが順番に検証するためのものです。

- Phase 1: BookStack / Seafile 同期、RAGFlow 検索、Citation 付き回答
- Phase 2: Carbone 生成、DOCX/PDF 出力

## 1. 前提条件

Docker Compose が使えることを確認します。

```bash
docker compose version
```

構成ファイルが正しく解決できることを確認します。

```bash
docker compose --profile inference-ollama --profile openwebui --profile ragflow --profile carbone config --quiet
```

このコマンドが何も出力せず終了すれば OK です。

## 2. 環境変数の準備

`.env` を作成または更新します。最低限、RAGFlow の API Key と同期元の接続情報が必要です。

```bash
RAGFLOW_API_KEY=ragflow-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
RAGFLOW_CHAT_ID=
RAGFLOW_CHAT_IDS=manuals:<chat_id>
RAGFLOW_AGENT_IDS=

BOOKSTACK_BASE_URL=http://bookstack.example.local
BOOKSTACK_TOKEN_ID=...
BOOKSTACK_TOKEN_SECRET=...
BOOKSTACK_DATASET_NAME=rag_bookstack

SEAFILE_BASE_URL=http://seafile.example.local
SEAFILE_API_TOKEN=...
SEAFILE_LIBRARY_IDS=
SEAFILE_PATHS=/
SEAFILE_DATASET_NAME=rag_seafile

CARBONE_GATEWAY_PUBLIC_URL=http://localhost:31010
```

補足:

- `RAGFLOW_API_KEY` は RAGFlow UI で作成します。
- `RAGFLOW_CHAT_ID` は `/answer` で RAGFlow Chat に回答生成させたい場合だけ設定します。空でも citation 付き候補回答は返ります。
- `RAGFLOW_CHAT_IDS` は Open WebUI Pipelines に RAGFlow Chat を表示したい場合に設定します。
- BookStack だけ、または Seafile だけでも検証できます。その場合、未使用側の環境変数は空で構いません。

## 3. イメージのビルド

新規追加した sync-worker と carbone-gateway をビルドします。

```bash
docker compose --profile ragflow --profile carbone build sync-worker carbone-gateway
```

`Image inferlab-sync-worker Built` と `Image inferlab-carbone-gateway Built` が表示されれば OK です。

## 4. サービス起動

Phase 1 から Phase 2 までをまとめて起動します。

```bash
docker compose --profile inference-ollama --profile openwebui --profile ragflow --profile carbone up -d
```

起動状態を確認します。

```bash
docker compose --profile inference-ollama --profile openwebui --profile ragflow --profile carbone ps
```

最低限、以下が `Up` になっていることを確認します。

- `inferlab-ragflow`
- `inferlab-sync-worker`
- `inferlab-carbone-gateway`
- `inferlab-open-webui`
- `inferlab-open-webui-pipelines`
- `inferlab-litellm`

## 5. Health Check

sync-worker を確認します。

```bash
curl -s http://localhost:31011/health
```

期待例:

```json
{"ok":true,"state_path":"/data/sync.sqlite3"}
```

Carbone Gateway を確認します。

```bash
curl -s http://localhost:31010/health
```

期待例:

```json
{"ok":true,"output_dir":"/app/outputs"}
```

RAGFlow UI はブラウザで確認します。

```text
http://localhost:31008/
```

Open WebUI はブラウザで確認します。

```text
http://localhost:31001/
```

## 6. Phase 1: BookStack / Seafile 同期

BookStack を同期します。

```bash
curl -s -X POST http://localhost:31011/sync/bookstack | jq .
```

Seafile を同期します。

```bash
curl -s -X POST http://localhost:31011/sync/seafile | jq .
```

両方まとめて同期する場合:

```bash
curl -s -X POST http://localhost:31011/sync/all | jq .
```

期待する確認ポイント:

- `dataset_id` が返る
- `scanned` が 1 以上になる
- 初回は `uploaded` が 1 以上になる
- 2 回目以降、変更がなければ `skipped` が増える

RAGFlow UI でも以下を確認します。

- `rag_bookstack` データセットが存在する
- `rag_seafile` データセットが存在する
- 同期した文書が登録されている
- parse が完了している

## 7. Phase 1: RAGFlow 検索

検索 API を実行します。

```bash
curl -s -X POST http://localhost:31011/search \
  -H 'Content-Type: application/json' \
  -d '{"question":"VPNの申請手順は？"}' | jq .
```

期待する確認ポイント:

- `chunks` が配列で返る
- `citations` が配列で返る
- citation に `source_name`、`page_url`、`file_path`、`document_id` のいずれかが含まれる

metadata filter を確認する場合:

```bash
curl -s -X POST http://localhost:31011/search \
  -H 'Content-Type: application/json' \
  -d '{
    "question": "VPNの申請手順は？",
    "metadata_condition": {
      "op": "and",
      "conditions": [
        {"field": "source", "op": "eq", "value": "bookstack"}
      ]
    }
  }' | jq .
```

## 8. Phase 1: Citation 付き回答

回答 API を実行します。

```bash
curl -s -X POST http://localhost:31011/answer \
  -H 'Content-Type: application/json' \
  -d '{"question":"VPNの申請手順を根拠付きで説明して"}' | jq .
```

期待する確認ポイント:

- `answer` が返る
- `citations` が返る
- `RAGFLOW_CHAT_ID` を設定している場合は RAGFlow Chat の回答が返る
- `RAGFLOW_CHAT_ID` が空の場合は検索チャンクから候補回答と citation が返る

## 9. Phase 2: DOCX/PDF 生成

Carbone Gateway に構造化 JSON を渡して DOCX/PDF を生成します。

```bash
curl -s -X POST http://localhost:31010/v1/reports \
  -H 'Content-Type: application/json' \
  -d '{
    "title": "VPN申請手順",
    "summary": "社内VPNの申請から承認までの流れ。",
    "sections": [
      {
        "title": "手順",
        "bullets": [
          "申請フォームを開く",
          "利用目的を入力する",
          "所属長承認を依頼する"
        ]
      }
    ],
    "citations": [
      {
        "ref": 1,
        "source_name": "IT手順書",
        "page_url": "http://bookstack.example.local/books/it/page/vpn"
      }
    ],
    "formats": ["docx", "pdf"]
  }' | jq .
```

期待する確認ポイント:

- `files` に `docx` と `pdf` が返る
- 各 file に `filename`、`url`、`bytes` が入る
- `bytes` が 0 より大きい

返ってきた `url` をブラウザで開き、ファイルがダウンロードできることを確認します。

生成物はホスト側では以下に保存されます。

```text
carbone/outputs/
```

## 10. Phase 2: Markdown 変換 API

構造化 JSON ではなく Markdown から生成する場合:

```bash
curl -s -X POST http://localhost:31010/v1/convert \
  -H 'Content-Type: application/json' \
  -d '{
    "title": "Markdown検証",
    "markdown": "# Markdown検証\n\n## Summary\n\nこれはMarkdownからDOCX/PDFを生成する検証です。\n",
    "formats": ["docx", "pdf"]
  }' | jq .
```

期待する確認ポイントは `/v1/reports` と同じです。

## 11. Open WebUI Pipelines での確認

ブラウザで Open WebUI を開きます。

```text
http://localhost:31001/
```

モデル一覧に以下が表示されることを確認します。

- `RAGFlow: Chat: <label>` または `RAGFlow: Agent: <label>`
- `Carbone: DOCX/PDF Report`

Carbone Pipeline を選び、以下のような JSON を送信します。

```json
{
  "title": "Open WebUI経由の生成テスト",
  "summary": "Open WebUI Pipelines から Carbone Gateway を呼び出す検証。",
  "sections": [
    {
      "title": "確認項目",
      "bullets": ["DOCXリンクが返る", "PDFリンクが返る"]
    }
  ],
  "citations": [],
  "formats": ["docx", "pdf"]
}
```

期待する確認ポイント:

- チャット応答に DOCX と PDF のリンクが表示される
- リンクを開くと生成ファイルを取得できる

## 12. トラブルシュート

`RAGFLOW_API_KEY is not configured` が出る場合:

```bash
docker compose --profile ragflow exec sync-worker env | grep RAGFLOW
```

`.env` の `RAGFLOW_API_KEY` が空でないことを確認し、必要なら再起動します。

```bash
docker compose --profile ragflow up -d --force-recreate sync-worker
```

BookStack 同期が 400 になる場合:

- `BOOKSTACK_BASE_URL`
- `BOOKSTACK_TOKEN_ID`
- `BOOKSTACK_TOKEN_SECRET`

を確認します。

Seafile 同期が 400 になる場合:

- `SEAFILE_BASE_URL`
- `SEAFILE_API_TOKEN`
- `SEAFILE_LIBRARY_IDS`
- `SEAFILE_PATHS`

を確認します。

Carbone 生成が 502 になる場合:

```bash
docker compose --profile carbone logs -f carbone carbone-gateway
```

Carbone EE の license が必要な環境では `CARBONE_EE_LICENSE` または `CARBONE_API_KEY` を設定してください。

Open WebUI に Pipeline が表示されない場合:

```bash
docker compose --profile openwebui logs -f open-webui-pipelines
```

`docker-compose.openwebui.yml` で以下の mount が有効になっていることを確認します。

```text
./ragflow/pipelines/ragflow_pipeline.py:/app/pipelines/ragflow_pipeline.py:ro
./carbone/pipelines/carbone_pipeline.py:/app/pipelines/carbone_pipeline.py:ro
```

## 13. 停止

検証後に停止する場合:

```bash
docker compose --profile inference-ollama --profile openwebui --profile ragflow --profile carbone down
```

生成物を削除する場合:

```bash
rm -f carbone/outputs/*
```

同期 state を初期化する場合:

```bash
docker volume rm inferlab_sync-worker-data
```

注意: 同期 state を消すと次回同期時に既存文書が再投入される可能性があります。
