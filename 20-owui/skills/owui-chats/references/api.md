# owui-chats API reference

Open WebUI v0.13.4のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。

`*`は必須field。pathの`{id}`などは実際の値へ置き換える。

### `GET /api/v1/chats/`

Get Session User Chat List

- parameters: `page` (query, integer), `include_pinned` (query, boolean), `include_folders` (query, boolean), `sort_by` (query, string), `sort_dir` (query, string)

### `DELETE /api/v1/chats/`

Delete All User Chats


### `GET /api/v1/chats/all`

Get User Chats


### `GET /api/v1/chats/all/archived`

Get User Archived Chats


### `GET /api/v1/chats/all/db`

Get All User Chats In Db


### `GET /api/v1/chats/all/tags`

Get All User Tags


### `POST /api/v1/chats/archive/all`

Archive All Chats


### `GET /api/v1/chats/archived`

Get Archived Session User Chat List

- parameters: `page` (query, integer), `query` (query, string), `order_by` (query, string), `direction` (query, string)

### `GET /api/v1/chats/archived/count`

Get Archived Session User Chat Count


### `GET /api/v1/chats/config`

Get Chat Config


### `POST /api/v1/chats/config`

Set Chat Config

- body (application/json): `CONTEXT_COMPACTION_MODEL`: string, `CONTEXT_COMPACTION_PROMPT_TEMPLATE`*: string, `CONTEXT_COMPACTION_RETENTION_PERCENTAGE`: integer, `CONTEXT_COMPACTION_TOKEN_CAP`: integer, `CONTEXT_COMPACTION_TOKEN_THRESHOLD`: integer, `ENABLE_CONTEXT_COMPACTION`*: boolean, `ENABLE_TOOL_CALL_LABELS`: boolean, `ENABLE_TOOL_PERMISSIONS`: boolean, `ENABLE_TOOL_PERMISSIONS_AUTO`: boolean, `ENABLE_TOOL_SEARCH`: boolean, `TOOL_PERMISSIONS_AUTO_DECISIONS_API_BASE_URL`: string, `TOOL_PERMISSIONS_AUTO_DECISIONS_API_KEY`: string, `TOOL_PERMISSIONS_AUTO_DECISIONS_MODEL`: string, `TOOL_PERMISSIONS_AUTO_DECISIONS_THRESHOLD`: number, `TOOL_PERMISSIONS_AUTO_ENGINE`: string, `TOOL_PERMISSIONS_AUTO_PROMPT`: string, `TOOL_SEARCH_ALWAYS_LOADED`: array<string>, `TOOL_SEARCH_DECISIONS_API_BASE_URL`: string, `TOOL_SEARCH_DECISIONS_API_KEY`: string, `TOOL_SEARCH_DECISIONS_MODEL`: string, `TOOL_SEARCH_DECISIONS_PROMPT`: string, `TOOL_SEARCH_DECISIONS_THRESHOLD`: number, `TOOL_SEARCH_DEFER_BUILTIN_TOOLS`: boolean, `TOOL_SEARCH_DEFER_THRESHOLD`: integer, `TOOL_SEARCH_ENGINE`: string, `VISUALIZATION_PROMPT_TEMPLATE`: string

### `GET /api/v1/chats/folder/{folder_id}`

Get Chats By Folder Id

- parameters: `folder_id` (path, string, required)

### `GET /api/v1/chats/folder/{folder_id}/list`

Get Chat List By Folder Id

- parameters: `folder_id` (path, string, required), `page` (query, integer), `sort_by` (query, string), `sort_dir` (query, string)

### `POST /api/v1/chats/import`

Import Chats

- body (application/json): `chats`*: array<ChatImportForm>

### `GET /api/v1/chats/list`

Get Session User Chat List

- parameters: `page` (query, integer), `include_pinned` (query, boolean), `include_folders` (query, boolean), `sort_by` (query, string), `sort_dir` (query, string)

### `GET /api/v1/chats/list/user/{user_id}`

Get User Chat List By User Id

- parameters: `user_id` (path, string, required), `page` (query, integer), `query` (query, string), `order_by` (query, string), `direction` (query, string)

### `POST /api/v1/chats/new`

Create New Chat

- body (application/json): `chat`*: object, `folder_id`: string, `variables`: object

### `GET /api/v1/chats/pinned`

Get User Pinned Chats


### `POST /api/v1/chats/read`

Mark Chats Read By User Id


### `GET /api/v1/chats/search`

Search User Chats

- parameters: `text` (query, string, required), `page` (query, integer)

### `DELETE /api/v1/chats/share/all`

Unshare All Chats


### `GET /api/v1/chats/share/{share_id}`

Get Shared Chat By Id

- parameters: `share_id` (path, string, required)

### `GET /api/v1/chats/shared`

Get Shared Session User Chat List

- parameters: `page` (query, integer), `query` (query, string), `order_by` (query, string), `direction` (query, string)

### `GET /api/v1/chats/shared/{id}/access`

Get Shared Chat Access By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/chats/shared/{id}/access/update`

Update Shared Chat Access By Id

- parameters: `id` (path, string, required)
- body (application/json): `access_grants`*: array<object>, `share_mode`: string

### `GET /api/v1/chats/stats/export`

Export Chat Stats

- parameters: `updated_at` (query, integer), `page` (query, integer), `stream` (query, boolean)

### `GET /api/v1/chats/stats/export/{chat_id}`

Export Single Chat Stats

- parameters: `chat_id` (path, string, required)

### `GET /api/v1/chats/stats/usage`

Get Session User Chat Usage Stats

- parameters: `items_per_page` (query, integer), `page` (query, integer)

### `POST /api/v1/chats/tags`

Get User Chat List By Tag Name

- body (application/json): `limit`: integer, `name`*: string, `skip`: integer

### `POST /api/v1/chats/unarchive/all`

Unarchive All Chats


### `GET /api/v1/chats/{id}`

Get Chat By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/chats/{id}`

Update Chat By Id

- parameters: `id` (path, string, required)
- body (application/json): `chat`*: object, `folder_id`: string, `variables`: object

### `DELETE /api/v1/chats/{id}`

Delete Chat By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/chats/{id}/archive`

Archive Chat By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/chats/{id}/clone`

Clone Chat By Id

- parameters: `id` (path, string, required)
- body (application/json): `title`: string

### `POST /api/v1/chats/{id}/clone/shared`

Clone Shared Chat By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/chats/{id}/compact`

Compact Chat By Id

- parameters: `id` (path, string, required)
- body (application/json): CompactChatForm

### `POST /api/v1/chats/{id}/folder`

Update Chat Folder Id By Id

- parameters: `id` (path, string, required)
- body (application/json): `folder_id`: string

### `POST /api/v1/chats/{id}/fork`

Fork Chat By Id

- parameters: `id` (path, string, required)
- body (application/json): ForkForm

### `POST /api/v1/chats/{id}/messages/{message_id}`

Update Chat Message By Id

- parameters: `id` (path, string, required), `message_id` (path, string, required)
- body (application/json): `content`: string, `voice`: object

### `DELETE /api/v1/chats/{id}/messages/{message_id}`

Delete Chat Message By Id

- parameters: `id` (path, string, required), `message_id` (path, string, required)

### `POST /api/v1/chats/{id}/messages/{message_id}/event`

Send Chat Message Event By Id

- parameters: `id` (path, string, required), `message_id` (path, string, required)
- body (application/json): `data`*: object, `type`*: string

### `POST /api/v1/chats/{id}/messages/{message_id}/resolve`

Resolve Chat Message Tool Call

- parameters: `id` (path, string, required), `message_id` (path, string, required)
- body (application/json): `action`*: string, `answers`: any, `call_id`*: string, `timed_out`: boolean

### `PATCH /api/v1/chats/{id}/params`

Update Chat Params

- parameters: `id` (path, string, required)
- body (application/json): object

### `POST /api/v1/chats/{id}/pin`

Pin Chat By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/chats/{id}/pinned`

Get Pinned Status By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/chats/{id}/search/snippet`

Get Chat Search Snippet

- parameters: `id` (path, string, required), `text` (query, string, required)

### `POST /api/v1/chats/{id}/share`

Share Chat By Id

- parameters: `id` (path, string, required)
- body (application/json): ShareChatForm

### `DELETE /api/v1/chats/{id}/share`

Delete Shared Chat By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/chats/{id}/tags`

Get Chat Tags By Id

- parameters: `id` (path, string, required)

### `POST /api/v1/chats/{id}/tags`

Add Tag By Id And Tag Name

- parameters: `id` (path, string, required)
- body (application/json): `name`*: string

### `PATCH /api/v1/chats/{id}/tags`

Update Chat Tag Color

- parameters: `id` (path, string, required)
- body (application/json): `color`*: string, `name`*: string

### `DELETE /api/v1/chats/{id}/tags`

Delete Tag By Id And Tag Name

- parameters: `id` (path, string, required)
- body (application/json): `name`*: string

### `POST /api/v1/chats/{id}/unread`

Mark Chat Unread By Id

- parameters: `id` (path, string, required)

### `GET /api/v1/chats/{id}/view`

Get Chat View

- parameters: `id` (path, string, required)

### `POST /api/v1/chats/{id}/view`

Update Chat View

- parameters: `id` (path, string, required)
