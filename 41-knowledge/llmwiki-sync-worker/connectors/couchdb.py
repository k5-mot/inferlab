from __future__ import annotations

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
        pages: list[WikiPage] = []
        skipped = 0
        for database in dbs:
            if database in exclude_databases or str(database).startswith("_"):
                continue
            previous_seq = str(next_state.get("databases", {}).get(database, "0"))
            query = urllib.parse.urlencode({"include_docs": "true", "limit": max_docs, "since": previous_seq})
            changes_url = f"{base_url}/{urllib.parse.quote(str(database), safe='')}/_changes?{query}"
            changes = self.http_client.get_json(changes_url, headers=headers)
            results = changes.get("results", [])
            db_pages = self._build_database_pages(str(database), results)
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
            title = extract_title(safe_doc, doc_id)
            content = build_markdown(
                source=self.name,
                source_type="couchdb",
                title=title,
                item_id=doc_id,
                status="deleted" if deleted else "generated",
                summary=f"CouchDB database `{database}` のdocument `{doc_id}`。",
                payload={"database": database, "sequence": result.get("seq"), "doc": safe_doc},
            )
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
