FROM node:24.16.0-bookworm-slim AS builder

WORKDIR /app

RUN corepack enable

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY tsconfig.json ./
COPY src ./src
RUN pnpm build \
    && pnpm prune --prod

FROM node:24.16.0-bookworm-slim AS application-base

ENV NODE_ENV=production \
    CONFIG_PATH=/app/config.yaml \
    PATH=/app/node_modules/.bin:${PATH}

WORKDIR /app

COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules

RUN mkdir -p /data/llmwiki/sources /data/llmwiki/wiki /data/llmwiki/.llmwiki /data/llmwiki/artifacts \
    && chown -R node:node /data/llmwiki

USER node

FROM application-base AS runtime

COPY --from=builder /app/dist/config.js ./dist/config.js
COPY --from=builder /app/dist/logger.js ./dist/logger.js
COPY --from=builder /app/dist/proxy.js ./dist/proxy.js
COPY --from=builder /app/dist/runtime.js ./dist/runtime.js
COPY --from=builder /app/dist/serve.js ./dist/serve.js
COPY --from=builder /app/dist/upstream.js ./dist/upstream.js
COPY --from=builder /app/dist/viewer-generation.js ./dist/viewer-generation.js
COPY --from=builder /app/dist/viewer-reload.js ./dist/viewer-reload.js
COPY --from=builder /app/dist/viewer.js ./dist/viewer.js

EXPOSE 8080

CMD ["node", "dist/runtime.js"]

FROM application-base AS ingester

COPY --from=builder /app/dist/config.js ./dist/config.js
COPY --from=builder /app/dist/couchdb-source.js ./dist/couchdb-source.js
COPY --from=builder /app/dist/llmwiki-client.js ./dist/llmwiki-client.js
COPY --from=builder /app/dist/logger.js ./dist/logger.js
COPY --from=builder /app/dist/main.js ./dist/main.js
COPY --from=builder /app/dist/scheduler.js ./dist/scheduler.js
COPY --from=builder /app/dist/source-adapter.js ./dist/source-adapter.js
COPY --from=builder /app/dist/upstream.js ./dist/upstream.js
COPY --from=builder /app/dist/viewer-generation.js ./dist/viewer-generation.js

CMD ["node", "dist/main.js"]
