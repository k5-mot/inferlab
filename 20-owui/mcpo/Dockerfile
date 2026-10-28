FROM ghcr.io/open-webui/open-terminal:0.14.5 AS docker-cli

FROM ghcr.io/open-webui/mcpo:main

# llmwikiのstdio MCPへ接続するため、配布済みイメージからDocker CLIだけを再利用する。
COPY --from=docker-cli /usr/bin/docker /usr/bin/docker
