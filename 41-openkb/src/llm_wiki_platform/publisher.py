"""OpenKB Generated WikiをBookStack LLM Wikiへ公開する。"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from llm_wiki_platform.config import BookStackConfig, PublishConfig
from llm_wiki_platform.connectors.base import RetryingHttpClient, require_mapping
from llm_wiki_platform.generated_wiki import GeneratedPage, load_generated_pages
from llm_wiki_platform.state import StateStore

_WIKILINK_PATTERN = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")
_UNAVAILABLE_MARKER = "**Generated source unavailable.**"


@dataclass(frozen=True, slots=True)
class PublishResult:
    """BookStack publishの集計結果。"""

    generated: int
    created: int
    updated: int
    unchanged: int
    unavailable: int
    dry_run: bool

    def as_dict(self) -> dict[str, int | bool]:
        """run detailへ保存するJSON互換dictを返す。

        Returns:
            publish集計値。
        """
        return {
            "generated": self.generated,
            "created": self.created,
            "updated": self.updated,
            "unchanged": self.unchanged,
            "unavailable": self.unavailable,
            "dry_run": self.dry_run,
        }


class BookStackPublisher:
    """Generated WikiをLLM Wiki shelf内のpageへ同期する。"""

    def __init__(
        self,
        bookstack: BookStackConfig,
        publish: PublishConfig,
        generated_wiki_path: Path,
        state_store: StateStore,
        http: RetryingHttpClient,
    ) -> None:
        """BookStackPublisherを初期化する。

        Args:
            bookstack: BookStack境界とcredential以外の接続設定。
            publish: dry-runと削除方針。
            generated_wiki_path: read-only mountされたOpenKB wiki directory。
            state_store: publish mappingの保存先。
            http: publisher token設定済みHTTP client。

        Returns:
            なし。
        """
        self._bookstack = bookstack
        self._publish = publish
        self._generated_wiki_path = generated_wiki_path
        self._state_store = state_store
        self._http = http

    async def publish(self) -> PublishResult:
        """Generated Wiki全体をBookStackへcreateまたはupdateする。

        Returns:
            create、update、unchanged、unavailable件数。

        Raises:
            FileNotFoundError: Generated Wiki directoryが存在しない場合。
            ValueError: LLM Wiki shelfを一意に解決できない場合。
        """
        pages = load_generated_pages(self._generated_wiki_path)
        shelf, books = await self._ensure_destination(pages)
        mappings = {
            str(item["openkb_id"]): item for item in self._state_store.list_publish_mappings()
        }
        created = 0
        updated = 0
        unchanged = 0
        page_urls: dict[str, str] = {}
        page_ids: dict[str, int] = {}
        for page in pages:
            mapping = mappings.get(page.openkb_id)
            book_id = books[page.category]
            if mapping is None:
                created += 1
                if self._publish.dry_run:
                    continue
                response = await self._http.request(
                    "POST",
                    "/api/pages",
                    json={"book_id": book_id, "name": page.title, "markdown": page.markdown},
                )
                created_page = require_mapping(response.json(), "created page")
                page_id = int(created_page["id"])
                page_ids[page.openkb_id] = page_id
            else:
                page_ids[page.openkb_id] = int(mapping["bookstack_page_id"])
                if (
                    mapping["last_published_hash"] == page.content_hash
                    and int(mapping["bookstack_book_id"]) == book_id
                ):
                    unchanged += 1
                else:
                    updated += 1
        if not self._publish.dry_run:
            self._populate_known_urls(pages, page_ids, page_urls)
            for page in pages:
                mapping = mappings.get(page.openkb_id)
                if (
                    mapping is not None
                    and mapping["last_published_hash"] == page.content_hash
                    and int(mapping["bookstack_book_id"]) == books[page.category]
                ):
                    continue
                page_id = page_ids[page.openkb_id]
                book_id = books[page.category]
                markdown = _convert_wikilinks(page.markdown, page_urls)
                await self._http.request(
                    "PUT",
                    f"/api/pages/{page_id}",
                    json={"book_id": book_id, "name": page.title, "markdown": markdown},
                )
                self._state_store.upsert_publish_mapping(
                    openkb_id=page.openkb_id,
                    bookstack_page_id=page_id,
                    bookstack_book_id=book_id,
                    content_hash=page.content_hash,
                )
        current_ids = {page.openkb_id for page in pages}
        stale = [mapping for openkb_id, mapping in mappings.items() if openkb_id not in current_ids]
        unavailable = await self._mark_unavailable(stale)
        if not self._publish.dry_run:
            await self._attach_books_to_shelf(int(shelf["id"]), set(books.values()), shelf)
        return PublishResult(
            generated=len(pages),
            created=created,
            updated=updated,
            unchanged=unchanged,
            unavailable=unavailable,
            dry_run=self._publish.dry_run,
        )

    async def _ensure_destination(
        self, pages: list[GeneratedPage]
    ) -> tuple[dict[str, Any], dict[str, int]]:
        """LLM Wiki shelfとcategory bookを解決または作成する。

        Args:
            pages: 公開対象page。

        Returns:
            shelf objectとcategory別book ID。

        Raises:
            ValueError: LLM Wiki shelfを一意に解決できない場合。
        """
        shelves = await self._list("/api/shelves")
        matching = [item for item in shelves if item.get("name") == self._bookstack.llm_wiki.shelf]
        if len(matching) != 1:
            raise ValueError(
                f"LLM Wiki shelfを一意に解決できません: {self._bookstack.llm_wiki.shelf}"
            )
        shelf_response = await self._http.request("GET", f"/api/shelves/{matching[0]['id']}")
        shelf = dict(require_mapping(shelf_response.json(), "LLM Wiki shelf"))
        all_books = await self._list("/api/books")
        books_by_name = {str(book.get("name")): int(book["id"]) for book in all_books}
        result: dict[str, int] = {}
        for category in sorted({page.category for page in pages}):
            book_name = self._bookstack.llm_wiki.books.get(category, _book_name(category))
            book_id = books_by_name.get(book_name)
            if book_id is None and not self._publish.dry_run:
                response = await self._http.request(
                    "POST", "/api/books", json={"name": book_name, "description": ""}
                )
                book_id = int(require_mapping(response.json(), "created book")["id"])
            result[category] = book_id or -1
        return shelf, result

    async def _list(self, path: str) -> list[dict[str, Any]]:
        """BookStack list endpointをpaginationして全件取得する。

        Args:
            path: list endpoint。

        Returns:
            全pageを連結したobject list。
        """
        offset = 0
        items: list[dict[str, Any]] = []
        while True:
            response = await self._http.request(
                "GET", path, params={"count": "500", "offset": str(offset)}
            )
            payload = require_mapping(response.json(), "BookStack list response")
            data = payload.get("data", [])
            if not isinstance(data, list):
                raise ValueError("BookStack list response.dataはlistである必要があります")
            page = [dict(require_mapping(item, "BookStack list item")) for item in data]
            items.extend(page)
            if len(page) < 500:
                return items
            offset += 500

    @staticmethod
    def _populate_known_urls(
        pages: list[GeneratedPage],
        page_ids: dict[str, int],
        page_urls: dict[str, str],
    ) -> None:
        """BookStack page IDからwikilink変換用canonical pathを構築する。

        Args:
            pages: 公開対象page。
            page_ids: OpenKB page IDとBookStack page IDの対応。
            page_urls: titleとURLの出力先。

        Returns:
            なし。
        """
        for page in pages:
            page_urls[page.title] = f"/link/{page_ids[page.openkb_id]}"

    async def _attach_books_to_shelf(
        self,
        shelf_id: int,
        generated_book_ids: set[int],
        shelf: dict[str, Any],
    ) -> None:
        """既存assignを保持したまま生成bookをLLM Wiki shelfへ追加する。

        Args:
            shelf_id: LLM Wiki shelf ID。
            generated_book_ids: 今回使用したbook ID。
            shelf: read endpointから取得したshelf object。

        Returns:
            なし。
        """
        existing_value = shelf.get("books", [])
        existing = {
            int(require_mapping(book, "shelf book")["id"])
            for book in existing_value
            if isinstance(existing_value, list)
        }
        book_ids = sorted(existing | {book_id for book_id in generated_book_ids if book_id > 0})
        await self._http.request(
            "PUT",
            f"/api/shelves/{shelf_id}",
            json={"name": self._bookstack.llm_wiki.shelf, "books": book_ids},
        )

    async def _mark_unavailable(self, stale: list[dict[str, Any]]) -> int:
        """Generated Wikiから消えたpageへunavailable表示を追加する。

        Args:
            stale: 現在のGenerated Wikiに存在しないmapping。

        Returns:
            unavailable表示を追加したpage数。
        """
        if self._publish.dry_run:
            return len(stale)
        changed = 0
        for mapping in stale:
            page_id = int(mapping["bookstack_page_id"])
            response = await self._http.request("GET", f"/api/pages/{page_id}")
            page = require_mapping(response.json(), "stale BookStack page")
            markdown = str(page.get("markdown") or "")
            if _UNAVAILABLE_MARKER in markdown:
                continue
            warning = (
                f"> {_UNAVAILABLE_MARKER} This page is retained for review and provenance.\n\n"
            )
            await self._http.request(
                "PUT", f"/api/pages/{page_id}", json={"markdown": warning + markdown}
            )
            changed += 1
        return changed


def _book_name(category: str) -> str:
    """OpenKB categoryをBookStack book名へ変換する。

    Args:
        category: Generated Wikiのtop-level directory名。

    Returns:
        title caseのbook名。
    """
    aliases = {
        "concepts": "Concepts",
        "entities": "Entities",
        "projects": "Projects",
        "systems": "Systems",
        "decisions": "Decisions",
        "sources": "Sources",
        "summaries": "Summaries",
        "syntheses": "Syntheses",
    }
    return aliases.get(category, category.replace("_", " ").title())


def _convert_wikilinks(markdown: str, page_urls: dict[str, str]) -> str:
    """解決可能なOpenKB wikilinkをBookStack Markdown linkへ変換する。

    Args:
        markdown: OpenKB page本文。
        page_urls: page titleとBookStack URLの対応。

    Returns:
        wikilink変換後のMarkdown。
    """

    def replace(match: re.Match[str]) -> str:
        """1つのwikilinkをURL解決できる場合だけMarkdown化する。

        Args:
            match: wikilink regex match。

        Returns:
            Markdown linkまたは元wikilink。
        """
        target = match.group(1).strip()
        label = (match.group(2) or target).strip()
        url = page_urls.get(target)
        return f"[{label}]({url})" if url else match.group(0)

    return _WIKILINK_PATTERN.sub(replace, markdown)
