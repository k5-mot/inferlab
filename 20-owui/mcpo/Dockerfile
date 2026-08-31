FROM ghcr.io/open-webui/open-terminal:0.12.3 AS docker-cli

FROM ghcr.io/open-webui/mcpo:main

# llmwikiのstdio MCPへ接続するため、配布済みイメージからDocker CLIだけを再利用する。
COPY --from=docker-cli /usr/bin/docker /usr/bin/docker
