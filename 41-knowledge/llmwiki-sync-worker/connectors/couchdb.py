from __future__ import annotations

import re
import urllib.parse
from typing import Any

from connectors.base import (
    SourceConnector,
    SyncBatch,
    WikiPage,
    basic_auth_headers,
    build_markdown,
    digest_json,
    extract_title,
    redact_value,
    require_env,
    slugify,
    to_int,
)


RENDERER_VERSION = 2


class CouchDbConnector(SourceConnector):
    """CouchDB `_changes`をMarkdown pageへ変換するconnector。"""

    def sync(self, state: dict[str, Any]) -> SyncBatch:
        """CouchDBの変更差分を取得して同期batchを作る。

        Args:
            state: database別のlast sequenceを含むcheckpoint。

        Returns:
            CouchDB由来のMarkdown pageと更新後checkpoint。

        Raises:
            MissingCredentialError: 認証情報が不足している場合。
            urllib.error.URLError: CouchDB接続に失敗した場合。
        """

        base_url = str(self.source_config["base_url"]).rstrip("/")
        headers = self._headers()
        max_docs = to_int(self.source_config.get("max_docs_per_database", 50), 50)
        exclude_databases = set(self.source_config.get("exclude_databases", []))
        dbs = self.http_client.get_json(f"{base_url}/_all_dbs", headers=headers)
        next_state = self.clone_state(state)
        next_state.setdefault("databases", {})
        databases = [str(database) for database in dbs if database not in exclude_databases and not str(database).startswith("_")]
        if next_state.get("renderer_version") != RENDERER_VERSION:
            return self._sync_existing_documents(base_url, headers, max_docs, databases, next_state)
        pages: list[WikiPage] = []
        skipped = 0
        for database in databases:
            previous_seq = str(next_state.get("databases", {}).get(database, "0"))
            query = urllib.parse.urlencode({"include_docs": "true", "limit": max_docs, "since": previous_seq})
            changes_url = f"{base_url}/{urllib.parse.quote(database, safe='')}/_changes?{query}"
            changes = self.http_client.get_json(changes_url, headers=headers)
            results = changes.get("results", [])
            db_pages = self._build_database_pages(database, results)
            pages.extend(db_pages)
            if db_pages:
                next_state["databases"][database] = changes.get("last_seq", previous_seq)
            else:
                skipped += len(results)
        return SyncBatch(pages=pages, state=next_state, ingest_paths=[self.source_slug], skipped=skipped)

    def check_status(self) -> dict[str, Any]:
        """CouchDBの接続状態を確認する。

        Args:
            None。

        Returns:
            CouchDBの状態dict。

        Raises:
            MissingCredentialError: 認証情報が不足している場合。
            urllib.error.URLError: CouchDB接続に失敗した場合。
        """

        base_url = str(self.source_config["base_url"]).rstrip("/")
        data = self.http_client.get_json(f"{base_url}/_up", headers=self._headers())
        return {"source": self.name, "status": "ok", "details": data}

    def _headers(self) -> dict[str, str]:
        """CouchDB Basic認証headerを作る。

        Args:
            None。

        Returns:
            Authorization header。

        Raises:
            MissingCredentialError: 認証情報が不足している場合。
        """

        username = require_env(str(self.source_config.get("username_env", "COUCHDB_USER")))
        password = require_env(str(self.source_config.get("password_env", "COUCHDB_PASSWORD")))
        return basic_auth_headers(username, password)

    def _build_database_pages(self, database: str, results: list[dict[str, Any]]) -> list[WikiPage]:
        """CouchDB change rowsをMarkdown pagesへ変換する。

        Args:
            database: CouchDB database名。
            results: `_changes` response内のchange row一覧。

        Returns:
            LLMwikiへ書き込むpage一覧。
        """

        pages: list[WikiPage] = []
        index_rows: list[dict[str, Any]] = []
        for result in results:
            doc = result.get("doc")
            doc_id = str(result.get("id", "unknown"))
            deleted = bool(result.get("deleted") or (isinstance(doc, dict) and doc.get("_deleted")))
            if not isinstance(doc, dict):
                doc = {"_id": doc_id, "_deleted": deleted}
            safe_doc = redact_value(doc)
            safe_doc.pop("_attachments", None)
            document_text = extract_document_text(safe_doc)
            title = extract_document_title(safe_doc, doc_id)
            content = build_markdown(
                source=self.name,
                source_type="couchdb",
                title=title,
                item_id=doc_id,
                status="deleted" if deleted else "generated",
                summary=build_document_summary(database, doc_id, document_text),
                payload={"database": database, "sequence": result.get("seq"), "doc": safe_doc},
            )
            if document_text:
                content = insert_document_text(content, document_text)
            pages.append(WikiPage(path=f"{self.source_slug}/{slugify(database)}/{slugify(doc_id)}", content=content, digest=digest_json({"doc": safe_doc, "deleted": deleted})))
            index_rows.append({"id": doc_id, "title": title, "deleted": deleted})
        if index_rows:
            pages.append(
                WikiPage(
                    path=f"{self.source_slug}/{slugify(database)}/index",
                    content=build_markdown(
                        source=self.name,
                        source_type="couchdb",
                        title=f"CouchDB {database}",
                        item_id=database,
                        status="generated",
                        summary=f"CouchDB database `{database}` の同期index。",
                        payload={"database": database, "items": index_rows},
                    ),
                    digest=digest_json(index_rows),
                )
            )
        return pages

    def _sync_existing_documents(
        self,
        base_url: str,
        headers: dict[str, str],
        max_docs: int,
        databases: list[str],
        next_state: dict[str, Any],
    ) -> SyncBatch:
        """renderer更新時に既存CouchDB documentを再描画する。

        Args:
            base_url: CouchDB base URL。
            headers: CouchDB認証header。
            max_docs: 1回で処理する最大document件数。
            databases: 同期対象database一覧。
            next_state: 更新中checkpoint。

        Returns:
            再描画対象pageと更新後checkpoint。

        Raises:
            urllib.error.URLError: CouchDB接続に失敗した場合。
        """

        scan_state = next_state.setdefault("full_scan", {"database_index": 0, "skip": 0})
        database_index = int(scan_state.get("database_index", 0))
        if database_index >= len(databases):
            next_state["renderer_version"] = RENDERER_VERSION
            next_state.pop("full_scan", None)
            return SyncBatch(pages=[], state=next_state, ingest_paths=[self.source_slug], skipped=0)
        database = databases[database_index]
        skip = int(scan_state.get("skip", 0))
        query = urllib.parse.urlencode({"include_docs": "true", "limit": max_docs, "skip": skip})
        rows_url = f"{base_url}/{urllib.parse.quote(database, safe='')}/_all_docs?{query}"
        response = self.http_client.get_json(rows_url, headers=headers)
        rows = response.get("rows", [])
        total_rows = int(response.get("total_rows", 0))
        results = [row_to_change(row) for row in rows if isinstance(row, dict) and isinstance(row.get("doc"), dict)]
        pages = self._build_database_pages(database, results)
        next_skip = skip + len(rows)
        if next_skip >= total_rows:
            scan_state["database_index"] = database_index + 1
            scan_state["skip"] = 0
        else:
            scan_state["database_index"] = database_index
            scan_state["skip"] = next_skip
        if int(scan_state.get("database_index", 0)) >= len(databases):
            next_state["renderer_version"] = RENDERER_VERSION
            next_state.pop("full_scan", None)
        return SyncBatch(pages=pages, state=next_state, ingest_paths=[self.source_slug], skipped=0)


def row_to_change(row: dict[str, Any]) -> dict[str, Any]:
    """`_all_docs` rowを`_changes`相当のdictへ変換する。

    Args:
        row: CouchDB `_all_docs`のrow。

    Returns:
        `_build_database_pages`へ渡せるchange dict。
    """

    return {"id": row.get("id"), "doc": row.get("doc"), "seq": None, "deleted": False}


def extract_document_text(document: dict[str, Any]) -> str:
    """CouchDB documentからMarkdown本文として展開する文字列を取り出す。

    Args:
        document: redaction済みCouchDB document。

    Returns:
        検索対象として通常Markdownに展開する文字列。存在しない場合は空文字列。
    """

    for field in ["data", "content", "text", "body", "markdown"]:
        value = document.get(field)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def extract_document_title(document: dict[str, Any], fallback: str) -> str:
    """CouchDB documentから検索しやすいtitleを抽出する。

    Args:
        document: redaction済みCouchDB document。
        fallback: title候補が見つからない場合の値。

    Returns:
        page title。
    """

    explicit_title = extract_title(document, "")
    if explicit_title:
        return explicit_title
    document_text = extract_document_text(document)
    for line in document_text.splitlines():
        stripped = line.strip().strip("#").strip()
        if stripped:
            return stripped[:80]
    return fallback


def build_document_summary(database: str, doc_id: str, document_text: str) -> str:
    """CouchDB document pageのsummaryを作る。

    Args:
        database: CouchDB database名。
        doc_id: CouchDB document ID。
        document_text: document本文。

    Returns:
        frontmatter summary。
    """

    excerpt = normalize_excerpt(document_text)
    if excerpt:
        return f"CouchDB database `{database}` のdocument `{doc_id}`。{excerpt}"
    return f"CouchDB database `{database}` のdocument `{doc_id}`。"


def normalize_excerpt(text: str) -> str:
    """Markdown本文からsummary向けの短いexcerptを作る。

    Args:
        text: document本文。

    Returns:
        改行と空白を正規化したexcerpt。
    """

    normalized = re.sub(r"\s+", " ", text).strip()
    return normalized[:240]


def insert_document_text(content: str, document_text: str) -> str:
    """生成済みMarkdownへ検索用の通常本文sectionを差し込む。

    Args:
        content: `build_markdown`で生成したMarkdown。
        document_text: CouchDB documentから抽出した本文。

    Returns:
        通常本文sectionを含むMarkdown。
    """

    marker = "## Payload\n\n"
    section = f"## Document Text\n\n{document_text}\n\n"
    return content.replace(marker, section + marker, 1)
