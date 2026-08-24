"""Wiki.js publish mappingとidempotent updateを検証する。"""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import yaml

from llm_wiki_platform.config import AppConfig
from llm_wiki_platform.connectors.base import RetryingHttpClient
from llm_wiki_platform.state import StateStore
from llm_wiki_platform.wikijs_publisher import WikiJSPublisher


def _publisher_config(tmp_path: Path) -> AppConfig:
    """Wiki.js publishを有効化したtest用AppConfigを作成する。

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
    loaded["wikijs"]["base_url"] = "http://wikijs.test"
    loaded["pipeline"]["publish"]["enabled"] = True
    loaded["pipeline"]["publish"]["targets"] = ["wikijs"]
    return AppConfig.model_validate(loaded)


async def test_publish_creates_pages_converts_links_and_skips_unchanged(
    tmp_path: Path,
) -> None:
    """path対応でpageを作成しwikilink変換後の再公開を省略することを検証する。"""
    config = _publisher_config(tmp_path)
    wiki_path = tmp_path / "wiki"
    (wiki_path / "concepts").mkdir(parents=True)
    (wiki_path / "systems").mkdir(parents=True)
    (wiki_path / "concepts" / "access-token.md").write_text(
        "---\ntitle: Access Token\n---\n# Access Token\n\nRelated to [[Session]].\n",
        encoding="utf-8",
    )
    (wiki_path / "systems" / "session.md").write_text(
        "---\ntitle: Session\n---\n# Session\n\nSession details.\n",
        encoding="utf-8",
    )
    state_store = StateStore(tmp_path / "state.db")
    remote_pages: dict[str, dict[str, object]] = {}
    created_variables: list[dict[str, object]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        """Wiki.js publish operationごとのtest responseを返す。

        Args:
            request: MockTransportが受け取ったrequest。

        Returns:
            operationに対応するGraphQL response。
        """
        body = json.loads(request.content)
        operation = body["operationName"]
        if operation == "ListPages":
            return httpx.Response(
                200,
                json={"data": {"pages": {"list": list(remote_pages.values())}}},
            )
        assert operation == "CreatePage"
        variables = body["variables"]
        created_variables.append(variables)
        page_id = len(remote_pages) + 101
        page = {
            "id": page_id,
            "path": variables["path"],
            "locale": variables["locale"],
            "title": variables["title"],
            "updatedAt": "2026-08-20T01:02:03.000Z",
        }
        remote_pages[str(variables["path"])] = page
        return httpx.Response(
            200,
            json={
                "data": {
                    "pages": {
                        "create": {
                            "responseResult": {
                                "succeeded": True,
                                "errorCode": 0,
                                "slug": "ok",
                                "message": "Page created successfully.",
                            },
                            "page": page,
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
        publisher = WikiJSPublisher(
            config.wikijs,
            config.pipeline.publish,
            wiki_path,
            state_store,
            retrying,
        )
        first = await publisher.publish()
        second = await publisher.publish()

    assert first.created == 2
    assert second.unchanged == 2
    access_token = next(
        item for item in created_variables if item["path"] == "llm/concepts/access-token"
    )
    assert access_token["content"] == (
        "# Access Token\n\nRelated to [Session](/en/llm/systems/session).\n"
    )
    mapping = state_store.get_wikijs_publish_mapping("concepts/access-token.md")
    assert mapping is not None
    assert mapping["wikijs_path"] == "llm/concepts/access-token"
    assert len(created_variables) == 2
