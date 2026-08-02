ARG HERMES_AGENT_BASE_IMAGE=docker.io/nousresearch/hermes-agent:v2026.7.30
FROM ${HERMES_AGENT_BASE_IMAGE}

ARG HERMES_AGENT_UID=1000
ARG HERMES_AGENT_GID=1000

RUN set -eux; \
    groupmod -o -g "${HERMES_AGENT_GID}" hermes; \
    usermod -o -u "${HERMES_AGENT_UID}" -g "${HERMES_AGENT_GID}" hermes
