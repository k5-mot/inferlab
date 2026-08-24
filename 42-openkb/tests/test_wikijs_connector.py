"""Wiki.js Human Wiki ConnectorのGraphQL境界を検証する。"""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import yaml

from llm_wiki_platform.config import AppConfig
from llm_wiki_platform.connectors.base import RetryingHttpClient
from llm_wiki_platform.connectors.wikijs import WikiJSConnector
from llm_wiki_platform.models import Authority


def _config() -> AppConfig:
    """repository設定からWiki.js Connector用AppConfigを作成する。

    Returns:
        schema検証済みAppConfig。
    """
    source_path = Path(__file__).parents[1] / "config.yaml"
    loaded = yaml.safe_load(source_path.read_text(encoding="utf-8"))
    assert isinstance(loaded, dict)
    loaded["wikijs"]["base_url"] = "http://wikijs.test"
    return AppConfig.model_validate(loaded)


async def test_connector_reads_only_human_wiki_path() -> None:
    """Human Wiki path配下だけを発見しauthoritative文書へ正規化することを検証する。"""
    config = _config()
    operations: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        """Wiki.js GraphQL operationに対応するtest responseを返す。

        Args:
            request: MockTransportが受け取ったrequest。

        Returns:
            operationに対応するGraphQL response。
        """
        assert request.url.path == "/graphql"
        body = json.loads(request.content)
        operations.append(body["operationName"])
        if body["operationName"] == "ListPages":
            assert body["variables"] == {"locale": "en"}
            return httpx.Response(
                200,
                json={
                    "data": {
                        "pages": {
                            "list": [
                                {
                                    "id": 11,
                                    "path": "human/architecture",
                                    "locale": "en",
                                    "title": "Architecture",
                                    "description": "System architecture",
                                    "contentType": "markdown",
                                    "isPublished": True,
                                    "isPrivate": False,
                                    "createdAt": "2026-08-01T00:00:00.000Z",
                                    "updatedAt": "2026-08-20T01:02:03.000Z",
                                    "tags": ["design"],
                                },
                                {
                                    "id": 12,
                                    "path": "llm/generated",
                                    "locale": "en",
                                    "title": "Generated",
                                    "description": "",
                                    "contentType": "markdown",
                                    "isPublished": True,
                                    "isPrivate": False,
                                    "createdAt": "2026-08-01T00:00:00.000Z",
                                    "updatedAt": "2026-08-20T01:02:04.000Z",
                                    "tags": [],
                                },
                            ]
                        }
                    }
                },
            )
        assert body["operationName"] == "GetPage"
        assert body["variables"] == {"id": 11}
        return httpx.Response(
            200,
            json={
                "data": {
                    "pages": {
                        "single": {
                            "id": 11,
                            "path": "human/architecture",
                            "locale": "en",
                            "title": "Architecture",
                            "description": "System architecture",
                            "content": "# Architecture\n\nCanonical design.",
                            "contentType": "markdown",
                            "createdAt": "2026-08-01T00:00:00.000Z",
                            "updatedAt": "2026-08-20T01:02:03.000Z",
                            "authorName": "Platform Team",
                            "tags": [{"tag": "design"}],
                        }
                    }
                }
            },
        )

    async with httpx.AsyncClient(
        base_url="http://wikijs.test", transport=httpx.MockTransport(handler)
    ) as client:
        retrying = RetryingHttpClient(
            client, config.defaults.ingest.retry, config.defaults.ingest.rate_limit
        )
        connector = WikiJSConnector(config.wikijs, retrying)
        batch = await connector.discover(None)
        raw = await connector.fetch(batch.objects[0])
        document = connector.normalize(batch.objects[0], raw)

    assert len(batch.objects) == 1
    assert batch.complete_snapshot is True
    assert document.id == "wikijs:human-wiki:page:11"
    assert document.content == "# Architecture\n\nCanonical design."
    assert document.url == "http://wikijs.test/en/human/architecture"
    assert document.authority is Authority.AUTHORITATIVE
    assert document.scope == {"type": "path", "id": "en/human"}
    assert connector.checkpoint(batch.objects, None) == "2026-08-20T01:02:03+00:00"
    assert operations == ["ListPages", "GetPage"]
