FROM node:24.16.0-bookworm-slim AS builder

WORKDIR /app

RUN corepack enable

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY tsconfig.json ./
COPY src ./src
RUN pnpm build \
    && pnpm prune --prod

FROM node:24.16.0-bookworm-slim

ENV NODE_ENV=production \
    CONFIG_PATH=/app/config.yaml \
    PATH=/app/node_modules/.bin:${PATH}

WORKDIR /app

COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist

RUN mkdir -p /data/llmwiki/sources /data/llmwiki/wiki /data/llmwiki/.llmwiki /data/llmwiki/artifacts \
    && chown -R node:node /data/llmwiki

USER node

CMD ["node", "dist/main.js"]
