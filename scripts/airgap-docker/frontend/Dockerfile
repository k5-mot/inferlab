FROM node:20-alpine

WORKDIR /app

COPY npm/ /opt/airgap/npm/
COPY package.json package-lock.json ./

RUN mkdir -p /opt/airgap/npm-cache \
    && for archive in /opt/airgap/npm/*.tgz; do \
        npm cache add --cache=/opt/airgap/npm-cache "$archive"; \
    done \
    && npm ci --offline --cache=/opt/airgap/npm-cache

COPY .gitignore index.html tsconfig.json vite.config.ts ./
COPY src/ src/

RUN npm exec --offline -- vp check \
    && npm exec --offline -- vp build \
    && test -f dist/index.html

CMD ["npm", "exec", "--offline", "--", "vp", "preview", "--host", "0.0.0.0"]
