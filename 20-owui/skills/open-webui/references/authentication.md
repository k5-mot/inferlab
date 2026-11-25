# Authentication and permissions

## How the key is provided

- Each Open WebUI user creates a personal API key in Open WebUI > Settings > Account > API Keys.
- The user stores it once in their own terminal home with `owui-api login`.
  The key is saved to `~/.config/open-webui/api-key` with mode `600`.
- Open Terminal runs each Open WebUI user as a separate OS user, so other users cannot read the file.
- `OWUI_API_KEY` (environment) overrides the file. Do not set it in shared configuration.

## What the server enforces

- Open WebUI ACLs: the key acts as the user who created it. Knowledge bases, notes, files
  and chats of other users are not visible unless shared.
- API key endpoint allowlist (`API_KEYS_ALLOWED_ENDPOINTS`): only the prefixes in
  `api-index.md` are reachable with an API key. Chat completions, terminals, automations,
  admin and auth APIs return 403.
- Admin-only endpoints still require an admin user.

## What this skill only asks you to do

- Confirm destructive operations with the user before using `OWUI_CONFIRM=yes`.
- Never reveal the key.

These are instructions, not security controls. Server-side controls above are the boundary.
