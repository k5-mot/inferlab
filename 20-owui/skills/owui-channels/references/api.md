# owui-channels API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/channels/`

Get Channels


### `POST /api/v1/channels/create`

Create New Channel

- body (application/json): `access_grants`: array<object>, `data`: object, `description`: string, `group_ids`: array<string>, `is_private`: boolean, `meta`: object, `name`: string, `type`: string, `user_ids`: array<string>

### `GET /api/v1/channels/list`

Get All Channels


### `GET /api/v1/channels/users/{user_id}`

Get Dm Channel By User Id

- parameters: `user_id` (path, string, required)

### `GET /api/v1/channels/webhooks/{webhook_id}/profile/image`

Get Webhook Profile Image

- parameters: `webhook_id` (path, string, required)

### `POST /api/v1/channels/webhooks/{webhook_id}/{token}`

Post Webhook Message

- parameters: `webhook_id` (path, string, required), `token` (path, string, required)
- body (application/json): `content`*: string

### `GET /api/v1/channels/{channel_id}/apps`

Get Channel Apps

- parameters: `channel_id` (path, string, required)

### `POST /api/v1/channels/{channel_id}/apps`

Invite App

- parameters: `channel_id` (path, string, required)
- body (application/json): `app_id`*: string

### `DELETE /api/v1/channels/{channel_id}/apps/{app_id}`

Remove App

- parameters: `channel_id` (path, string, required), `app_id` (path, string, required)

### `GET /api/v1/channels/{id}`

Get Channel By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/channels/{id}/access/update`

Update Channel Access By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`*: array<object>

### `DELETE /api/v1/channels/{id}/delete`

Delete Channel By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/channels/{id}/members`

Get Channel Members By Id

- parameters: `id` (path, string, required), `query` (query, string), `order_by` (query, string), `direction` (query, string), `page` (query, integer)

### `POST /api/v1/channels/{id}/members/active`

Update Is Active Member By Id And User Id

- parameters: `id` (path, string, required)
- body (application/json): `is_active`*: boolean

### `POST /api/v1/channels/{id}/members/mute`

Update Member Mute Status

- parameters: `id` (path, string, required)
- body (application/json): `is_channel_muted`*: boolean

### `GET /api/v1/channels/{id}/messages`

Get Channel Messages

- parameters: `id` (path, string, required), `skip` (query, integer), `limit` (query, integer)

### `GET /api/v1/channels/{id}/messages/pinned`

Get Pinned Channel Messages

- parameters: `id` (path, string, required), `page` (query, integer)

### `POST /api/v1/channels/{id}/messages/post`

Post New Message

- parameters: `id` (path, string, required)
- body (application/json): `content`*: string, `data`: object, `meta`: object, `parent_id`: string, `reply_to_id`: string, `temp_id`: string

### `GET /api/v1/channels/{id}/messages/{message_id}`

Get Channel Message

- parameters: `id` (path, string, required), `message_id` (path, string, required)

### `GET /api/v1/channels/{id}/messages/{message_id}/data`

Get Channel Message Data

- parameters: `id` (path, string, required), `message_id` (path, string, required)

### `DELETE /api/v1/channels/{id}/messages/{message_id}/delete`

Delete Message By Id

- parameters: `id` (path, string, required), `message_id` (path, string, required)

### `POST /api/v1/channels/{id}/messages/{message_id}/pin`

Pin Channel Message

- parameters: `id` (path, string, required), `message_id` (path, string, required)
- body (application/json): `is_pinned`*: boolean

### `POST /api/v1/channels/{id}/messages/{message_id}/reactions/add`

Add Reaction To Message

- parameters: `id` (path, string, required), `message_id` (path, string, required)
- body (application/json): `name`*: string

### `POST /api/v1/channels/{id}/messages/{message_id}/reactions/remove`

Remove Reaction By Id And User Id And Name

- parameters: `id` (path, string, required), `message_id` (path, string, required)
- body (application/json): `name`*: string

### `GET /api/v1/channels/{id}/messages/{message_id}/thread`

Get Channel Thread Messages

- parameters: `id` (path, string, required), `message_id` (path, string, required), `skip` (query, integer), `limit` (query, integer), `around` (query, string), `before` (query, string)

### `POST /api/v1/channels/{id}/messages/{message_id}/update`

Update Message By Id

- parameters: `id` (path, string, required), `message_id` (path, string, required)
- body (application/json): `content`*: string, `data`: object, `meta`: object, `parent_id`: string, `reply_to_id`: string, `temp_id`: string

### `POST /api/v1/channels/{id}/update`

Update Channel By Id

- parameters: `id` (path, string, required)
- body (application/json): `data`: object, `description`: string, `group_ids`: array<string>, `is_private`: boolean, `meta`: object, `name`: string, `user_ids`: array<string>

### `POST /api/v1/channels/{id}/update/members/add`

Add Members By Id

- parameters: `id` (path, string, required)
- body (application/json): `group_ids`: array<string>, `user_ids`: array<string>

### `POST /api/v1/channels/{id}/update/members/remove`

Remove Members By Id

- parameters: `id` (path, string, required)
- body (application/json): `user_ids`: array<string>

### `GET /api/v1/channels/{id}/webhooks`

Get Channel Webhooks

- parameters: `id` (path, string, required)

### `POST /api/v1/channels/{id}/webhooks/create`

Create Channel Webhook

- parameters: `id` (path, string, required)
- body (application/json): `name`*: string, `profile_image_url`: string

### `DELETE /api/v1/channels/{id}/webhooks/{webhook_id}/delete`

Delete Channel Webhook

- parameters: `id` (path, string, required), `webhook_id` (path, string, required)

### `POST /api/v1/channels/{id}/webhooks/{webhook_id}/update`

Update Channel Webhook

- parameters: `id` (path, string, required), `webhook_id` (path, string, required)
- body (application/json): `name`*: string, `profile_image_url`: string
