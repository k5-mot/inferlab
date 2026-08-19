"""BookStack Human Wiki向けread-only Connector。"""

from __future__ import annotations

from datetime import UTC
from typing import Any

from llm_wiki_platform.config import BookStackConfig
from llm_wiki_platform.connectors.base import (
    ConnectorBatch,
    RetryingHttpClient,
    SourceConnector,
    decode_json_object,
    json_bytes,
    parse_datetime,
    require_mapping,
)
from llm_wiki_platform.models import Authority, KnowledgeDocument, SourceObject


class BookStackConnector(SourceConnector):
    """Human Wiki shelf配下のpageだけを取り込む。"""

    name = "bookstack"

    def __init__(self, config: BookStackConfig, http: RetryingHttpClient) -> None:
        """BookStackConnectorを初期化する。

        Args:
            config: BookStack境界と接続設定。
            http: reader token設定済みHTTP client。

        Returns:
            なし。
        """
        self._config = config
        self._http = http

    async def discover(self, checkpoint: str | None) -> ConnectorBatch:
        """Human Wiki shelf配下のpageを全件列挙する。

        Args:
            checkpoint: 前回取得時刻。削除検出のためfilterには使用しない。

        Returns:
            Human Wiki pageの完全snapshot。

        Raises:
            ValueError: 設定されたHuman Wiki shelfが存在しない場合。
        """
        del checkpoint
        shelves = await self._list("/api/shelves")
        matching = [item for item in shelves if item.get("name") == self._config.human_wiki.shelf]
        if len(matching) != 1:
            raise ValueError(
                f"Human Wiki shelfを一意に解決できません: {self._config.human_wiki.shelf}"
            )
        shelf_id = int(matching[0]["id"])
        shelf_response = await self._http.request("GET", f"/api/shelves/{shelf_id}")
        shelf = require_mapping(shelf_response.json(), "shelf")
        books_value = shelf.get("books", [])
        if not isinstance(books_value, list):
            raise ValueError("shelf.booksはlistである必要があります")
        objects: list[SourceObject] = []
        for book_item in books_value:
            book_summary = require_mapping(book_item, "book")
            book_id = int(book_summary["id"])
            book_response = await self._http.request("GET", f"/api/books/{book_id}")
            book = require_mapping(book_response.json(), "book")
            for page in _extract_pages(book.get("contents", [])):
                page_id = str(page["id"])
                objects.append(
                    SourceObject(
                        id=f"bookstack:human-wiki:page:{page_id}",
                        source=self.name,
                        source_type="page",
                        source_instance=str(self._config.base_url.host),
                        source_id=page_id,
                        title=str(page.get("name") or f"Page {page_id}"),
                        url=None,
                        updated_at=parse_datetime(page.get("updated_at")),
                        metadata={
                            "book_id": book_id,
                            "book_name": book.get("name", book_summary.get("name")),
                            "shelf_id": shelf_id,
                        },
                    )
                )
        return ConnectorBatch(objects=tuple(objects), complete_snapshot=True)

    async def _list(self, path: str) -> list[dict[str, Any]]:
        """BookStack list endpointをpaginationして全件取得する。

        Args:
            path: `/api`配下のlist endpoint。

        Returns:
            全pageを連結したobject list。
        """
        offset = 0
        count = 500
        items: list[dict[str, Any]] = []
        while True:
            response = await self._http.request(
                "GET", path, params={"count": str(count), "offset": str(offset)}
            )
            payload = require_mapping(response.json(), "list response")
            data = payload.get("data", [])
            if not isinstance(data, list):
                raise ValueError("BookStack list response.dataはlistである必要があります")
            page = [dict(require_mapping(item, "list item")) for item in data]
            items.extend(page)
            if len(page) < count:
                return items
            offset += count

    async def fetch(self, source: SourceObject) -> bytes:
        """BookStack page本文とmetadataを取得する。

        Args:
            source: Human Wiki pageのSource Object。

        Returns:
            Page API responseのJSON bytes。
        """
        response = await self._http.request("GET", f"/api/pages/{source.source_id}")
        return json_bytes(require_mapping(response.json(), "page"))

    def normalize(self, source: SourceObject, raw: bytes) -> KnowledgeDocument:
        """BookStack pageをauthoritative documentへ正規化する。

        Args:
            source: Human Wiki pageのSource Object。
            raw: fetchで取得したPage API JSON。

        Returns:
            authoritative authorityのKnowledgeDocument。
        """
        page = decode_json_object(raw)
        content = str(page.get("markdown") or page.get("html") or "")
        updated_by = page.get("updated_by")
        author = str(require_mapping(updated_by, "updated_by").get("name")) if updated_by else None
        page_url = page.get("url")
        return KnowledgeDocument(
            id=source.id,
            source=self.name,
            source_type=source.source_type,
            source_instance=source.source_instance,
            source_id=source.source_id,
            title=str(page.get("name") or source.title),
            content=content,
            content_format="markdown" if page.get("markdown") else "html",
            url=page_url if isinstance(page_url, str) else source.url,
            created_at=parse_datetime(page.get("created_at")),
            updated_at=parse_datetime(page.get("updated_at")) or source.updated_at,
            authors=() if author is None else (author,),
            scope={"type": "shelf", "id": self._config.human_wiki.shelf},
            authority=Authority.AUTHORITATIVE,
            metadata={
                "book_id": source.metadata["book_id"],
                "book_name": source.metadata["book_name"],
                "shelf_id": source.metadata["shelf_id"],
            },
        )

    def checkpoint(self, objects: tuple[SourceObject, ...], previous: str | None) -> str | None:
        """最新page更新時刻をcheckpointとして返す。

        Args:
            objects: 処理に成功したpage一覧。
            previous: 前回checkpoint。

        Returns:
            最新updated_at。timestampがなければprevious。
        """
        timestamps = [item.updated_at for item in objects if item.updated_at is not None]
        return max(timestamps).astimezone(UTC).isoformat() if timestamps else previous


def _extract_pages(value: object) -> list[dict[str, Any]]:
    """BookまたはChapter contentsからpageを再帰的に抽出する。

    Args:
        value: BookStack contents値。

    Returns:
        typeがpageのobject一覧。
    """
    pages: list[dict[str, Any]] = []
    if isinstance(value, list):
        for item in value:
            pages.extend(_extract_pages(item))
    elif isinstance(value, dict):
        if value.get("type") == "page" or (
            "id" in value and "name" in value and "pages" not in value
        ):
            pages.append(dict(value))
        else:
            pages.extend(_extract_pages(value.get("pages", [])))
            pages.extend(_extract_pages(value.get("contents", [])))
    return pages
