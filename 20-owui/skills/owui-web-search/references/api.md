# owui-web-search API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `POST /api/v1/retrieval/process/web`

Process Web

- parameters: `process` (query, boolean), `overwrite` (query, boolean)
- body (application/json): `collection_name`: string, `url`*: string

### `POST /api/v1/retrieval/process/web/search`

Process Web Search

- body (application/json): `queries`*: array<string>
