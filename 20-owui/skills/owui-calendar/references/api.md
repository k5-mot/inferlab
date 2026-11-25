# owui-calendar API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/calendars/`

Get Calendars


### `POST /api/v1/calendars/create`

Create Calendar

- body (application/json): `access_grants`: array<object>, `color`: string, `data`: object, `meta`: object, `name`*: string

### `GET /api/v1/calendars/events`

Get Events

- parameters: `start` (query, string, required), `end` (query, string, required), `calendar_ids` (query, string)

### `POST /api/v1/calendars/events/create`

Create Event

- body (application/json): `all_day`: boolean, `attendees`: array<object>, `calendar_id`*: string, `color`: string, `data`: object, `description`: string, `end_at`: integer, `location`: string, `meta`: object, `rrule`: string, `start_at`*: integer, `title`*: string

### `GET /api/v1/calendars/events/search`

Search Events

- parameters: `query` (query, string), `skip` (query, integer), `limit` (query, integer)

### `GET /api/v1/calendars/events/{event_id}`

Get Event

- parameters: `event_id` (path, string, required)

### `DELETE /api/v1/calendars/events/{event_id}/delete`

Delete Event

- parameters: `event_id` (path, string, required)

### `POST /api/v1/calendars/events/{event_id}/rsvp`

Rsvp Event

- parameters: `event_id` (path, string, required)
- body (application/json): `status`*: string

### `POST /api/v1/calendars/events/{event_id}/update`

Update Event

- parameters: `event_id` (path, string, required)
- body (application/json): `all_day`: boolean, `attendees`: array<object>, `calendar_id`: string, `color`: string, `data`: object, `description`: string, `end_at`: integer, `is_cancelled`: boolean, `location`: string, `meta`: object, `rrule`: string, `start_at`: integer, `title`: string

### `GET /api/v1/calendars/{calendar_id}`

Get Calendar By Id

- parameters: `calendar_id` (path, string, required)

### `POST /api/v1/calendars/{calendar_id}/access/update`

Update Calendar Access By Id

- parameters: `calendar_id` (path, string, required)
- body (application/json): `access_grants`*: array<object>

### `POST /api/v1/calendars/{calendar_id}/default`

Set Default Calendar

- parameters: `calendar_id` (path, string, required)

### `DELETE /api/v1/calendars/{calendar_id}/delete`

Delete Calendar

- parameters: `calendar_id` (path, string, required)

### `POST /api/v1/calendars/{calendar_id}/update`

Update Calendar

- parameters: `calendar_id` (path, string, required)
- body (application/json): `color`: string, `data`: object, `meta`: object, `name`: string
