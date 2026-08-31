FROM docker.io/library/python:3.12.14-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY pyproject.toml README.md ./
COPY src ./src

RUN pip install --no-cache-dir . \
    && useradd --create-home --uid 1000 llm-wiki \
    && mkdir -p /data/knowledge-source \
    && chown -R llm-wiki:llm-wiki /data/knowledge-source

USER llm-wiki

EXPOSE 8080

CMD ["llm-wiki-api", "--config", "/app/config.yaml", "--host", "0.0.0.0", "--port", "8080"]
