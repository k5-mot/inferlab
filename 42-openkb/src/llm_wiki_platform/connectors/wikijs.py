"""Wiki.js Human Wiki向けread-only Connector。"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import UTC

from llm_wiki_platform.config import WikiJSConfig
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
from llm_wiki_platform.wikijs_graphql import WikiJSGraphQLClient

_LIST_PAGES_QUERY = """
query ListPages($locale: String!) {
  pages {
    list(locale: $locale, orderBy: PATH, orderByDirection: ASC) {
      id path locale title description contentType isPublished isPrivate
      createdAt updatedAt tags
    }
  }
}
"""

_GET_PAGE_QUERY = """
query GetPage($id: Int!) {
  pages {
    single(id: $id) {
      id path locale title description content contentType createdAt updatedAt
      authorName tags { tag }
    }
  }
}
"""


class WikiJSConnector(SourceConnector):
    """Human Wiki path配下の公開pageだけを取り込む。"""

    name = "wikijs"

    def __init__(self, config: WikiJSConfig, http: RetryingHttpClient) -> None:
        """WikiJSConnectorを初期化する。

        Args:
            config: Wiki.js境界と接続設定。
            http: reader API key設定済みHTTP client。

        Returns:
            なし。
        """
        self._config = config
        self._graphql = WikiJSGraphQLClient(http)

    async def discover(self, checkpoint: str | None) -> ConnectorBatch:
        """Human Wiki path配下のpageを全件列挙する。

        Args:
            checkpoint: 前回取得時刻。削除検出のためfilterには使用しない。

        Returns:
            Human Wiki pageの完全snapshot。
        """
        del checkpoint
        boundary = self._config.human_wiki
        data = await self._graphql.execute(
            "ListPages", _LIST_PAGES_QUERY, {"locale": boundary.locale}
        )
        pages_container = require_mapping(data.get("pages"), "Wiki.js pages")
        page_values = pages_container.get("list", [])
        if not isinstance(page_values, list):
            raise ValueError("Wiki.js pages.listはlistである必要があります")
        objects: list[SourceObject] = []
        for value in page_values:
            page = require_mapping(value, "Wiki.js page summary")
            page_path = str(page.get("path") or "")
            if page.get("isPublished") is not True or not is_path_within(page_path, boundary.path):
                continue
            page_id = str(page["id"])
            objects.append(
                SourceObject(
                    id=f"wikijs:human-wiki:page:{page_id}",
                    source=self.name,
                    source_type="page",
                    source_instance=str(self._config.base_url.host),
                    source_id=page_id,
                    title=str(page.get("title") or f"Page {page_id}"),
                    url=self._page_url(boundary.locale, page_path),
                    updated_at=parse_datetime(page.get("updatedAt")),
                    metadata={
                        "path": page_path,
                        "locale": boundary.locale,
                        "content_type": page.get("contentType"),
                    },
                )
            )
        return ConnectorBatch(objects=tuple(objects), complete_snapshot=True)

    async def fetch(self, source: SourceObject) -> bytes:
        """Wiki.js page本文とmetadataを取得する。

        Args:
            source: Human Wiki pageのSource Object。

        Returns:
            Page GraphQL responseのJSON bytes。
        """
        data = await self._graphql.execute(
            "GetPage", _GET_PAGE_QUERY, {"id": int(source.source_id)}
        )
        pages = require_mapping(data.get("pages"), "Wiki.js pages")
        page = require_mapping(pages.get("single"), "Wiki.js page")
        return json_bytes(page)

    def normalize(self, source: SourceObject, raw: bytes) -> KnowledgeDocument:
        """Wiki.js pageをauthoritative documentへ正規化する。

        Args:
            source: Human Wiki pageのSource Object。
            raw: fetchで取得したPage GraphQL JSON。

        Returns:
            authoritative authorityのKnowledgeDocument。
        """
        page = decode_json_object(raw)
        locale = str(page.get("locale") or source.metadata["locale"])
        page_path = str(page.get("path") or source.metadata["path"])
        tags = _tag_names(page.get("tags"))
        author_name = page.get("authorName")
        return KnowledgeDocument(
            id=source.id,
            source=self.name,
            source_type=source.source_type,
            source_instance=source.source_instance,
            source_id=source.source_id,
            title=str(page.get("title") or source.title),
            content=str(page.get("content") or ""),
            content_format=str(page.get("contentType") or "markdown"),
            url=self._page_url(locale, page_path),
            created_at=parse_datetime(page.get("createdAt")),
            updated_at=parse_datetime(page.get("updatedAt")) or source.updated_at,
            authors=() if not isinstance(author_name, str) else (author_name,),
            labels=tags,
            scope={
                "type": "path",
                "id": f"{self._config.human_wiki.locale}/{self._config.human_wiki.path}",
            },
            authority=Authority.AUTHORITATIVE,
            metadata={"path": page_path, "locale": locale},
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

    def _page_url(self, locale: str, path: str) -> str:
        """Wiki.js pageのcanonical URLを構築する。

        Args:
            locale: page locale。
            path: locale配下のpage path。

        Returns:
            Wiki.js base URL基準のabsolute URL。
        """
        base_url = str(self._config.base_url).rstrip("/")
        return f"{base_url}/{locale}/{path.lstrip('/')}"


def is_path_within(path: str, prefix: str) -> bool:
    """Wiki.js pathが指定prefix自身または配下か判定する。

    Args:
        path: 判定対象page path。
        prefix: Wiki境界のpath prefix。

    Returns:
        prefix範囲内ならTrue。
    """
    return path == prefix or path.startswith(f"{prefix}/")


def _tag_names(value: object) -> tuple[str, ...]:
    """Wiki.js tag object一覧からtag名を抽出する。

    Args:
        value: GraphQL responseのtags値。

    Returns:
        空値を除いたtag名。
    """
    if not isinstance(value, list):
        return ()
    tags: list[str] = []
    for item in value:
        if isinstance(item, Mapping) and isinstance(item.get("tag"), str):
            tags.append(str(item["tag"]))
    return tuple(tags)
