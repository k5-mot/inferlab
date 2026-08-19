"""BookStack publish mappingとidempotent updateを検証する。"""

from __future__ import annotations

from pathlib import Path

import httpx
import yaml

from llm_wiki_platform.config import AppConfig
from llm_wiki_platform.connectors.base import RetryingHttpClient
from llm_wiki_platform.publisher import BookStackPublisher
from llm_wiki_platform.state import StateStore


def _publisher_config(tmp_path: Path) -> AppConfig:
    """publishを有効化したtest用AppConfigを作成する。

    Args:
        tmp_path: test固有directory。

    Returns:
        schema検証済みAppConfig。
    """
    source_path = Path(__file__).parents[1] / "config.yaml"
    loaded = yaml.safe_load(source_path.read_text(encoding="utf-8"))
    assert isinstance(loaded, dict)
    loaded["storage"] = {
        "source_store_path": str(tmp_path / "source"),
        "state_database_path": str(tmp_path / "state.db"),
    }
    loaded["bookstack"]["base_url"] = "http://bookstack.test"
    loaded["pipeline"]["publish"]["enabled"] = True
    return AppConfig.model_validate(loaded)


async def test_publish_creates_mapping_then_skips_unchanged_page(tmp_path: Path) -> None:
    """stable OpenKB IDで初回createと2回目unchangedを判定することを検証する。"""
    config = _publisher_config(tmp_path)
    wiki_path = tmp_path / "wiki"
    concept_path = wiki_path / "concepts"
    concept_path.mkdir(parents=True)
    (concept_path / "access-token.md").write_text(
        "---\ntitle: Access Token\n---\n# Access Token\n\nRelated to [[Session]].\n",
        encoding="utf-8",
    )
    state_store = StateStore(tmp_path / "state.db")
    requests: list[tuple[str, str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        """BookStack endpointごとのtest responseを返す。

        Args:
            request: MockTransportが受け取ったrequest。

        Returns:
            endpointに対応するHTTP response。
        """
        requests.append((request.method, request.url.path))
        if request.method == "GET" and request.url.path == "/api/shelves":
            return httpx.Response(200, json={"data": [{"id": 1, "name": "LLM Wiki"}]})
        if request.method == "GET" and request.url.path == "/api/shelves/1":
            return httpx.Response(200, json={"id": 1, "name": "LLM Wiki", "books": []})
        if request.method == "GET" and request.url.path == "/api/books":
            return httpx.Response(200, json={"data": [{"id": 10, "name": "Concepts"}]})
        if request.method == "POST" and request.url.path == "/api/pages":
            return httpx.Response(
                200,
                json={
                    "id": 100,
                    "name": "Access Token",
                    "url": "http://bookstack.test/books/concepts/page/access-token",
                },
            )
        if request.method == "GET" and request.url.path == "/api/pages/100":
            return httpx.Response(
                200,
                json={
                    "id": 100,
                    "name": "Access Token",
                    "markdown": "# Access Token",
                    "url": "http://bookstack.test/books/concepts/page/access-token",
                },
            )
        if request.method == "PUT":
            return httpx.Response(200, json={"ok": True})
        return httpx.Response(404)

    async with httpx.AsyncClient(
        base_url="http://bookstack.test", transport=httpx.MockTransport(handler)
    ) as client:
        retrying = RetryingHttpClient(
            client, config.defaults.ingest.retry, config.defaults.ingest.rate_limit
        )
        publisher = BookStackPublisher(
            config.bookstack,
            config.pipeline.publish,
            wiki_path,
            state_store,
            retrying,
        )
        first = await publisher.publish()
        second = await publisher.publish()

    assert first.created == 1
    assert second.unchanged == 1
    mapping = state_store.get_publish_mapping("concepts/access-token.md")
    assert mapping is not None
    assert mapping["bookstack_page_id"] == 100
    assert requests.count(("POST", "/api/pages")) == 1
    assert requests.count(("PUT", "/api/pages/100")) == 1
