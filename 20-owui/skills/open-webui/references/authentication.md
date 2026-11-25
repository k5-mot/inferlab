# Authentication and permissions

## How the key is provided

- Each Open WebUI user creates a personal API key in Open WebUI > Settings > Account > API Keys.
- The user registers it once in their own terminal with `owui-api login`.
- In Open Terminal, `owui-api login` sends the key to `owui-broker`, a local service running as a
  separate OS user. The broker stores the key where neither the user's shell nor the agent can
  read it, identifies the caller's OS user from the kernel socket table, and adds the key to
  Open WebUI requests. A key left in `~/.config/open-webui/api-key` by the old setup is moved to
  the broker and deleted by `owui-api login`.
- The broker also holds the LiteLLM key used by Pi, and calls only chat completions and the model list.
- Outside Open Terminal (other agent harnesses), `owui-api` falls back to `OWUI_API_KEY` or
  `~/.config/open-webui/api-key` (mode `600`). Do not set `OWUI_API_KEY` in shared configuration.

## What the server enforces

- Open WebUI ACLs: the key acts as the user who created it. Knowledge bases, notes, files
  and chats of other users are not visible unless shared.
- API key endpoint allowlist (`API_KEYS_ALLOWED_ENDPOINTS`): only the prefixes in
  `api-index.md` are reachable with an API key. Chat completions, terminals, automations,
  admin and auth APIs return 403.
- Admin-only endpoints still require an admin user.
- Tool servers (`owui-api tool`): the broker forwards only to servers that Open WebUI lists for
  the user in `GET /api/v1/tools/` (`server:<id>`), so tool server access grants apply.

## What this skill only asks you to do

- Confirm destructive operations with the user before using `OWUI_CONFIRM=yes`.
- Never reveal the key.

These are instructions, not security controls. Server-side controls above are the boundary.
