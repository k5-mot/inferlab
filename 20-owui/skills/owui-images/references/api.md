# owui-images API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/images/config`

Get Config


### `POST /api/v1/images/config/update`

Update Config

- body (application/json): `ENABLE_IMAGE_EDIT`*: boolean, `ENABLE_IMAGE_GENERATION`*: boolean, `ENABLE_IMAGE_PROMPT_GENERATION`*: boolean, `IMAGE_CONNECTIONS`: array<ImageConnection>, `IMAGE_EDIT_DEFAULT_MODEL`: string, `IMAGE_GENERATION_DEFAULT_MODEL`: string

### `GET /api/v1/images/connections/models`

Get Connection Models


### `POST /api/v1/images/connections/verify`

Verify Image Connection

- body (application/json): `config`: object, `id`: string, `key`: string, `name`: string, `type`: string, `url`: string

### `POST /api/v1/images/edit`

Edit Images

- body (application/json): `background`: string, `image`*: string | array<string>, `model`: string, `n`: integer, `negative_prompt`: string, `prompt`*: string, `size`: string

### `POST /api/v1/images/generations`

Generate Images

- body (application/json): `model`: string, `n`: integer, `negative_prompt`: string, `prompt`*: string, `size`: string, `steps`: integer

### `GET /api/v1/images/models`

Get Models
