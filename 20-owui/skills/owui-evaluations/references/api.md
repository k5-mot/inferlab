# owui-evaluations API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/evaluations/config`

Get Config


### `POST /api/v1/evaluations/config`

Update Config

- body (application/json): `ENABLE_EVALUATION_ARENA_MODELS`: boolean, `EVALUATION_ARENA_MODELS`: array<object>

### `POST /api/v1/evaluations/feedback`

Create Feedback

- body (application/json): `data`: RatingData, `meta`: object, `snapshot`: SnapshotData, `type`*: string

### `GET /api/v1/evaluations/feedback/{id}`

Get Feedback By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/evaluations/feedback/{id}`

Update Feedback By Id

- parameters: `id` (path, string, required)
- body (application/json): `data`: RatingData, `meta`: object, `snapshot`: SnapshotData, `type`*: string

### `DELETE /api/v1/evaluations/feedback/{id}`

Delete Feedback By Id

- parameters: `id` (path, string, required)

### `DELETE /api/v1/evaluations/feedbacks`

Delete Feedbacks


### `DELETE /api/v1/evaluations/feedbacks/all`

Delete All Feedbacks


### `GET /api/v1/evaluations/feedbacks/all/export`

Export All Feedbacks

- parameters: `model_id` (query, string)

### `GET /api/v1/evaluations/feedbacks/all/ids`

Get All Feedback Ids


### `GET /api/v1/evaluations/feedbacks/list`

Get Feedbacks

- parameters: `order_by` (query, string), `direction` (query, string), `page` (query, integer), `model_id` (query, string)

### `GET /api/v1/evaluations/feedbacks/models`

Get Feedback Model Ids


### `GET /api/v1/evaluations/feedbacks/user`

Get User Feedbacks

- parameters: `page` (query, integer)

### `GET /api/v1/evaluations/leaderboard`

Get Leaderboard

- parameters: `query` (query, string)

### `GET /api/v1/evaluations/leaderboard/{model_id}/history`

Get Model History

- parameters: `model_id` (path, string, required), `days` (query, integer)
