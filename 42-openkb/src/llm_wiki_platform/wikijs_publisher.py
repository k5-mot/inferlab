"""OpenKB Generated WikiをWiki.js LLM Wikiへ公開する。"""

from __future__ import annotations

import re
from pathlib import Path, PurePosixPath
from typing import Any

from llm_wiki_platform.config import PublishConfig, WikiJSConfig
from llm_wiki_platform.connectors.base import RetryingHttpClient, require_mapping
from llm_wiki_platform.generated_wiki import (
    GeneratedPage,
    convert_wikilinks,
    load_generated_pages,
)
from llm_wiki_platform.publisher import PublishResult
from llm_wiki_platform.state import StateStore
from llm_wiki_platform.wikijs_graphql import WikiJSGraphQLClient, require_success

_UNAVAILABLE_MARKER = "**Generated source unavailable.**"

_LIST_PAGES_QUERY = """
query ListPages($locale: String!) {
  pages {
    list(locale: $locale, orderBy: PATH, orderByDirection: ASC) {
      id path locale title updatedAt
    }
  }
}
"""

_GET_PAGE_QUERY = """
query GetPage($id: Int!) {
  pages {
    single(id: $id) { id path locale title content }
  }
}
"""

_CREATE_PAGE_MUTATION = """
mutation CreatePage(
  $content: String!, $description: String!, $editor: String!,
  $isPublished: Boolean!, $isPrivate: Boolean!, $locale: String!,
  $path: String!, $tags: [String]!, $title: String!
) {
  pages {
    create(
      content: $content, description: $description, editor: $editor,
      isPublished: $isPublished, isPrivate: $isPrivate, locale: $locale,
      path: $path, tags: $tags, title: $title
    ) {
      responseResult { succeeded errorCode slug message }
      page { id path locale title updatedAt }
    }
  }
}
"""

_UPDATE_PAGE_MUTATION = """
mutation UpdatePage(
  $id: Int!, $content: String, $description: String, $editor: String,
  $isPublished: Boolean, $isPrivate: Boolean, $locale: String,
  $path: String, $tags: [String], $title: String
) {
  pages {
    update(
      id: $id, content: $content, description: $description, editor: $editor,
      isPublished: $isPublished, isPrivate: $isPrivate, locale: $locale,
      path: $path, tags: $tags, title: $title
    ) {
      responseResult { succeeded errorCode slug message }
      page { id path locale title updatedAt }
    }
  }
}
"""


class WikiJSPublisher:
    """Generated WikiをWiki.js LLM Wiki pathへ同期する。"""

    def __init__(
        self,
        wikijs: WikiJSConfig,
        publish: PublishConfig,
        generated_wiki_path: Path,
        state_store: StateStore,
        http: RetryingHttpClient,
    ) -> None:
        """WikiJSPublisherを初期化する。

        Args:
            wikijs: Wiki.js境界とcredential以外の接続設定。
            publish: dry-runと削除方針。
            generated_wiki_path: read-only mountされたOpenKB wiki directory。
            state_store: publish mappingの保存先。
            http: publisher API key設定済みHTTP client。

        Returns:
            なし。
        """
        self._wikijs = wikijs
        self._publish = publish
        self._generated_wiki_path = generated_wiki_path
        self._state_store = state_store
        self._graphql = WikiJSGraphQLClient(http)

    async def publish(self) -> PublishResult:
        """Generated Wiki全体をWiki.jsへcreateまたはupdateする。

        Returns:
            create、update、unchanged、unavailable件数。

        Raises:
            FileNotFoundError: Generated Wiki directoryが存在しない場合。
            ValueError: 公開先pathが重複する場合。
            WikiJSGraphQLError: GraphQL operationが失敗した場合。
        """
        pages = load_generated_pages(self._generated_wiki_path)
        paths = {page.openkb_id: self._destination_path(page) for page in pages}
        if len(set(paths.values())) != len(paths):
            raise ValueError("Generated Wikiから重複するWiki.js pathが生成されました")
        remote_pages = await self._list_pages()
        remote_by_path = {str(page["path"]): page for page in remote_pages}
        remote_by_id = {int(page["id"]): page for page in remote_pages}
        mappings = {
            str(item["openkb_id"]): item
            for item in self._state_store.list_wikijs_publish_mappings()
        }
        page_urls = {
            page.title: f"/{self._wikijs.llm_wiki.locale}/{paths[page.openkb_id]}" for page in pages
        }
        created = 0
        updated = 0
        unchanged = 0
        for page in pages:
            destination_path = paths[page.openkb_id]
            mapping = mappings.get(page.openkb_id)
            remote = remote_by_path.get(destination_path)
            if (
                mapping is not None
                and remote is not None
                and mapping["last_published_hash"] == page.content_hash
                and mapping["wikijs_path"] == destination_path
            ):
                unchanged += 1
                continue
            markdown = convert_wikilinks(page.markdown, page_urls)
            variables = self._page_variables(page, destination_path, markdown)
            if remote is None:
                created += 1
                if self._publish.dry_run:
                    continue
                page_id = await self._create_page(variables)
            else:
                updated += 1
                page_id = int(remote["id"])
                if self._publish.dry_run:
                    continue
                await self._update_page(page_id, variables)
            self._state_store.upsert_wikijs_publish_mapping(
                openkb_id=page.openkb_id,
                wikijs_page_id=page_id,
                wikijs_path=destination_path,
                content_hash=page.content_hash,
            )
        current_ids = {page.openkb_id for page in pages}
        stale = [mapping for key, mapping in mappings.items() if key not in current_ids]
        unavailable = await self._mark_unavailable(stale, remote_by_id)
        return PublishResult(
            generated=len(pages),
            created=created,
            updated=updated,
            unchanged=unchanged,
            unavailable=unavailable,
            dry_run=self._publish.dry_run,
        )

    async def _list_pages(self) -> list[dict[str, Any]]:
        """LLM Wiki localeのpage一覧を取得する。

        Returns:
            LLM Wiki path配下のpage summary一覧。
        """
        boundary = self._wikijs.llm_wiki
        data = await self._graphql.execute(
            "ListPages", _LIST_PAGES_QUERY, {"locale": boundary.locale}
        )
        container = require_mapping(data.get("pages"), "Wiki.js pages")
        value = container.get("list", [])
        if not isinstance(value, list):
            raise ValueError("Wiki.js pages.listはlistである必要があります")
        pages = [dict(require_mapping(item, "Wiki.js page summary")) for item in value]
        return [
            page
            for page in pages
            if str(page.get("path")) == boundary.path
            or str(page.get("path", "")).startswith(f"{boundary.path}/")
        ]

    async def _create_page(self, variables: dict[str, Any]) -> int:
        """Wiki.js pageを作成する。

        Args:
            variables: create mutationへ渡すpage属性。

        Returns:
            作成されたWiki.js page ID。
        """
        data = await self._graphql.execute("CreatePage", _CREATE_PAGE_MUTATION, variables)
        pages = require_mapping(data.get("pages"), "Wiki.js pages")
        result = require_success(pages.get("create"), "Wiki.js page create")
        page = require_mapping(result.get("page"), "created Wiki.js page")
        return int(page["id"])

    async def _update_page(self, page_id: int, variables: dict[str, Any]) -> None:
        """既存Wiki.js pageを更新する。

        Args:
            page_id: 更新対象Wiki.js page ID。
            variables: update mutationへ渡すpage属性。

        Returns:
            なし。
        """
        data = await self._graphql.execute(
            "UpdatePage", _UPDATE_PAGE_MUTATION, {"id": page_id} | variables
        )
        pages = require_mapping(data.get("pages"), "Wiki.js pages")
        require_success(pages.get("update"), "Wiki.js page update")

    async def _mark_unavailable(
        self,
        stale: list[dict[str, Any]],
        remote_by_id: dict[int, dict[str, Any]],
    ) -> int:
        """Generated Wikiから消えたpageへunavailable表示を追加する。

        Args:
            stale: 現在のGenerated Wikiに存在しないmapping。
            remote_by_id: LLM Wiki path配下に現存するpage summary。

        Returns:
            unavailable表示を追加したpage数。
        """
        existing = [item for item in stale if int(item["wikijs_page_id"]) in remote_by_id]
        if self._publish.dry_run:
            return len(existing)
        changed = 0
        for mapping in existing:
            page_id = int(mapping["wikijs_page_id"])
            data = await self._graphql.execute("GetPage", _GET_PAGE_QUERY, {"id": page_id})
            pages = require_mapping(data.get("pages"), "Wiki.js pages")
            page = require_mapping(pages.get("single"), "stale Wiki.js page")
            content = str(page.get("content") or "")
            if _UNAVAILABLE_MARKER in content:
                continue
            warning = (
                f"> {_UNAVAILABLE_MARKER} This page is retained for review and provenance.\n\n"
            )
            await self._update_page(
                page_id,
                {
                    "content": warning + content,
                    "description": "Generated source unavailable",
                    "editor": "markdown",
                    "isPublished": True,
                    "isPrivate": False,
                    "locale": str(page["locale"]),
                    "path": str(page["path"]),
                    "tags": ["openkb", "llm-wiki", "unavailable"],
                    "title": str(page["title"]),
                },
            )
            changed += 1
        return changed

    def _destination_path(self, page: GeneratedPage) -> str:
        """OpenKB page IDをLLM Wiki配下のstable pathへ変換する。

        Args:
            page: 変換対象Generated Page。

        Returns:
            localeを含まないWiki.js page path。
        """
        source_path = PurePosixPath(page.openkb_id).with_suffix("")
        relative = "/".join(_slug_segment(part) for part in source_path.parts)
        return f"{self._wikijs.llm_wiki.path}/{relative}"

    def _page_variables(
        self,
        page: GeneratedPage,
        destination_path: str,
        markdown: str,
    ) -> dict[str, Any]:
        """Wiki.js create/update共通のpage変数を構築する。

        Args:
            page: 公開対象Generated Page。
            destination_path: localeを除いた公開先path。
            markdown: wikilink変換済み本文。

        Returns:
            GraphQL mutationへ渡す変数。
        """
        return {
            "content": markdown,
            "description": "Generated by OpenKB",
            "editor": "markdown",
            "isPublished": True,
            "isPrivate": False,
            "locale": self._wikijs.llm_wiki.locale,
            "path": destination_path,
            "tags": ["openkb", "llm-wiki"],
            "title": page.title,
        }


def _slug_segment(value: str) -> str:
    """Generated Wiki path segmentをWiki.js向けslugへ変換する。

    Args:
        value: OpenKB relative pathの1 segment。

    Returns:
        空にならない小文字slug。
    """
    normalized = re.sub(r"[^\w-]+", "-", value.strip().lower()).strip("-")
    return normalized or "page"
