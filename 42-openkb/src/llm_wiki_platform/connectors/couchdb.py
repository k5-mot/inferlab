"""Obsidian Self-hosted LiveSync向けCouchDB Connector。"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import PurePosixPath
from urllib.parse import quote, urljoin

from llm_wiki_platform.config import SourceConfig
from llm_wiki_platform.connectors.base import (
    ConnectorBatch,
    RetryingHttpClient,
    SourceConnector,
    decode_json_object,
    require_mapping,
)
from llm_wiki_platform.models import Authority, KnowledgeDocument, SourceObject


class CouchDBConnector(SourceConnector):
    """LiveSync snapshotから公開対象のMarkdown noteを復元する。"""

    name = "couchdb"

    def __init__(self, config: SourceConfig, http: RetryingHttpClient) -> None:
        """CouchDB Connectorを初期化する。

        Args:
            config: databaseとfilterを含むCouchDB source設定。
            http: Basic認証設定済みHTTP client。

        Returns:
            なし。

        Raises:
            ValueError: databaseが設定されていない場合。
        """
        if config.database is None:
            raise ValueError("CouchDB databaseが未設定です")
        self._config = config
        self._http = http
        self._database = config.database
        self._exclude_prefixes = tuple(config.exclude.get("paths", ()))

    async def discover(self, checkpoint: str | None) -> ConnectorBatch:
        """CouchDBの一貫したsnapshotからMarkdown親documentを列挙する。

        Args:
            checkpoint: 前回取得位置。完全snapshotのためfilterには使用しない。

        Returns:
            公開対象noteの完全snapshot。

        Raises:
            ValueError: CouchDB responseまたはLiveSync documentが不正な場合。
        """
        del checkpoint
        parents: list[dict[str, object]] = []
        bookmark: str | None = None
        seen_bookmarks: set[str] = set()
        while True:
            query: dict[str, object] = {
                "selector": {"type": {"$eq": "plain"}},
                "fields": ["_id", "_rev", "type", "path", "children", "deleted"],
                "limit": 500,
            }
            if bookmark is not None:
                query["bookmark"] = bookmark
            response = await self._http.request(
                "POST",
                f"/{quote(self._database, safe='')}/_find",
                json=query,
            )
            page, next_bookmark = _parent_documents(response.content)
            parents.extend(
                document
                for document in page
                if _is_visible_markdown_parent(document, self._exclude_prefixes)
            )
            if len(parents) > self._config.max_documents:
                raise ValueError(
                    "CouchDB Markdown document数が上限を超えています: "
                    f"{len(parents)}/{self._config.max_documents}"
                )
            if not page or next_bookmark is None or next_bookmark in seen_bookmarks:
                break
            seen_bookmarks.add(next_bookmark)
            bookmark = next_bookmark
        objects = tuple(
            self._source_object(parent)
            for parent in sorted(parents, key=lambda item: str(item["path"]))
        )
        return ConnectorBatch(objects=objects, complete_snapshot=True)

    def _source_object(self, parent: dict[str, object]) -> SourceObject:
        """LiveSync親documentをSource Objectへ変換する。

        Args:
            parent: 検証済みMarkdown親document。

        Returns:
            note pathとdocument IDを保持するSource Object。
        """
        document_id = _required_string(parent.get("_id"), "親documentの_id")
        note_path = _required_string(parent.get("path"), f"親document {document_id} のpath")
        return SourceObject(
            id=f"couchdb:{self._database}:note:{document_id}",
            source=self.name,
            source_type="note",
            source_instance=str(self._config.base_url.host),
            source_id=document_id,
            title=_document_title(note_path, self._config.title_strategy),
            url=urljoin(
                str(self._config.base_url),
                f"{quote(self._database, safe='')}/{quote(document_id, safe='')}",
            ),
            metadata={
                "document_id": document_id,
                "note_path": note_path,
                "revision": parent.get("_rev"),
                "children": parent.get("children"),
                "extension": ".md",
            },
        )

    async def fetch(self, source: SourceObject) -> bytes:
        """snapshot内の親documentと順序付きleaf chunkから本文を復元する。

        Args:
            source: discoverで発見したLiveSync note。

        Returns:
            復元済みMarkdown bytes。

        Raises:
            ValueError: 親documentまたは参照leafが不正な場合。
        """
        children = source.metadata.get("children")
        if not isinstance(children, list):
            raise ValueError(f"LiveSync親documentにchildrenがありません: {source.source_id}")
        child_ids = [
            _required_string(child, f"親document {source.source_id} のchild ID")
            for child in children
        ]
        if not child_ids:
            return b""
        response = await self._http.request(
            "POST",
            f"/{quote(self._database, safe='')}/_all_docs",
            params={"include_docs": "true"},
            json={"keys": child_ids},
        )
        documents = _document_map(response.content)
        chunks: list[str] = []
        for child_id in child_ids:
            child = documents.get(child_id)
            if child is None:
                raise ValueError(f"LiveSync leaf chunkが見つかりません: {child_id}")
            if child.get("type") != "leaf":
                raise ValueError(f"LiveSync childがleafではありません: {child_id}")
            chunks.append(_required_string(child.get("data"), f"leaf {child_id} のdata"))
        return "".join(chunks).encode()

    def normalize(self, source: SourceObject, raw: bytes) -> KnowledgeDocument:
        """復元したMarkdown noteをCanonical Documentへ変換する。

        Args:
            source: LiveSync noteのSource Object。
            raw: 復元済みMarkdown bytes。

        Returns:
            reference authorityのKnowledgeDocument。
        """
        note_path = str(source.metadata["note_path"])
        parts = PurePosixPath(note_path).parts
        scope_id = parts[0] if len(parts) > 1 else "root"
        return KnowledgeDocument(
            id=source.id,
            source=self.name,
            source_type=source.source_type,
            source_instance=source.source_instance,
            source_id=source.source_id,
            title=source.title,
            content=raw.decode("utf-8", errors="replace"),
            content_format="markdown",
            url=source.url,
            scope={"type": "folder", "id": scope_id},
            authority=Authority.REFERENCE,
            metadata={
                "note_path": note_path,
                "revision": source.metadata.get("revision"),
            },
        )

    def checkpoint(self, objects: tuple[SourceObject, ...], previous: str | None) -> str | None:
        """完全snapshot取得時刻をcheckpointとして返す。

        Args:
            objects: 処理に成功したnote一覧。
            previous: 前回checkpoint。

        Returns:
            取得対象があれば現在UTC時刻、なければprevious。
        """
        return datetime.now(UTC).isoformat() if objects else previous


def _document_map(content: bytes) -> dict[str, dict[str, object]]:
    """CouchDB `_all_docs` responseをdocument ID mapへ変換する。

    Args:
        content: UTF-8 JSON response body。

    Returns:
        document IDとdocumentの対応。

    Raises:
        ValueError: response構造が不正な場合。
    """
    payload = decode_json_object(content)
    rows = payload.get("rows")
    if not isinstance(rows, list):
        raise ValueError("CouchDB `_all_docs`応答にrowsがありません")
    documents: dict[str, dict[str, object]] = {}
    for row_value in rows:
        row = require_mapping(row_value, "CouchDB `_all_docs` row")
        document_value = row.get("doc")
        if document_value is None:
            continue
        document = dict(require_mapping(document_value, "CouchDB document"))
        document_id = document.get("_id")
        if isinstance(document_id, str) and document_id:
            documents[document_id] = document
    return documents


def _parent_documents(content: bytes) -> tuple[list[dict[str, object]], str | None]:
    """CouchDB `_find` responseから親document一覧を取得する。

    Args:
        content: UTF-8 JSON response body。

    Returns:
        構造を検証した親document一覧と次pageのbookmark。

    Raises:
        ValueError: responseにdocs配列がない場合。
    """
    payload = decode_json_object(content)
    docs = payload.get("docs")
    if not isinstance(docs, list):
        raise ValueError("CouchDB `_find`応答にdocsがありません")
    documents = [dict(require_mapping(document, "CouchDB parent document")) for document in docs]
    bookmark = payload.get("bookmark")
    return documents, bookmark if isinstance(bookmark, str) and bookmark else None


def _is_visible_markdown_parent(
    document: dict[str, object], exclude_prefixes: tuple[str, ...]
) -> bool:
    """LiveSync documentが公開対象Markdown親documentか判定する。

    Args:
        document: 判定対象document。
        exclude_prefixes: 除外するnote path prefix。

    Returns:
        非削除かつhiddenでないMarkdown親documentならTrue。
    """
    if document.get("type") != "plain" or document.get("deleted") is True:
        return False
    note_path = document.get("path")
    if not isinstance(note_path, str) or not note_path.lower().endswith(".md"):
        return False
    if any(note_path.startswith(prefix) for prefix in exclude_prefixes):
        return False
    return not any(segment.startswith(".") for segment in note_path.split("/"))


def _document_title(note_path: str, strategy: str) -> str:
    """Obsidian note pathを記事titleへ変換する。

    Args:
        note_path: vault rootからのnote path。
        strategy: path保持または階層連結方式。

    Returns:
        設定方式で生成した記事title。
    """
    if strategy == "path":
        return note_path
    segments = [segment for segment in note_path.split("/") if segment]
    if segments[-1].lower().endswith(".md"):
        segments[-1] = segments[-1][:-3]
    return " ".join(segments)


def _required_string(value: object, context: str) -> str:
    """外部値が空でない文字列であることを検証する。

    Args:
        value: 検証対象値。
        context: errorへ含める項目名。

    Returns:
        検証済み文字列。

    Raises:
        ValueError: 値が空または文字列でない場合。
    """
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context}が空でない文字列ではありません")
    return value
