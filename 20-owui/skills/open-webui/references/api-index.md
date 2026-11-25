# Open WebUI API index

Open WebUI v0.13.4のOpenAPI Schemaから生成した。手で編集しない。

| Skillまたは除外理由 | operation数 |
| --- | --- |
| 除外: Pi自身をagent modelとして呼べるため、再帰防止で禁止する。 | 3 |
| 除外: 推論はLiteLLMへ集約する。RAGはowui-knowledge経由で使う。 | 1 |
| 除外: Anthropic Messages互換のchat APIであり、再帰防止で禁止する。 | 2 |
| owui-models | 24 |
| 除外: 同上。 | 9 |
| 除外: 管理機能。 | 20 |
| owui-audio | 6 |
| 除外: 認証情報の発行・変更を伴うため禁止する。 | 39 |
| 除外: agent modelを定期実行できるため、再帰防止で禁止する。 | 10 |
| owui-calendar | 14 |
| owui-channels | 33 |
| owui-chats | 56 |
| 除外: 管理機能（owui-admin、原則無効）。 | 64 |
| owui-evaluations | 15 |
| owui-files | 16 |
| owui-folders | 15 |
| 除外: server側code実行の登録を伴うため禁止する。 | 22 |
| owui-images | 7 |
| owui-knowledge | 39 |
| owui-memory | 12 |
| owui-notes | 13 |
| owui-notifications | 11 |
| owui-prompts | 15 |
| 除外: query、web以外はRAG設定の変更やresetを含む管理機能。 | 12 |
| owui-web-search | 2 |
| owui-skills | 21 |
| 除外: chat taskの制御であり、agent loopから使う必要がない。 | 10 |
| 除外: Open Terminal経由でagent sessionを起動できるため、再帰防止で禁止する。 | 31 |
| owui-tools | 23 |
| 除外: server側code実行とDB downloadを含むため禁止する。 | 4 |
| 除外: 認証flow。 | 6 |
| 除外: 推論はLiteLLMへ集約する。 | 64 |

## 未分類

次のoperationはSkill化しておらず、API keyのallowlistにも含めない。

- `GET /api/changelog`
- `GET /api/config`
- `GET /api/events`
- `GET /api/events/webhooks`
- `POST /api/events/webhooks`
- `PUT /api/events/webhooks/{webhook_id}`
- `DELETE /api/events/webhooks/{webhook_id}`
- `GET /api/usage`
- `GET /api/v1/apps`
- `POST /api/v1/apps`
- `POST /api/v1/apps/manifest/preview`
- `GET /api/v1/apps/{app_id}`
- `PATCH /api/v1/apps/{app_id}`
- `DELETE /api/v1/apps/{app_id}`
- `POST /api/v1/apps/{app_id}/connect`
- `POST /api/v1/apps/{app_id}/interactions`
- `GET /api/v1/comments/`
- `POST /api/v1/comments/`
- `GET /api/v1/comments/context`
- `GET /api/v1/comments/mentions`
- `GET /api/v1/comments/{id}`
- `PATCH /api/v1/comments/{id}`
- `DELETE /api/v1/comments/{id}`
- `PUT /api/v1/comments/{id}/reactions`
- `DELETE /api/v1/comments/{id}/reactions`
- `GET /api/v1/comments/{id}/replies`
- `POST /api/v1/comments/{id}/replies`
- `GET /api/v1/search`
- `GET /api/v1/videos/config`
- `POST /api/v1/videos/config/update`
- `GET /api/v1/videos/connections/models`
- `POST /api/v1/videos/connections/verify`
- `POST /api/v1/videos/generations`
- `GET /api/v1/videos/models`
- `GET /api/version`
- `GET /api/version/updates`
- `GET /cache/{path}`
- `GET /health`
- `GET /health/db`
- `GET /manifest.json`
- `GET /opensearch.xml`
- `GET /ready`
