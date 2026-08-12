#!/usr/bin/env python3
from __future__ import annotations

import base64
import copy
import datetime as dt
import hashlib
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


SECRET_FIELD_RE = re.compile(r"(password|secret|token|key|authorization|cookie|session)", re.IGNORECASE)
ENV_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")


@dataclass
class WikiPage:
    """LLMwikiへ書き込む1ページの内容を表す。

    Args:
        path: wiki内のページpath。
        content: Markdown本文。
        digest: 同期元内容から計算した変更検知用hash。

    Returns:
        dataclassのため戻り値はない。
    """

    path: str
    content: str
    digest: str


@dataclass
class SyncBatch:
    """データソース1件分の同期結果候補を表す。

    Args:
        pages: LLMwikiへ書き込むページ一覧。
        state: 同期成功後に保存するcheckpoint状態。
        ingest_paths: 書き込み後に`wiki_ingest`するpath一覧。
        skipped: 変更なしとしてskipした件数。

    Returns:
        dataclassのため戻り値はない。
    """

    pages: list[WikiPage]
    state: dict[str, Any]
    ingest_paths: list[str]
    skipped: int = 0


class SyncError(Exception):
    """同期処理で復旧可能な失敗を呼び出し元へ伝える例外。"""


class MissingCredentialError(SyncError):
    """有効化済みデータソースの認証情報不足を表す例外。"""


class HttpClient:
    """標準ライブラリだけでHTTP requestを実行するclient。"""

    def __init__(self, timeout_seconds: int) -> None:
        """HTTP clientを初期化する。

        Args:
            timeout_seconds: requestごとのtimeout秒数。

        Returns:
            None。
        """

        self.timeout_seconds = timeout_seconds

    def request(
        self,
        method: str,
        url: str,
        *,
        headers: dict[str, str] | None = None,
        body: bytes | None = None,
        verify_tls: bool = True,
    ) -> tuple[bytes, dict[str, str]]:
        """HTTP requestを実行してresponse bodyとheaderを返す。

        Args:
            method: HTTP method。
            url: request先URL。
            headers: HTTP header。
            body: request body。
            verify_tls: HTTPS証明書検証を有効化するか。

        Returns:
            response bodyのbytesとresponse header。

        Raises:
            urllib.error.URLError: 接続失敗やHTTP errorが発生した場合。
        """

        request = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
        context = None
        if not verify_tls:
            context = ssl._create_unverified_context()
        with urllib.request.urlopen(request, timeout=self.timeout_seconds, context=context) as response:
            return response.read(), {key.lower(): value for key, value in response.headers.items()}

    def get_json(
        self,
        url: str,
        *,
        headers: dict[str, str] | None = None,
        verify_tls: bool = True,
    ) -> Any:
        """JSON endpointをGETしてdecode済み値を返す。

        Args:
            url: request先URL。
            headers: HTTP header。
            verify_tls: HTTPS証明書検証を有効化するか。

        Returns:
            JSON decode後のPython値。

        Raises:
            json.JSONDecodeError: response bodyがJSONでない場合。
            urllib.error.URLError: 接続失敗やHTTP errorが発生した場合。
        """

        body, _ = self.request("GET", url, headers=headers, verify_tls=verify_tls)
        return json.loads(body.decode("utf-8"))

    def post_json(self, url: str, payload: dict[str, Any], *, headers: dict[str, str] | None = None) -> tuple[Any, dict[str, str]]:
        """JSON bodyをPOSTしてdecode済みresponseとheaderを返す。

        Args:
            url: request先URL。
            payload: JSON bodyにする値。
            headers: 追加HTTP header。

        Returns:
            JSON responseとresponse header。空bodyの場合のresponseは空dict。

        Raises:
            json.JSONDecodeError: response bodyがJSONでない場合。
            urllib.error.URLError: 接続失敗やHTTP errorが発生した場合。
        """

        merged_headers = {"Content-Type": "application/json", **(headers or {})}
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        response, response_headers = self.request("POST", url, headers=merged_headers, body=body)
        if not response:
            return {}, response_headers
        response_text = response.decode("utf-8")
        parsed = parse_sse_json(response_text)
        if parsed is not None:
            return parsed, response_headers
        return json.loads(response_text), response_headers

    def propfind(
        self,
        url: str,
        *,
        headers: dict[str, str],
        depth: str,
        verify_tls: bool,
    ) -> bytes:
        """WebDAV PROPFINDを実行してXML bodyを返す。

        Args:
            url: request先URL。
            headers: 認証などのHTTP header。
            depth: WebDAV Depth header値。
            verify_tls: HTTPS証明書検証を有効化するか。

        Returns:
            XML response body。

        Raises:
            urllib.error.URLError: 接続失敗やHTTP errorが発生した場合。
        """

        body = (
            '<?xml version="1.0"?>'
            '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" '
            'xmlns:nc="http://nextcloud.org/ns">'
            "<d:prop>"
            "<d:displayname />"
            "<d:getlastmodified />"
            "<d:getcontentlength />"
            "<d:getcontenttype />"
            "<d:resourcetype />"
            "</d:prop>"
            "</d:propfind>"
        ).encode("utf-8")
        merged_headers = {"Depth": depth, "Content-Type": "application/xml", **headers}
        body, _ = self.request("PROPFIND", url, headers=merged_headers, body=body, verify_tls=verify_tls)
        return body


class LlmWikiClient:
    """llm-wiki MCP endpointだけを使うclient。"""

    def __init__(self, mcp_url: str, wiki: str, http_client: HttpClient) -> None:
        """MCP clientを初期化する。

        Args:
            mcp_url: llm-wiki HTTP MCP endpoint。
            wiki: 書き込み先wiki名。
            http_client: HTTP request実行に使うclient。

        Returns:
            None。
        """

        self.mcp_url = mcp_url
        self.wiki = wiki
        self.http_client = http_client
        self.session_id: str | None = None

    def initialize(self) -> None:
        """MCP sessionを開始する。

        Args:
            None。

        Returns:
            None。

        Side Effects:
            llm-wiki MCP serverへinitialize通知を送信し、session idを保持する。
        """

        payload = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "llmwiki-sync-worker", "version": "1.0.0"},
            },
        }
        response, response_headers = self.http_client.post_json(
            self.mcp_url,
            payload,
            headers={"Accept": "application/json, text/event-stream"},
        )
        session_header = response_headers.get("mcp-session-id")
        if isinstance(session_header, str):
            self.session_id = session_header
        if "serverInfo" not in response.get("result", {}):
            raise SyncError(f"unexpected MCP initialize response: {response}")
        self.notify_initialized()

    def notify_initialized(self) -> None:
        """MCP initialized notificationを送信する。

        Args:
            None。

        Returns:
            None。

        Side Effects:
            llm-wiki MCP serverへnotificationを送る。
        """

        payload = {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
        headers = {"Accept": "application/json, text/event-stream"}
        if self.session_id:
            headers["mcp-session-id"] = self.session_id
        self.http_client.post_json(self.mcp_url, payload, headers=headers)

    def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
        """MCP toolを呼び出す。

        Args:
            name: tool名。
            arguments: toolへ渡すarguments。

        Returns:
            MCP result。

        Raises:
            SyncError: MCP error responseを受け取った場合。
        """

        if not self.session_id:
            self.initialize()
        payload = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }
        headers = {"Accept": "application/json, text/event-stream"}
        if self.session_id:
            headers["mcp-session-id"] = self.session_id
        response, _ = self.http_client.post_json(self.mcp_url, payload, headers=headers)
        if "error" in response:
            raise SyncError(f"MCP tool {name} failed: {response['error']}")
        result = response.get("result")
        if isinstance(result, dict) and result.get("isError"):
            raise SyncError(f"MCP tool {name} failed: {result}")
        return result

    def write_page(self, page: WikiPage) -> None:
        """Markdown pageをllm-wikiへ書き込む。

        Args:
            page: 書き込み対象ページ。

        Returns:
            None。

        Side Effects:
            llm-wiki repository内のページ内容を更新する。
        """

        self.call_tool(
            "wiki_content_write",
            {"wiki": self.wiki, "uri": page.path, "content": page.content},
        )

    def ingest(self, path: str) -> None:
        """指定pathをllm-wikiへingestする。

        Args:
            path: ingest対象path。

        Returns:
            None。

        Side Effects:
            validate、index更新、Git commitをllm-wiki側で実行する。
        """

        self.call_tool("wiki_ingest", {"wiki": self.wiki, "path": path})

    def rebuild_index(self) -> None:
        """llm-wikiのindexを再構築する。

        Args:
            None。

        Returns:
            None。

        Side Effects:
            llm-wikiの検索indexを再構築する。
        """

        self.call_tool("wiki_index_rebuild", {"wiki": self.wiki})


class SourceAdapter:
    """データソース固有処理を隠蔽するadapterの基底class。"""

    def __init__(self, source_config: dict[str, Any], http_client: HttpClient) -> None:
        """adapterを初期化する。

        Args:
            source_config: config.yaml内のsource定義。
            http_client: HTTP request実行に使うclient。

        Returns:
            None。
        """

        self.source_config = source_config
        self.http_client = http_client
        self.name = str(source_config["name"])
        self.source_slug = slugify(self.name)

    def sync(self, state: dict[str, Any]) -> SyncBatch:
        """同期対象ページと次回checkpointを作る。

        Args:
            state: 前回成功時のsource別checkpoint。

        Returns:
            書き込み対象pageと更新後state。

        Raises:
            NotImplementedError: 派生classが実装していない場合。
        """

        raise NotImplementedError


class CouchDbSource(SourceAdapter):
    """CouchDB `_changes`をMarkdown pageへ変換するadapter。"""

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
        username = require_env(str(self.source_config.get("username_env", "COUCHDB_USER")))
        password = require_env(str(self.source_config.get("password_env", "COUCHDB_PASSWORD")))
        max_docs = to_int(self.source_config.get("max_docs_per_database", 50), 50)
        exclude_databases = set(self.source_config.get("exclude_databases", []))
        headers = basic_auth_headers(username, password)
        dbs = self.http_client.get_json(f"{base_url}/_all_dbs", headers=headers)
        next_state = copy.deepcopy(state)
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
            page_path = f"{self.source_slug}/{slugify(database)}/{slugify(doc_id)}"
            content = build_markdown(
                source=self.name,
                source_type="couchdb",
                title=title,
                item_id=doc_id,
                status="deleted" if deleted else "generated",
                summary=f"CouchDB database `{database}` のdocument `{doc_id}`。",
                payload={"database": database, "sequence": result.get("seq"), "doc": safe_doc},
            )
            pages.append(WikiPage(path=page_path, content=content, digest=digest_json({"doc": safe_doc, "deleted": deleted})))
            index_rows.append({"id": doc_id, "title": title, "deleted": deleted})

        if index_rows:
            content = build_markdown(
                source=self.name,
                source_type="couchdb",
                title=f"CouchDB {database}",
                item_id=database,
                status="generated",
                summary=f"CouchDB database `{database}` の同期index。",
                payload={"database": database, "items": index_rows},
            )
            pages.append(
                WikiPage(
                    path=f"{self.source_slug}/{slugify(database)}/index",
                    content=content,
                    digest=digest_json(index_rows),
                )
            )
        return pages


class HttpJsonSource(SourceAdapter):
    """JSON REST endpointをMarkdown pageへ変換するadapter。"""

    def sync(self, state: dict[str, Any]) -> SyncBatch:
        """設定されたJSON endpointを取得して同期batchを作る。

        Args:
            state: endpoint item別hashを含むcheckpoint。

        Returns:
            JSON REST由来のMarkdown pageと更新後checkpoint。

        Raises:
            MissingCredentialError: 認証情報が不足している場合。
            urllib.error.URLError: REST endpoint接続に失敗した場合。
        """

        base_url = str(self.source_config["base_url"]).rstrip("/")
        verify_tls = to_bool(self.source_config.get("verify_tls", True))
        headers = auth_headers(self.source_config.get("auth", {}))
        next_state = copy.deepcopy(state)
        next_state.setdefault("items", {})
        pages: list[WikiPage] = []
        skipped = 0
        for endpoint in self.source_config.get("endpoints", []):
            endpoint_name = str(endpoint["name"])
            endpoint_slug = slugify(endpoint_name)
            url = build_url(base_url, str(endpoint["path"]), endpoint.get("query", {}))
            data = self.http_client.get_json(url, headers=headers, verify_tls=verify_tls)
            items = extract_items(data, endpoint.get("items_path", ""))
            max_items = to_int(endpoint.get("max_items", len(items)), len(items))
            selected_items = items[:max_items]
            index_rows: list[dict[str, Any]] = []
            endpoint_changed = False
            for item in selected_items:
                safe_item = redact_value(item)
                item_id = pick_first(safe_item, endpoint.get("id_fields", ["id"])) or digest_json(safe_item)[:12]
                title = pick_first(safe_item, endpoint.get("title_fields", ["name", "title", "id"])) or str(item_id)
                state_key = f"{endpoint_slug}:{item_id}"
                item_digest = digest_json(safe_item)
                index_rows.append({"id": item_id, "title": title, "path": f"{self.source_slug}/{endpoint_slug}/{slugify(str(item_id))}"})
                if next_state["items"].get(state_key) == item_digest:
                    skipped += 1
                    continue
                page_path = f"{self.source_slug}/{endpoint_slug}/{slugify(str(item_id))}"
                content = build_markdown(
                    source=self.name,
                    source_type=str(self.source_config.get("type", "http_json")),
                    title=str(title),
                    item_id=str(item_id),
                    status="generated",
                    summary=f"{self.name} `{endpoint_name}` endpointから取得したitem。",
                    payload={"endpoint": endpoint_name, "item": safe_item},
                )
                pages.append(WikiPage(path=page_path, content=content, digest=item_digest))
                next_state["items"][state_key] = item_digest
                endpoint_changed = True

            if endpoint_changed:
                index_digest = digest_json(index_rows)
                pages.append(
                    WikiPage(
                        path=f"{self.source_slug}/{endpoint_slug}/index",
                        content=build_markdown(
                            source=self.name,
                            source_type=str(self.source_config.get("type", "http_json")),
                            title=f"{self.name} {endpoint_name}",
                            item_id=endpoint_name,
                            status="generated",
                            summary=f"{self.name} `{endpoint_name}` endpointの同期index。",
                            payload={"endpoint": endpoint_name, "items": index_rows},
                        ),
                        digest=index_digest,
                    )
                )
        return SyncBatch(pages=pages, state=next_state, ingest_paths=[self.source_slug], skipped=skipped)


class NextcloudWebDavSource(SourceAdapter):
    """Nextcloud WebDAV metadataをMarkdown pageへ変換するadapter。"""

    def sync(self, state: dict[str, Any]) -> SyncBatch:
        """Nextcloud WebDAV PROPFIND結果から同期batchを作る。

        Args:
            state: file path別hashを含むcheckpoint。

        Returns:
            Nextcloud由来のMarkdown pageと更新後checkpoint。

        Raises:
            MissingCredentialError: 認証情報が不足している場合。
            urllib.error.URLError: WebDAV接続に失敗した場合。
            xml.etree.ElementTree.ParseError: WebDAV response XMLがparseできない場合。
        """

        base_url = str(self.source_config["base_url"]).rstrip("/")
        username = require_env(str(self.source_config.get("username_env", "NEXTCLOUD_LLMWIKI_USER")))
        password = require_env(str(self.source_config.get("password_env", "NEXTCLOUD_LLMWIKI_PASSWORD")))
        root_path = normalize_webdav_root(str(self.source_config.get("root_path", "/")))
        depth = str(self.source_config.get("depth", "1"))
        verify_tls = to_bool(self.source_config.get("verify_tls", True))
        max_items = to_int(self.source_config.get("max_items", 50), 50)
        headers = basic_auth_headers(username, password)
        dav_path = f"/remote.php/dav/files/{urllib.parse.quote(username, safe='')}{urllib.parse.quote(root_path, safe='/')}"
        xml_body = self.http_client.propfind(f"{base_url}{dav_path}", headers=headers, depth=depth, verify_tls=verify_tls)
        entries = parse_webdav_entries(xml_body, root_path)[:max_items]
        next_state = copy.deepcopy(state)
        next_state.setdefault("items", {})
        pages: list[WikiPage] = []
        skipped = 0
        index_rows: list[dict[str, Any]] = []
        changed = False
        for entry in entries:
            item_id = entry["href"]
            title = entry.get("displayname") or item_id
            item_digest = digest_json(entry)
            index_rows.append({"id": item_id, "title": title, "type": entry.get("type")})
            if next_state["items"].get(item_id) == item_digest:
                skipped += 1
                continue
            page_path = f"{self.source_slug}/files/{slugify(item_id)}"
            content = build_markdown(
                source=self.name,
                source_type="nextcloud_webdav",
                title=str(title),
                item_id=item_id,
                status="generated",
                summary=f"Nextcloud WebDAV `{root_path}` 配下のmetadata。",
                payload={"entry": entry},
            )
            pages.append(WikiPage(path=page_path, content=content, digest=item_digest))
            next_state["items"][item_id] = item_digest
            changed = True

        if changed:
            pages.append(
                WikiPage(
                    path=f"{self.source_slug}/files/index",
                    content=build_markdown(
                        source=self.name,
                        source_type="nextcloud_webdav",
                        title=f"{self.name} files",
                        item_id=root_path,
                        status="generated",
                        summary="Nextcloud WebDAV metadataの同期index。",
                        payload={"root_path": root_path, "items": index_rows},
                    ),
                    digest=digest_json(index_rows),
                )
            )
        return SyncBatch(pages=pages, state=next_state, ingest_paths=[self.source_slug], skipped=skipped)


def load_config(path: Path) -> dict[str, Any]:
    """YAML設定を読み込み、環境変数展開後のdictを返す。

    Args:
        path: config.yamlのpath。

    Returns:
        設定dict。

    Raises:
        FileNotFoundError: 設定fileが存在しない場合。
        yaml.YAMLError: YAML parseに失敗した場合。
    """

    raw_config = yaml.safe_load(path.read_text(encoding="utf-8"))
    return expand_env(raw_config)


def expand_env(value: Any) -> Any:
    """設定値内の`${VAR}`または`${VAR:-default}`を再帰的に展開する。

    Args:
        value: 展開対象の任意値。

    Returns:
        環境変数展開後の値。
    """

    if isinstance(value, dict):
        return {key: expand_env(item) for key, item in value.items()}
    if isinstance(value, list):
        return [expand_env(item) for item in value]
    if isinstance(value, str):
        return ENV_RE.sub(lambda match: os.getenv(match.group(1), match.group(2) or ""), value)
    return value


def read_state(path: Path) -> dict[str, Any]:
    """checkpoint fileを読み込む。

    Args:
        path: checkpoint JSON fileのpath。

    Returns:
        checkpoint dict。存在しない場合は空dict。
    """

    if not path.exists():
        return {"sources": {}}
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"sources": {}}
    if "sources" not in state:
        return {"sources": {}, "legacy_couchdb": state}
    return state


def write_json(path: Path, value: dict[str, Any]) -> None:
    """JSON fileへatomicに近い形で値を書き込む。

    Args:
        path: 書き込み先path。
        value: JSON化するdict。

    Returns:
        None。

    Side Effects:
        file system上のJSON fileを更新する。
    """

    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_suffix(path.suffix + ".tmp")
    temp_path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temp_path.replace(path)


def require_env(name: str) -> str:
    """必須環境変数を取得する。

    Args:
        name: 環境変数名。

    Returns:
        環境変数値。

    Raises:
        MissingCredentialError: 値が空の場合。
    """

    value = os.getenv(name, "")
    if not value:
        raise MissingCredentialError(f"required environment variable is empty: {name}")
    return value


def to_bool(value: Any) -> bool:
    """設定値をboolへ変換する。

    Args:
        value: boolまたは文字列表現。

    Returns:
        bool値。
    """

    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def to_int(value: Any, default: int) -> int:
    """設定値をintへ変換する。

    Args:
        value: intまたは文字列表現。
        default: 変換できない場合の既定値。

    Returns:
        int値。
    """

    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def slugify(value: str) -> str:
    """wiki pathで使えるslugへ変換する。

    Args:
        value: 変換元文字列。

    Returns:
        path segmentとして扱いやすいslug。
    """

    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", value.strip()).strip("-_")
    return slug[:120] or "item"


def digest_json(value: Any) -> str:
    """JSON正規化した値のSHA-256 hashを返す。

    Args:
        value: hash化する値。

    Returns:
        SHA-256 hexadecimal digest。
    """

    body = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(body).hexdigest()


def redact_value(value: Any) -> Any:
    """secretらしいfieldと添付本文を取り除いた値を返す。

    Args:
        value: redaction対象。

    Returns:
        secretを伏せたcopy。
    """

    if isinstance(value, dict):
        redacted: dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            if SECRET_FIELD_RE.search(key_text):
                redacted[key_text] = "[REDACTED]"
            elif key_text in {"_attachments", "attachments"}:
                redacted[key_text] = "[OMITTED]"
            else:
                redacted[key_text] = redact_value(item)
        return redacted
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    return value


def build_markdown(
    *,
    source: str,
    source_type: str,
    title: str,
    item_id: str,
    status: str,
    summary: str,
    payload: dict[str, Any],
) -> str:
    """同期対象itemをLLMwiki向けMarkdownへ整形する。

    Args:
        source: source名。
        source_type: source adapter種別。
        title: page title。
        item_id: source内item識別子。
        status: page状態。
        summary: LLM向け要約。
        payload: 詳細payload。

    Returns:
        frontmatter付きMarkdown本文。
    """

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    frontmatter = {
        "type": "doc",
        "title": title,
        "status": status,
        "summary": summary,
        "tags": ["llmwiki-sync", slugify(source)],
        "owner": "llmwiki-sync-worker",
        "source": source,
        "source_type": source_type,
        "source_id": item_id,
        "generated_at": now,
        "read_when": [
            f"{source}の同期内容を確認するとき",
            "Hermes-AgentやOpenClawが外部サービスの状態を検索するとき",
        ],
    }
    return (
        "---\n"
        f"{yaml.safe_dump(frontmatter, allow_unicode=True, sort_keys=False)}"
        "---\n\n"
        f"# {title}\n\n"
        f"{summary}\n\n"
        "## Payload\n\n"
        "```json\n"
        f"{json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)}\n"
        "```\n"
    )


def basic_auth_headers(username: str, password: str) -> dict[str, str]:
    """Basic認証headerを作る。

    Args:
        username: user名。
        password: passwordまたはAPI key。

    Returns:
        Authorization headerを含むdict。
    """

    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return {"Authorization": f"Basic {token}"}


def auth_headers(auth_config: dict[str, Any] | None) -> dict[str, str]:
    """設定された認証方式からHTTP headerを作る。

    Args:
        auth_config: source設定内のauth定義。

    Returns:
        認証HTTP header。

    Raises:
        MissingCredentialError: 有効な認証方式で必要な環境変数が空の場合。
    """

    if not auth_config:
        return {}
    auth_type = str(auth_config.get("type", "none"))
    if auth_type == "none":
        return {}
    if auth_type == "basic":
        return basic_auth_headers(
            require_env(str(auth_config.get("username_env", ""))),
            require_env(str(auth_config.get("password_env", ""))),
        )
    if auth_type == "bearer":
        return {"Authorization": f"Bearer {require_env(str(auth_config.get('token_env', '')))}"}
    if auth_type == "private_token":
        return {"PRIVATE-TOKEN": require_env(str(auth_config.get("token_env", "")))}
    if auth_type == "bookstack_token":
        token_id = require_env(str(auth_config.get("token_id_env", "")))
        token_secret = require_env(str(auth_config.get("token_secret_env", "")))
        return {"Authorization": f"Token {token_id}:{token_secret}"}
    raise SyncError(f"unsupported auth type: {auth_type}")


def build_url(base_url: str, path: str, query: dict[str, Any] | None) -> str:
    """base URL、path、queryからrequest URLを作る。

    Args:
        base_url: service base URL。
        path: endpoint path。
        query: query parameter。

    Returns:
        完成したURL。
    """

    normalized_path = "/" + path.lstrip("/")
    pairs: list[tuple[str, str]] = []
    for key, value in (query or {}).items():
        if value in ("", None):
            continue
        if isinstance(value, bool):
            pairs.append((key, "true" if value else "false"))
        elif isinstance(value, (dict, list)):
            pairs.append((key, json.dumps(value, ensure_ascii=False)))
        else:
            pairs.append((key, str(value)))
    encoded_query = urllib.parse.urlencode(pairs)
    return f"{base_url}{normalized_path}" + (f"?{encoded_query}" if encoded_query else "")


def extract_items(data: Any, path: str) -> list[Any]:
    """JSON値からitems配列を取り出す。

    Args:
        data: JSON decode後の値。
        path: dot区切りの取得path。空の場合はroot。

    Returns:
        item一覧。対象がdictの場合は1件配列に包む。
    """

    current = data
    if path:
        for part in path.split("."):
            if part == "":
                continue
            if not isinstance(current, dict):
                return []
            current = current.get(part, [])
    if isinstance(current, list):
        return current
    if isinstance(current, dict):
        return [current]
    return []


def pick_first(item: Any, fields: list[str]) -> str | None:
    """dictから最初に見つかったfield値を文字列として返す。

    Args:
        item: 参照対象。
        fields: 候補field名一覧。

    Returns:
        見つかった値。存在しない場合はNone。
    """

    if not isinstance(item, dict):
        return None
    for field in fields:
        value = item.get(field)
        if value not in ("", None):
            return str(value)
    return None


def extract_title(item: Any, fallback: str) -> str:
    """同期itemからtitle候補を抽出する。

    Args:
        item: 参照対象。
        fallback: title候補がない場合の値。

    Returns:
        page title。
    """

    return pick_first(item, ["title", "name", "subject", "_id", "id"]) or fallback


def normalize_webdav_root(root_path: str) -> str:
    """Nextcloud WebDAV root pathを正規化する。

    Args:
        root_path: 設定上のroot path。

    Returns:
        先頭と末尾に`/`を持つpath。
    """

    stripped = root_path.strip()
    if stripped in {"", "/"}:
        return "/"
    return "/" + stripped.strip("/") + "/"


def parse_webdav_entries(xml_body: bytes, root_path: str) -> list[dict[str, Any]]:
    """WebDAV multistatus XMLからfile metadata一覧を取り出す。

    Args:
        xml_body: PROPFIND response body。
        root_path: requestしたroot path。

    Returns:
        fileまたはdirectoryのmetadata一覧。

    Raises:
        xml.etree.ElementTree.ParseError: XML parseに失敗した場合。
    """

    root = ET.fromstring(xml_body)
    entries: list[dict[str, Any]] = []
    for response in root:
        if local_name(response.tag) != "response":
            continue
        entry = parse_webdav_response(response)
        if entry and entry.get("href") != root_path:
            entries.append(entry)
    return entries


def parse_sse_json(body: str) -> dict[str, Any] | None:
    """SSE response bodyから最後のJSON data eventを取り出す。

    Args:
        body: text/event-stream response body。

    Returns:
        JSON-RPC message。JSON dataがない場合はNone。

    Raises:
        json.JSONDecodeError: data eventが不正なJSONの場合。
    """

    messages: list[dict[str, Any]] = []
    for line in body.splitlines():
        if not line.startswith("data:"):
            continue
        data = line.removeprefix("data:").strip()
        if not data or data == "[DONE]":
            continue
        messages.append(json.loads(data))
    return messages[-1] if messages else None


def parse_webdav_response(response: ET.Element) -> dict[str, Any] | None:
    """WebDAV response要素をmetadata dictへ変換する。

    Args:
        response: WebDAV response XML要素。

    Returns:
        metadata dict。hrefがない場合はNone。
    """

    href = ""
    props: dict[str, Any] = {}
    for child in response.iter():
        name = local_name(child.tag)
        if name == "href" and child.text:
            href = urllib.parse.unquote(child.text)
        elif name in {"displayname", "getlastmodified", "getcontentlength", "getcontenttype"} and child.text:
            props[name] = child.text
        elif name == "collection":
            props["type"] = "directory"
    if not href:
        return None
    props.setdefault("type", "file")
    props["href"] = href
    return props


def local_name(tag: str) -> str:
    """XML tagからnamespaceを除いたlocal nameを返す。

    Args:
        tag: XML tag名。

    Returns:
        namespace除去後の名前。
    """

    return tag.rsplit("}", 1)[-1]


def create_adapter(source_config: dict[str, Any], http_client: HttpClient) -> SourceAdapter:
    """source typeに対応するadapterを作る。

    Args:
        source_config: config.yaml内のsource定義。
        http_client: HTTP request実行に使うclient。

    Returns:
        SourceAdapter実装。

    Raises:
        SyncError: 未対応source typeが指定された場合。
    """

    source_type = str(source_config.get("type", ""))
    if source_type == "couchdb":
        return CouchDbSource(source_config, http_client)
    if source_type == "http_json":
        return HttpJsonSource(source_config, http_client)
    if source_type == "nextcloud_webdav":
        return NextcloudWebDavSource(source_config, http_client)
    raise SyncError(f"unsupported source type: {source_type}")


def source_state_for(state: dict[str, Any], source_name: str) -> dict[str, Any]:
    """source別checkpointを取り出す。

    Args:
        state: checkpoint全体。
        source_name: source名。

    Returns:
        source別checkpoint。旧CouchDB専用形式の場合は互換変換した値。
    """

    sources = state.setdefault("sources", {})
    if source_name in sources:
        return copy.deepcopy(sources[source_name])
    if source_name == "couchdb" and isinstance(state.get("legacy_couchdb"), dict):
        return {"databases": state["legacy_couchdb"]}
    return {}


def run_once(config: dict[str, Any]) -> dict[str, Any]:
    """全enabled sourceを1回同期する。

    Args:
        config: 展開済み設定dict。

    Returns:
        health fileへ保存する実行結果。

    Side Effects:
        llm-wiki page、checkpoint、health JSONを更新する。
    """

    worker_config = config.get("worker", {})
    checkpoint_path = Path(str(worker_config.get("checkpoint_path", "/state/checkpoint.json")))
    health_path = Path(str(worker_config.get("health_path", "/state/health.json")))
    http_client = HttpClient(to_int(worker_config.get("http_timeout_seconds", 30), 30))
    wiki_config = config.get("llm_wiki", {})
    llmwiki = LlmWikiClient(str(wiki_config["mcp_url"]), str(wiki_config["wiki"]), http_client)
    state = read_state(checkpoint_path)
    started_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    source_results: list[dict[str, Any]] = []
    any_error = False
    any_updates = False

    for source_config in config.get("sources", []):
        source_name = str(source_config.get("name", "unnamed"))
        if not to_bool(source_config.get("enabled", False)):
            source_results.append({"source": source_name, "status": "disabled", "updated": 0, "skipped": 0})
            continue
        try:
            adapter = create_adapter(source_config, http_client)
            batch = adapter.sync(source_state_for(state, source_name))
            for page in batch.pages:
                llmwiki.write_page(page)
            if batch.pages:
                for ingest_path in batch.ingest_paths:
                    llmwiki.ingest(ingest_path)
                any_updates = True
            state.setdefault("sources", {})[source_name] = batch.state
            write_json(checkpoint_path, state)
            source_results.append(
                {
                    "source": source_name,
                    "status": "ok",
                    "updated": len(batch.pages),
                    "skipped": batch.skipped,
                    "ingested": batch.ingest_paths if batch.pages else [],
                }
            )
        except MissingCredentialError as exc:
            any_error = True
            source_results.append({"source": source_name, "status": "credential_error", "error": str(exc)})
        except (SyncError, urllib.error.URLError, ET.ParseError, json.JSONDecodeError) as exc:
            any_error = True
            source_results.append({"source": source_name, "status": "error", "error": str(exc)})

    if any_updates:
        llmwiki.rebuild_index()

    status = "degraded" if any_error else "ok"
    health = {"status": status, "started_at": started_at, "finished_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(), "sources": source_results}
    write_json(health_path, health)
    print(json.dumps(health, ensure_ascii=False, sort_keys=True), flush=True)
    return health


def sleep_between_runs(interval_seconds: int) -> bool:
    """次回実行まで待機する。

    Args:
        interval_seconds: 待機秒数。0以下なら継続しない。

    Returns:
        待機した場合はTrue、終了すべき場合はFalse。
    """

    if interval_seconds <= 0:
        return False
    time.sleep(interval_seconds)
    return True


def main() -> int:
    """sync-workerのentrypoint。

    Args:
        None。

    Returns:
        process exit code。
    """

    config_path = Path(os.getenv("SYNC_CONFIG_PATH", "/config/config.yaml"))
    while True:
        config = load_config(config_path)
        run_once(config)
        interval = to_int(config.get("worker", {}).get("interval_seconds", 3600), 3600)
        if not sleep_between_runs(interval):
            return 0


if __name__ == "__main__":
    sys.exit(main())
