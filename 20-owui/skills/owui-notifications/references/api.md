# owui-notifications API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/notifications/events`

Get Notification Events


### `GET /api/v1/notifications/inbox`

Get Inbox

- parameters: `cursor` (query, string), `limit` (query, integer)

### `GET /api/v1/notifications/inbox/count`

Get Inbox Count


### `POST /api/v1/notifications/inbox/open`

Open Inbox


### `PATCH /api/v1/notifications/inbox/{id}`

Read Inbox Item

- parameters: `id` (path, string, required)

### `GET /api/v1/notifications/targets`

Get Notification Targets


### `POST /api/v1/notifications/targets`

Create Notification Target

- body (application/json): `config`: object, `delivery`: string, `enabled`: boolean, `events`: array<string>, `id`: string, `type`: string

### `PUT /api/v1/notifications/targets/{target_id}`

Update Notification Target

- parameters: `target_id` (path, string, required)
- body (application/json): `config`: object, `delivery`: string, `enabled`: boolean, `events`: array<string>, `id`: string, `type`: string

### `DELETE /api/v1/notifications/targets/{target_id}`

Delete Notification Target

- parameters: `target_id` (path, string, required)

### `PUT /api/v1/notifications/targets/{target_id}/default`

Set Default Notification Target

- parameters: `target_id` (path, string, required)

### `POST /api/v1/notifications/targets/{target_id}/test`

Test Notification Target

- parameters: `target_id` (path, string, required)
