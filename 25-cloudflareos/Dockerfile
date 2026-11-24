FROM docker.io/library/node:24.22.3-bookworm-slim

ARG CLOUDFLARE_OS_REF=df04e239ed85376643c586a7329d3b8604df489e

ENV CI=1 \
    PNPM_HOME=/pnpm \
    PATH=/pnpm:${PATH}

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates git procps \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global pnpm@11.17.0 \
    && mkdir -p /workspace

WORKDIR /workspace

RUN git init . \
    && git remote add origin https://github.com/cloudflare/cloudflare-os.git \
    && git fetch --depth=1 origin "${CLOUDFLARE_OS_REF}" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${CLOUDFLARE_OS_REF}" \
    && rm -rf .git

COPY cloudflare-os-litellm.patch /tmp/cloudflare-os-litellm.patch

RUN git apply --unidiff-zero --check /tmp/cloudflare-os-litellm.patch \
    && git apply --unidiff-zero /tmp/cloudflare-os-litellm.patch \
    && rm /tmp/cloudflare-os-litellm.patch \
    && pnpm install --frozen-lockfile

EXPOSE 8787

CMD ["pnpm", "run-local"]
