
```bash
sudo docker compose --profile common --profile inference-ollama --profile openwebui --profile hermes-agent down
sudo docker compose --profile common --profile inference-ollama --profile openwebui --profile hermes-agent up -d --force-recreate --remove-orphans

curl -sS http://localhost:40000/v1/models \
  -H 'Authorization: Bearer sk-litellm-master-key' \
  | jq .

curl -sS http://localhost:40000/v1/chat/completions \
  -H 'Authorization: Bearer sk-litellm-master-key' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma4:e4b",
    "messages": [
      {"role": "user", "content": "日本語で短く自己紹介して"}
    ],
    "temperature": 0.2
  }' \
  | jq .

curl -sS http://localhost:40000/embeddings \
  -H 'Authorization: Bearer sk-litellm-master-key' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "ruri-v3:310m",
    "input": ["テスト"]
  }' \
  | jq .

curl -sS http://localhost:40000/rerank \
  -H 'Authorization: Bearer sk-litellm-master-key' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "ruri-v3-reranker:310m",
    "query": "テスト",
    "documents": ["ドキュメント1", "ドキュメント2"]
  }' \
  | jq .
```
