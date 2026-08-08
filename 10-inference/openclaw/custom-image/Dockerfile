ARG OPENCLAW_BASE_IMAGE=ghcr.io/openclaw/openclaw:2026.7.1-browser
FROM ghcr.io/astral-sh/uv:0.12.0 AS uv-bin
FROM ${OPENCLAW_BASE_IMAGE}

USER root

# MCPサーバーをHermes Agentと同じuvx形式で起動できるよう、uv実行ファイルだけを追加する。
COPY --from=uv-bin /uv /uvx /usr/local/bin/

# 設定テンプレートを実行時の永続領域へ反映するため、起動補助をimageへ同梱する。
COPY --chown=node:node openclaw-entrypoint.sh /usr/local/bin/openclaw-entrypoint.sh
COPY --chown=node:node openclaw.template.json openclaw.schema.json /usr/local/share/openclaw/

# openclaw.template.jsonを起動時に展開するため、最小packageだけ追加する。
RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && chmod 0555 /usr/local/bin/openclaw-entrypoint.sh \
    && mkdir -p /home/node/.openclaw /usr/local/share/openclaw \
    && chown -R node:node /home/node/.openclaw /usr/local/share/openclaw

USER node

# named volumeの初回作成時にDockerがimage側の中身をコピーできるよう、標準のstate directoryへpluginを入れる。
RUN OPENCLAW_HOME=/home/node \
    HOME=/home/node \
    node dist/index.js plugins install @openclaw/discord@2026.7.1

# docker-compose側でcommandを上書きしなくても、標準でgatewayを起動する。
ENTRYPOINT ["tini", "-s", "--", "/usr/local/bin/openclaw-entrypoint.sh"]
CMD ["node", "dist/index.js", "gateway"]
