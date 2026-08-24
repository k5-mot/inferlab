# RAG

DoclingとQdrantをまとめた文書処理・ベクトル検索stack。

- Docling: 文書変換APIとUIを提供する。
- Qdrant: Open WebUIなどから利用するベクトル検索databaseを提供する。

Qdrantはhostへportを公開していないため、動作確認は同じCompose network上のDocling containerから実行する。

## Docling資材の準備

Doclingはhost上の次の資材をread-onlyで利用する。

- `/srv/docling/`: `uvx --from docling==2.118.0 docling-tools models download`で取得したmodel catalogの各stageで⭐が付いたmodel。
- `/srv/docling/tesseract/`: 英語・日本語のTesseract traineddata。

オンライン端末のrepository rootで実行する。

```powershell
# 配布用treeをout/srv/doclingへ取得する。
.\script\Download-Docling-Assets.ps1 -OutputDirectory out
```

LinuxまたはmacOSではShell版を実行できる。

```bash
# 配布用treeをout/srv/doclingへ取得する。
./script/download-docling-assets.sh --output-directory out
```

期待結果:

- `out/srv/docling/`直下に`layout`、`tableformer`、`rapidocr`、`picture_classifier`、`granitedocling`、`smolvlm`、`code_formula`のmodel directoryが作成される。
- `out/srv/docling/tesseract/`に`eng`、`jpn`、`jpn_vert`、`osd`、`script/Japanese`、`script/Japanese_vert`のtraineddataが作成される。
- traineddataのSHA-256検証が成功する。

失敗条件:

- `uvx`を利用できない、またはuvx経由の`docling-tools`実行に失敗する。
- traineddataのdownloadまたはSHA-256検証に失敗する。
- airgap serverへ資材を転送した後、bind mount元のdirectoryまたはfileが不足する。

## 起動

repository rootで実行する。

```bash
# RAG stackを起動する。
sudo docker compose --env-file .env --profile rag up -d
```

期待結果:

- `docling`が`http://${PUBLIC_HOST}:31100`で応答する。
- `qdrant`がCompose network内の`http://qdrant:6333`で応答する。
- `docling`と`qdrant`がhealthyになる。
- Doclingがbind mountしたmodelを起動時に読み込む。

失敗条件:

- Doclingのmodel cache初期化またはdownloadで起動が止まる。
- `/srv/docling/`のmodel directoryまたは`/srv/docling/tesseract/`が存在しない。
- Qdrantが`11-rag/qdrant/config.yaml`を読み込めない。
- hostの`31100` portが他processと競合する。

## 確認手順

repository rootで実行する。

```bash
# rag profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile rag ps

# .envのAPI keyと接続先hostを現在のshellに読み込む。
set -a; . ./.env; set +a

# hostからDoclingのhealth endpointを確認する。
curl -fsS -H "X-Api-Key: ${DOCLING_SERVE_API_KEY}" "http://${PUBLIC_HOST:-localhost}:31100/readyz" >/dev/null

# Docling container内からDoclingのhealth endpointを確認する。
sudo docker compose --env-file .env --profile rag exec docling curl -fsS -H "X-Api-Key: ${DOCLING_SERVE_API_KEY}" http://127.0.0.1:5001/readyz >/dev/null

# Docling containerがhost側modelをread-only mountしていることを確認する。
sudo docker compose --env-file .env --profile rag exec docling findmnt -T /opt/app-root/src/.cache/docling/models -o TARGET,SOURCE,OPTIONS

# Docling containerで利用可能なTesseract言語を確認する。
sudo docker compose --env-file .env --profile rag exec docling tesseract --list-langs

# Docling containerからQdrantのhealth endpointを確認する。
sudo docker compose --env-file .env --profile rag exec docling curl -fsS -H "api-key: ${QDRANT_API_KEY}" http://qdrant:6333/readyz >/dev/null

# Docling containerからQdrantのcollection一覧APIを確認する。
sudo docker compose --env-file .env --profile rag exec docling curl -fsS -H "api-key: ${QDRANT_API_KEY}" http://qdrant:6333/collections
```

期待結果:

- `docling`と`qdrant`が`healthy`になる。
- Doclingの`readyz`がHTTP 200を返す。
- model mountのoptionに`ro`が含まれる。
- Tesseract言語一覧に`eng`、`jpn`、`jpn_vert`、`osd`、`script/Japanese`、`script/Japanese_vert`が含まれる。
- Qdrantの`readyz`がHTTP 200を返す。
- Qdrantのcollection一覧APIがJSONを返す。

失敗条件:

- `docling`または`qdrant`が再起動を繰り返す。
- Doclingの`readyz`がHTTP 200を返さない。
- DoclingのAPI key不一致によりHTTP 401になる。
- model mountがread-onlyではない。
- 必要なTesseract言語が表示されない。
- QdrantのAPI key不一致によりHTTP 401になる。
- `docling` containerから`qdrant:6333`を名前解決できない。

## rollback

```bash
# RAG stackを停止する。
sudo docker compose --env-file .env --profile rag down
```

期待結果:

- `docling`と`qdrant`が停止する。
- `/srv/docling/`の資材とnamed volumeは削除されない。

失敗条件:

- `docker compose down`が非ゼロ終了する。

## References

- [uv: Using tools](https://docs.astral.sh/uv/guides/tools/)
- [Docling Serve](https://github.com/docling-project/docling-serve)
- [Docling model prefetching and offline usage](https://docling-project.github.io/docling/usage/advanced_options/#model-prefetching-and-offline-usage)
- [Docling CLI reference](https://github.com/docling-project/docling/blob/main/docs/reference/cli.md#docling-tools-models)
- [Docling model catalog](https://github.com/docling-project/docling/blob/main/docs/usage/model_catalog.md)
- [Tesseract tessdata_best](https://github.com/tesseract-ocr/tessdata_best)
