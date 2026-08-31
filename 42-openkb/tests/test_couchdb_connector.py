"""Obsidian LiveSync用CouchDB Connectorを検証する。"""

from __future__ import annotations

import json
from typing import Any

import httpx
import pytest

from llm_wiki_platform.config import SourceConfig
from llm_wiki_platform.connectors.couchdb import CouchDBConnector


class FakeHttpClient:
    """固定したCouchDB responseを返すHTTP client。"""

    def __init__(
        self,
        parents: list[dict[str, Any]],
        leaves: list[dict[str, Any]],
    ) -> None:
        """Fake clientを初期化する。

        Args:
            parents: `_find` responseへ含める親document。
            leaves: `_all_docs` responseへ含めるleaf document。

        Returns:
            なし。
        """
        self.parents = parents
        self.leaves = leaves
        self.requests: list[tuple[str, str, dict[str, Any]]] = []

    async def request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        """requestを記録して固定responseを返す。

        Args:
            method: HTTP method。
            url: request path。
            **kwargs: request option。

        Returns:
            CouchDB互換JSON response。
        """
        self.requests.append((method, url, kwargs))
        if url.endswith("/_find"):
            payload = {"docs": self.parents}
        else:
            keys = kwargs["json"]["keys"]
            payload = {
                "rows": [{"doc": document} for document in self.leaves if document["_id"] in keys]
            }
        return httpx.Response(200, content=json.dumps(payload).encode())


def _source_config(**overrides: Any) -> SourceConfig:
    """test用CouchDB source設定を生成する。

    Args:
        **overrides: 上書きする設定値。

    Returns:
        検証済みSourceConfig。
    """
    values: dict[str, Any] = {
        "enabled": True,
        "base_url": "http://couchdb:5984",
        "database": "obsidian",
        "credential": {
            "username_env": "COUCHDB_USERNAME",
            "password_env": "COUCHDB_PASSWORD",
        },
        "ingest": {"schedule": "0 */6 * * *"},
        "title_strategy": "hierarchy",
        "max_documents": 1000,
        "exclude": {"paths": ["ix:"]},
    }
    values.update(overrides)
    return SourceConfig.model_validate(values)


@pytest.mark.asyncio
async def test_couchdb_connector_restores_visible_markdown_notes() -> None:
    """公開対象noteだけを列挙し、chunk順と階層titleを保持することを検証する。"""
    parents = [
        {
            "_id": "note-1",
            "_rev": "2-a",
            "type": "plain",
            "path": "AWS/AWS CLF/事前テスト.md",
            "children": ["leaf-b", "leaf-a"],
        },
        {
            "_id": "hidden",
            "type": "plain",
            "path": ".obsidian/config.md",
            "children": [],
        },
        {
            "_id": "internal",
            "type": "plain",
            "path": "ix:laptop/plugin.md",
            "children": [],
        },
        {
            "_id": "deleted",
            "type": "plain",
            "path": "deleted.md",
            "deleted": True,
            "children": [],
        },
    ]
    leaves = [
        {"_id": "leaf-a", "type": "leaf", "data": "後半"},
        {"_id": "leaf-b", "type": "leaf", "data": "# 前半\n"},
    ]
    http = FakeHttpClient(parents, leaves)
    connector = CouchDBConnector(_source_config(), http)  # type: ignore[arg-type]

    batch = await connector.discover(None)
    raw = await connector.fetch(batch.objects[0])
    document = connector.normalize(batch.objects[0], raw)

    assert len(batch.objects) == 1
    assert batch.complete_snapshot is True
    assert batch.objects[0].title == "AWS AWS CLF 事前テスト"
    assert raw.decode() == "# 前半\n後半"
    assert document.content == "# 前半\n後半"
    assert document.scope == {"type": "folder", "id": "AWS"}
    assert http.requests[0][0:2] == ("POST", "/obsidian/_find")
    assert http.requests[1] == (
        "POST",
        "/obsidian/_all_docs",
        {
            "params": {"include_docs": "true"},
            "json": {"keys": ["leaf-b", "leaf-a"]},
        },
    )


@pytest.mark.asyncio
async def test_couchdb_connector_rejects_missing_leaf_chunk() -> None:
    """参照leaf欠損を不完全snapshotとして成功扱いしないことを検証する。"""
    parents = [
        {
            "_id": "note-1",
            "type": "plain",
            "path": "note.md",
            "children": ["missing-leaf"],
        }
    ]
    connector = CouchDBConnector(
        _source_config(),
        FakeHttpClient(parents, []),  # type: ignore[arg-type]
    )
    batch = await connector.discover(None)

    with pytest.raises(ValueError, match="leaf chunk"):
        await connector.fetch(batch.objects[0])
