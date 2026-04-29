
```bash
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
```
