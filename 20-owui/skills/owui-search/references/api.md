# owui-search API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/search`

Search

- parameters: `q` (query, string), `kind` (query, string), `sharing` (query, string), `scope` (query, string), `page` (query, integer)
