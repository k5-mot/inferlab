#!/usr/bin/env python3
"""CouchDBの変更をllm-wiki MCP経由で同期するworker。"""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


SYSTEM_DATABASES = {"_users", "_replicator", "_global_changes", "_metadata"}
SECRET_FIELD_PATTERN = re.compile(r"(password|secret|token|key)", re.IGNORECASE)


def getenv(name: str, default: str | None = None, *, required: bool = False) -> str:
    """環境変数を取得し、必須値が空の場合は例外を送出する。

    Args:
        name: 取得する環境変数名。
        default: 環境変数が未設定または空の場合の既定値。
        required: Trueの場合、値が空ならRuntimeErrorを送出する。

    Returns:
        環境変数または既定値。

    Raises:
        RuntimeError: required=Trueで値が空の場合。
    """
    value = os.getenv(name, default or "").strip()
    if required and not value:
        raise RuntimeError(f"{name} is required")
    return value


def utc_now() -> str:
    """現在時刻をUTCのISO 8601文字列で返す。

    Returns:
        秒精度のUTC時刻文字列。
    """
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()


def read_json(path: Path, default: Any) -> Any:
    """JSONファイルを読み込み、存在しない場合は既定値を返す。

    Args:
        path: 読み込むJSONファイルのpath。
        default: ファイルが存在しない場合に返す値。

    Returns:
        読み込んだJSON値、または既定値。

    Raises:
        json.JSONDecodeError: JSONの構文が不正な場合。
    """
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: Any) -> None:
    """JSONファイルをatomicに書き込む。

    Args:
        path: 書き込み先path。
        value: JSONとして保存する値。

    Returns:
        None。

    Side Effects:
        対象ファイルと親directoryを作成または更新する。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp_path.replace(path)


def redact(value: Any) -> Any:
    """CouchDB document内のsecret系fieldを再帰的にmaskする。

    Args:
        value: 任意のJSON互換値。

    Returns:
        secret系fieldをmaskしたJSON互換値。
    """
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, child in value.items():
            if SECRET_FIELD_PATTERN.search(key):
                result[key] = "[REDACTED]"
            elif key == "_attachments":
                result[key] = "[OMITTED]"
            else:
                result[key] = redact(child)
        return result
    if isinstance(value, list):
        return [redact(item) for item in value[:100]]
    if isinstance(value, str) and len(value) > 8000:
        return value[:8000] + "...[TRUNCATED]"
    return value


def slug_part(value: str) -> str:
    """CouchDB database名またはdocument IDをwiki slugの一部へ変換する。

    Args:
        value: CouchDB由来の名前。

    Returns:
        llm-wiki slugで扱いやすい文字列。
    """
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "_", value.strip())
    cleaned = cleaned.strip("._-")
    return cleaned or "unknown"


def build_document_markdown(database: str, document: dict[str, Any]) -> str:
    """CouchDB documentをllm-wikiのdoc page Markdownへ変換する。

    Args:
        database: CouchDB database名。
        document: CouchDB document。

    Returns:
        llm-wikiへ書き込むMarkdown本文。
    """
    doc_id = str(document.get("_id", "unknown"))
    rev = str(document.get("_rev", "unknown"))
    safe_document = redact(document)
    title = f"CouchDB {database}: {doc_id}"
    summary = f"CouchDB database `{database}` の document `{doc_id}` から同期した内容。"
    body = json.dumps(safe_document, ensure_ascii=False, indent=2, sort_keys=True)
    return "\n".join(
        [
            "---",
            "type: doc",
            f"title: {json.dumps(title, ensure_ascii=False)}",
            "status: generated",
            f"summary: {json.dumps(summary, ensure_ascii=False)}",
            f"last_updated: {json.dumps(utc_now())}",
            "tags: [couchdb, synced]",
            "owner: couchdb-llmwiki-sync",
            "read_when:",
            f"  - {json.dumps(f'CouchDB document {database}/{doc_id} を確認したいとき', ensure_ascii=False)}",
            "---",
            "",
            f"# {title}",
            "",
            f"- Database: `{database}`",
            f"- Document ID: `{doc_id}`",
            f"- Revision: `{rev}`",
            f"- Synced at: `{utc_now()}`",
            "",
            "## Document",
            "",
            "```json",
            body,
            "```",
            "",
        ]
    )


def build_database_markdown(database: str, count: int) -> str:
    """CouchDB database概要をllm-wikiのdoc page Markdownへ変換する。

    Args:
        database: CouchDB database名。
        count: 今回同期したdocument件数。

    Returns:
        llm-wikiへ書き込むMarkdown本文。
    """
    title = f"CouchDB database: {database}"
    return "\n".join(
        [
            "---",
            "type: doc",
            f"title: {json.dumps(title, ensure_ascii=False)}",
            "status: generated",
            f"summary: {json.dumps(f'CouchDB database `{database}` の同期概要。', ensure_ascii=False)}",
            f"last_updated: {json.dumps(utc_now())}",
            "tags: [couchdb, synced]",
            "owner: couchdb-llmwiki-sync",
            "read_when:",
            f"  - {json.dumps(f'CouchDB database {database} の概要を確認したいとき', ensure_ascii=False)}",
            "---",
            "",
            f"# {title}",
            "",
            f"- Last synced at: `{utc_now()}`",
            f"- Documents synced in last run: `{count}`",
            "",
        ]
    )


class CouchDBClient:
    """CouchDB APIを呼び出すための最小client。"""

    def __init__(self, base_url: str, username: str, password: str, timeout: float) -> None:
        """CouchDBClientを初期化する。

        Args:
            base_url: CouchDBのbase URL。
            username: Basic認証user名。
            password: Basic認証password。
            timeout: HTTP timeout秒。

        Returns:
            None。
        """
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
        self.headers = {"Authorization": f"Basic {token}"}

    def get_json(self, path: str, query: dict[str, str | int] | None = None) -> Any:
        """CouchDBからJSON responseを取得する。

        Args:
            path: base URLからのpath。
            query: query parameter。

        Returns:
            JSONとしてdecodeしたresponse。

        Raises:
            urllib.error.URLError: HTTP通信に失敗した場合。
            json.JSONDecodeError: responseがJSONではない場合。
        """
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(url, headers=self.headers)
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            return json.loads(response.read().decode("utf-8"))

    def list_databases(self) -> list[str]:
        """同期対象のCouchDB database一覧を返す。

        Returns:
            system databaseを除外したdatabase名のlist。
        """
        databases = self.get_json("/_all_dbs")
        return [db for db in databases if isinstance(db, str) and db not in SYSTEM_DATABASES and not db.startswith("_")]

    def changes(self, database: str, since: str | int, limit: int) -> dict[str, Any]:
        """CouchDB _changes APIから変更documentを取得する。

        Args:
            database: CouchDB database名。
            since: checkpointのlast_seq。
            limit: 取得上限件数。

        Returns:
            _changes response。
        """
        encoded_db = urllib.parse.quote(database, safe="")
        return self.get_json(
            f"/{encoded_db}/_changes",
            {"include_docs": "true", "since": since, "limit": limit},
        )


class LlmWikiMcpClient:
    """llm-wikiのStreamable HTTP MCPを呼び出すclient。"""

    def __init__(self, url: str, timeout: float) -> None:
        """LlmWikiMcpClientを初期化する。

        Args:
            url: llm-wiki MCP endpoint URL。
            timeout: HTTP timeout秒。

        Returns:
            None。
        """
        self.url = url
        self.timeout = timeout
        self.session_id: str | None = None
        self.next_id = 1

    def initialize(self) -> None:
        """MCP sessionを初期化する。

        Returns:
            None。

        Raises:
            RuntimeError: MCP initializeに失敗した場合。
        """
        result, session_id = self.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "inferlab-couchdb-llmwiki-sync", "version": "0.1.0"},
            },
            allow_without_session=True,
        )
        if not session_id:
            raise RuntimeError("MCP session id was not returned")
        self.session_id = session_id
        if "serverInfo" not in result:
            raise RuntimeError("MCP initialize response did not include serverInfo")
        self.notify("notifications/initialized", {})

    def request(
        self,
        method: str,
        params: dict[str, Any],
        *,
        allow_without_session: bool = False,
    ) -> tuple[dict[str, Any], str | None]:
        """MCP JSON-RPC requestを送信する。

        Args:
            method: JSON-RPC method名。
            params: JSON-RPC params。
            allow_without_session: session初期化前のrequestを許可するか。

        Returns:
            JSON-RPC resultとresponse headerのsession id。

        Raises:
            RuntimeError: session未初期化、MCP error、またはresponse不正の場合。
        """
        if not allow_without_session and not self.session_id:
            raise RuntimeError("MCP session is not initialized")
        request_id = self.next_id
        self.next_id += 1
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        message, session_id = self.post(payload)
        if message.get("error"):
            raise RuntimeError(f"MCP error: {message['error']}")
        result = message.get("result")
        if not isinstance(result, dict):
            raise RuntimeError(f"Unexpected MCP response: {message}")
        return result, session_id

    def notify(self, method: str, params: dict[str, Any]) -> None:
        """MCP JSON-RPC notificationを送信する。

        Args:
            method: JSON-RPC method名。
            params: JSON-RPC params。

        Returns:
            None。
        """
        self.post({"jsonrpc": "2.0", "method": method, "params": params})

    def post(self, payload: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
        """MCP endpointへHTTP POSTし、SSE内のJSON-RPC messageを返す。

        Args:
            payload: JSON-RPC payload。

        Returns:
            JSON-RPC messageとresponse headerのsession id。

        Raises:
            RuntimeError: responseからJSON-RPC messageを取得できない場合。
        """
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.session_id:
            headers["mcp-session-id"] = self.session_id
        request = urllib.request.Request(self.url, data=json.dumps(payload).encode("utf-8"), headers=headers)
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            body = response.read().decode("utf-8")
            session_id = response.headers.get("mcp-session-id")
        message = parse_sse_json(body)
        if message is None:
            return {}, session_id
        return message, session_id

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        """MCP toolを呼び出す。

        Args:
            name: tool名。
            arguments: tool arguments。

        Returns:
            tools/callのresult。
        """
        result, _ = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(f"MCP tool {name} failed: {result}")
        return result

    def write_page(self, wiki: str, uri: str, content: str) -> None:
        """llm-wikiへpage contentを書き込む。

        Args:
            wiki: 対象wiki名。
            uri: page slugまたはwiki URI。
            content: Markdown本文。

        Returns:
            None。
        """
        self.call_tool("wiki_content_write", {"wiki": wiki, "uri": uri, "content": content})

    def ingest(self, wiki: str, path: str) -> None:
        """llm-wikiにpath配下のvalidate、index、commitを実行させる。

        Args:
            wiki: 対象wiki名。
            path: wiki root相対pathまたはslug。

        Returns:
            None。
        """
        self.call_tool("wiki_ingest", {"wiki": wiki, "path": path})

    def rebuild_index(self, wiki: str) -> None:
        """llm-wikiの検索indexを再構築する。

        Args:
            wiki: 対象wiki名。

        Returns:
            None。
        """
        self.call_tool("wiki_index_rebuild", {"wiki": wiki})


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


def sync_once(
    couchdb: CouchDBClient,
    llm_wiki: LlmWikiMcpClient,
    *,
    wiki: str,
    checkpoint_path: Path,
    max_docs: int,
) -> dict[str, int]:
    """CouchDBの変更を1回分LLMwikiへ同期する。

    Args:
        couchdb: CouchDB client。
        llm_wiki: llm-wiki MCP client。
        wiki: 対象wiki名。
        checkpoint_path: checkpoint保存path。
        max_docs: databaseごとの最大処理件数。

    Returns:
        database名から同期件数へのmap。
    """
    checkpoint = read_json(checkpoint_path, {})
    if not isinstance(checkpoint, dict):
        checkpoint = {}

    updated: dict[str, int] = {}
    for database in couchdb.list_databases():
        since = checkpoint.get(database, 0)
        changes = couchdb.changes(database, since, max_docs)
        results = changes.get("results", [])
        if not isinstance(results, list):
            raise RuntimeError(f"Unexpected _changes results for {database}")
        if len(results) > max_docs:
            raise RuntimeError(f"CouchDB returned too many results for {database}: {len(results)} > {max_docs}")

        count = 0
        db_slug = slug_part(database)
        for change in results:
            if not isinstance(change, dict) or change.get("deleted"):
                continue
            document = change.get("doc")
            if not isinstance(document, dict):
                continue
            doc_id = str(document.get("_id", change.get("id", "unknown")))
            uri = f"couchdb/{db_slug}/documents/{slug_part(doc_id)}"
            llm_wiki.write_page(wiki, uri, build_document_markdown(database, document))
            count += 1

        if results:
            llm_wiki.write_page(wiki, f"couchdb/{db_slug}/index", build_database_markdown(database, count))
            llm_wiki.ingest(wiki, f"couchdb/{db_slug}")
            checkpoint[database] = changes.get("last_seq", since)
            write_json(checkpoint_path, checkpoint)
            updated[database] = count

    if updated:
        llm_wiki.rebuild_index(wiki)

    return updated


def main() -> int:
    """環境変数から設定を読み、同期loopを実行する。

    Returns:
        process exit code。
    """
    couchdb = CouchDBClient(
        getenv("COUCHDB_URL", "http://couchdb:5984"),
        getenv("COUCHDB_USER", required=True),
        getenv("COUCHDB_PASSWORD", required=True),
        float(getenv("SYNC_HTTP_TIMEOUT_SECONDS", "30")),
    )
    llm_wiki = LlmWikiMcpClient(
        getenv("LLM_WIKI_MCP_URL", "http://llm-wiki:8080/mcp"),
        float(getenv("SYNC_HTTP_TIMEOUT_SECONDS", "30")),
    )
    wiki = getenv("LLM_WIKI_SPACE_NAME", "inferlab")
    checkpoint_path = Path(getenv("SYNC_CHECKPOINT_PATH", "/state/checkpoint.json"))
    health_path = Path(getenv("SYNC_HEALTH_PATH", "/state/health.json"))
    interval_seconds = int(getenv("SYNC_INTERVAL_SECONDS", "3600"))
    max_docs = int(getenv("SYNC_MAX_DOCS_PER_DATABASE", "50"))

    llm_wiki.initialize()
    while True:
        started_at = utc_now()
        try:
            updated = sync_once(couchdb, llm_wiki, wiki=wiki, checkpoint_path=checkpoint_path, max_docs=max_docs)
            write_json(health_path, {"status": "ok", "started_at": started_at, "finished_at": utc_now(), "updated": updated})
            if updated:
                print(json.dumps({"updated": updated}, ensure_ascii=False), flush=True)
        except Exception as exc:
            write_json(health_path, {"status": "error", "started_at": started_at, "finished_at": utc_now(), "error": str(exc)})
            print(f"sync failed: {exc}", file=sys.stderr, flush=True)
            if interval_seconds <= 0:
                return 1
        if interval_seconds <= 0:
            return 0
        time.sleep(interval_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
