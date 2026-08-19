"""起動済みBookStackに対するPublisher integration test。"""

from __future__ import annotations

import os
from pathlib import Path

import httpx
import pytest
import yaml

from llm_wiki_platform.config import AppConfig
from llm_wiki_platform.connectors.base import RetryingHttpClient
from llm_wiki_platform.publisher import BookStackPublisher
from llm_wiki_platform.state import StateStore


def _integration_credentials() -> tuple[str, str, str, str]:
    """integration test用BookStack接続情報を環境変数から取得する。

    Returns:
        base URL、token ID、token secret、artifact名suffix。

    Raises:
        pytest.skip: 必須環境変数が不足している場合。
    """
    base_url = os.environ.get("BOOKSTACK_INTEGRATION_BASE_URL", "")
    token_id = os.environ.get("BOOKSTACK_INTEGRATION_TOKEN_ID", "")
    token_secret = os.environ.get("BOOKSTACK_INTEGRATION_TOKEN_SECRET", "")
    suffix = os.environ.get("BOOKSTACK_INTEGRATION_SUFFIX", "")
    if not all((base_url, token_id, token_secret, suffix)):
        pytest.skip("BookStack integration test用環境変数が設定されていません")
    return base_url, token_id, token_secret, suffix


def _integration_config(
    tmp_path: Path,
    base_url: str,
    shelf_name: str,
    concept_book_name: str,
    system_book_name: str,
) -> AppConfig:
    """integration test専用のBookStack destination設定を構築する。

    Args:
        tmp_path: test固有のstate保存先。
        base_url: BookStack API base URL。
        shelf_name: 検証用shelf名。
        concept_book_name: concepts categoryのbook名。
        system_book_name: systems categoryのbook名。

    Returns:
        schema検証済みAppConfig。
    """
    source_path = Path(__file__).parents[2] / "config.yaml"
    loaded = yaml.safe_load(source_path.read_text(encoding="utf-8"))
    assert isinstance(loaded, dict)
    loaded["storage"] = {
        "source_store_path": str(tmp_path / "source"),
        "state_database_path": str(tmp_path / "state.db"),
    }
    loaded["defaults"]["ingest"]["rate_limit"]["requests_per_minute"] = 6000
    loaded["bookstack"]["base_url"] = base_url
    loaded["bookstack"]["llm_wiki"]["shelf"] = shelf_name
    loaded["bookstack"]["llm_wiki"]["books"]["concepts"] = concept_book_name
    loaded["bookstack"]["llm_wiki"]["books"]["systems"] = system_book_name
    loaded["pipeline"]["publish"]["enabled"] = True
    return AppConfig.model_validate(loaded)


def _create_generated_pages(wiki_path: Path, suffix: str) -> tuple[Path, Path]:
    """wikilinkを含む2つのGenerated Wiki pageを作成する。

    Args:
        wiki_path: Generated Wiki root。
        suffix: title衝突を避ける検証run識別子。

    Returns:
        concept pageとsystem pageのpath。

    Side Effects:
        wiki_path配下へMarkdown fileを作成する。
    """
    concept_path = wiki_path / "concepts" / "access-token.md"
    system_path = wiki_path / "systems" / "session.md"
    concept_path.parent.mkdir(parents=True)
    system_path.parent.mkdir(parents=True)
    concept_path.write_text(
        "---\n"
        f"title: Access Token {suffix}\n"
        "---\n"
        f"# Access Token {suffix}\n\nSee [[Session {suffix}|session details]].\n",
        encoding="utf-8",
    )
    system_path.write_text(
        f"---\ntitle: Session {suffix}\n---\n# Session {suffix}\n\nIntegration test source.\n",
        encoding="utf-8",
    )
    return concept_path, system_path


@pytest.mark.integration
async def test_publish_lifecycle_against_bookstack(tmp_path: Path) -> None:
    """実BookStackでcreate、idempotency、update、unavailableを検証する。"""
    base_url, token_id, token_secret, suffix = _integration_credentials()
    shelf_name = f"LLM Wiki Integration {suffix}"
    concept_book_name = f"Integration Concepts {suffix}"
    system_book_name = f"Integration Systems {suffix}"
    headers = {"Authorization": f"Token {token_id}:{token_secret}"}

    async with httpx.AsyncClient(base_url=base_url, headers=headers, timeout=30) as client:
        shelves_response = await client.get("/api/shelves", params={"count": "500"})
        shelves_response.raise_for_status()
        shelves = shelves_response.json()["data"]
        assert all(shelf["name"] != shelf_name for shelf in shelves), (
            f"BOOKSTACK_INTEGRATION_SUFFIXが既存shelfと重複しています: {suffix}"
        )
        shelf_response = await client.post(
            "/api/shelves",
            json={"name": shelf_name, "description": "LLM Wiki Publisher integration test"},
        )
        shelf_response.raise_for_status()
        shelf_id = int(shelf_response.json()["id"])

        config = _integration_config(
            tmp_path,
            base_url,
            shelf_name,
            concept_book_name,
            system_book_name,
        )
        wiki_path = tmp_path / "wiki"
        concept_path, system_path = _create_generated_pages(wiki_path, suffix)
        state_store = StateStore(tmp_path / "state.db")
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

        created = await publisher.publish()
        unchanged = await publisher.publish()
        concept_path.write_text(
            concept_path.read_text(encoding="utf-8") + "\nUpdated integration content.\n",
            encoding="utf-8",
        )
        updated = await publisher.publish()
        system_path.unlink()
        unavailable = await publisher.publish()

        concept_mapping = state_store.get_publish_mapping("concepts/access-token.md")
        system_mapping = state_store.get_publish_mapping("systems/session.md")
        assert concept_mapping is not None
        assert system_mapping is not None
        concept_response = await client.get(
            f"/api/pages/{int(concept_mapping['bookstack_page_id'])}"
        )
        system_response = await client.get(f"/api/pages/{int(system_mapping['bookstack_page_id'])}")
        shelf_detail_response = await client.get(f"/api/shelves/{shelf_id}")
        concept_response.raise_for_status()
        system_response.raise_for_status()
        shelf_detail_response.raise_for_status()

    assert created.created == 2
    assert unchanged.unchanged == 2
    assert updated.updated == 1
    assert updated.unchanged == 1
    assert unavailable.unavailable == 1
    assert "[session details](/link/" in concept_response.json()["markdown"]
    assert "Updated integration content." in concept_response.json()["markdown"]
    assert "Generated source unavailable." in system_response.json()["markdown"]
    assert len(shelf_detail_response.json()["books"]) == 2
