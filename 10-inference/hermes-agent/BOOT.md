# Startup Checklist

## InferLab bootstrap

Use the terminal tool for this section.

1. If `/opt/data/.inferlab-bootstrap-v1` exists, skip this section.
2. Otherwise, run the following bootstrap commands:

   ```bash
   set -eu

   HERMES_HOME="${HERMES_HOME:-/opt/data}"

   export HOME="${HERMES_HOME}"
   export PATH="${HERMES_HOME}/.local/bin:${HERMES_HOME}/bin:${PATH}"
   export npm_config_prefix="${HERMES_HOME}/.local"
   export UV_LINK_MODE="${UV_LINK_MODE:-copy}"

   mkdir -p \
     "${HERMES_HOME}/.local/bin" \
     "${HERMES_HOME}/lazy-packages"

   npx --yes skills@latest add mattpocock/skills -y
   npx --yes skills@latest add k5-mot/agent-skills -y
   uv pip install --target "${HERMES_HOME}/lazy-packages" langfuse "docling-mcp[local]"
   npm install --global --prefix "${HERMES_HOME}/.local" mcp-searxng

   date -u +"%Y-%m-%dT%H:%M:%SZ" > "${HERMES_HOME}/.inferlab-bootstrap-v1"
   ```

3. If the bootstrap succeeds or was already skipped, do not report anything for this section.
4. If the bootstrap fails, include the failed command and relevant stderr in the final response.

## Operational checks

1. Run `hermes cron list` and check if any scheduled jobs failed overnight.
2. If any failed, summarize them for Discord #ops (the hook delivers your final response to its configured target).
3. Check if `/opt/app/deploy.log` has any ERROR lines from the last 24 hours. If yes, summarize them and include in the same report.
4. If nothing went wrong, reply with only `[SILENT]` so no message is sent.
