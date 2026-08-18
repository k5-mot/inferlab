# RAG

DoclingとQdrantをまとめた文書処理・ベクトル検索stack。

- Docling: 文書変換APIとUIを提供する。
- Qdrant: Open WebUIなどから利用するベクトル検索databaseを提供する。

Qdrantはhostへportを公開していないため、動作確認は同じCompose network上のDocling containerから実行する。

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

失敗条件:

- Doclingのmodel cache初期化またはdownloadで起動が止まる。
- Qdrantが`11-rag/qdrant/config.yaml`を読み込めない。
- hostの`31100` portが他processと競合する。

## 確認手順

repository rootで実行する。

```bash
# rag profileのcontainer状態を確認する。
sudo docker compose --env-file .env --profile rag ps

# hostからDoclingのhealth endpointを確認する。
curl -fsS -H 'X-Api-Key: sk-docling-serve-api-key' "http://${PUBLIC_HOST:-localhost}:31100/readyz" >/dev/null

# Docling container内からDoclingのhealth endpointを確認する。
sudo docker compose --env-file .env --profile rag exec docling curl -fsS -H 'X-Api-Key: sk-docling-serve-api-key' http://127.0.0.1:5001/readyz >/dev/null

# Docling containerからQdrantのhealth endpointを確認する。
sudo docker compose --env-file .env --profile rag exec docling curl -fsS -H 'api-key: sk-qdrant-api-key' http://qdrant:6333/readyz >/dev/null

# Docling containerからQdrantのcollection一覧APIを確認する。
sudo docker compose --env-file .env --profile rag exec docling curl -fsS -H 'api-key: sk-qdrant-api-key' http://qdrant:6333/collections
```

期待結果:

- `docling`と`qdrant`が`healthy`になる。
- Doclingの`readyz`がHTTP 200を返す。
- Qdrantの`readyz`がHTTP 200を返す。
- Qdrantのcollection一覧APIがJSONを返す。

失敗条件:

- `docling`または`qdrant`が再起動を繰り返す。
- Doclingの`readyz`がHTTP 200を返さない。
- DoclingのAPI key不一致によりHTTP 401になる。
- QdrantのAPI key不一致によりHTTP 401になる。
- `docling` containerから`qdrant:6333`を名前解決できない。

## References

- [Docling Serve](https://github.com/docling-project/docling-serve)
