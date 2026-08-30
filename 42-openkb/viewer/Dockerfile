FROM docker.io/library/node:24.20.0-bookworm-slim AS builder

WORKDIR /app

RUN corepack enable

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

COPY tsconfig.json ./
COPY src ./src
COPY static ./static
RUN pnpm build \
    && pnpm prune --prod

FROM docker.io/library/node:24.20.0-bookworm-slim

ENV NODE_ENV=production \
    CONFIG_PATH=/app/config.yaml \
    PATH=/app/node_modules/.bin:${PATH}

WORKDIR /app

COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/static ./static

RUN mkdir -p /data/mintlify \
    && chown -R node:node /data/mintlify

USER node

EXPOSE 8080

CMD ["node", "dist/main.js"]
