FROM debian:trixie-slim

ARG TARGETARCH
ARG LLM_WIKI_VERSION=v0.5.5

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl git netcat-openbsd tar \
    && rm -rf /var/lib/apt/lists/* \
    && case "${TARGETARCH}" in \
      amd64) llm_wiki_target="x86_64-unknown-linux-gnu" ;; \
      arm64) llm_wiki_target="aarch64-unknown-linux-gnu" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/geronimo-iia/llm-wiki/releases/download/${LLM_WIKI_VERSION}/${llm_wiki_target}.tar.gz" -o /tmp/llm-wiki.tar.gz \
    && tar -xzf /tmp/llm-wiki.tar.gz -C /usr/local/bin llm-wiki \
    && chmod 0755 /usr/local/bin/llm-wiki \
    && rm /tmp/llm-wiki.tar.gz

COPY entrypoint.sh /usr/local/bin/llm-wiki-entrypoint.sh

RUN chmod 0755 /usr/local/bin/llm-wiki-entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/llm-wiki-entrypoint.sh"]
