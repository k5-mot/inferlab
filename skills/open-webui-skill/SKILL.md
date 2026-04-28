---
name: open-webui-skill
description: Operate Open WebUI Channels, messages, threads, and files using OPEN_WEBUI_API_KEY.
version: 1.0.0
author: inferlab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Open WebUI, Channels, Files, Messaging]
required_environment_variables:
  - name: OPEN_WEBUI_BASE_URL
    prompt: Open WebUI base URL
    help: Base URL such as http://open-webui:8080
    required_for: Open WebUI API access
  - name: OPEN_WEBUI_API_KEY
    prompt: Open WebUI bot API key
    help: Use a bot user API key. Do not put the key in cron prompts or logs.
    required_for: Open WebUI API access
---
# open-webui-skill

## Purpose

Use this skill to operate Open WebUI Channels with the bot user configured by `OPEN_WEBUI_API_KEY`.

Capabilities:

- List channels visible to the bot user.
- Resolve `#channel-name` or a plain channel name to a channel ID.
- Fetch channel metadata.
- Fetch channel messages, regardless of whether they were written by AI or humans.
- Fetch message threads.
- Fetch file metadata and extracted file content.
- Post Markdown messages to a channel.

## Commands

List and resolve:

```bash
python3 /opt/inferlab/skills/open-webui-skill/client.py list-channels
python3 /opt/inferlab/skills/open-webui-skill/client.py resolve-channel --channel report
```

Fetch channel messages:

```bash
python3 /opt/inferlab/skills/open-webui-skill/client.py messages \
  --channel report \
  --limit 100 \
  --include-threads
```

Fetch file content:

```bash
python3 /opt/inferlab/skills/open-webui-skill/client.py file-content --file-id "<file_id>"
```

Post to Channels:

```bash
python3 /opt/inferlab/skills/open-webui-skill/client.py post \
  --channel report \
  --content "## Report\n\nBody"
```

## Rules

- Never include `OPEN_WEBUI_API_KEY` in prompts, output, or saved cron definitions.
- Do not use `--dry-run` for scheduled posting unless the user explicitly asks for preview only.
- For live posting, inspect command JSON. `"ok": true` means the API accepted the post. `"ok": false` means no post happened.
- Prefer explicit channel names or IDs. `report` and `#report` are both accepted.
- If file content is needed, first inspect message `data.files[*].id`, then call `file-content`.

## Composition

- For activity reports: fetch messages with this skill, summarize with `llm-activity-report-skill`, then post with this skill.
- For technology news: collect sources with web/search, format with `tech-news-report-skill`, then post with this skill.
