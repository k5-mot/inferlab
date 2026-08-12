from __future__ import annotations

import uuid
import urllib.error
from typing import Any

from http_client import HttpClient


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

        Raises:
            RuntimeError: MCP initialize responseが不正な場合。

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
            raise RuntimeError(f"unexpected MCP initialize response: {response}")
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
            RuntimeError: MCP error responseを受け取った場合。
        """

        if not self.session_id:
            self.initialize()
        try:
            response = self._call_tool_once(name, arguments)
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            self.session_id = None
            self.initialize()
            response = self._call_tool_once(name, arguments)
        result = response.get("result")
        if isinstance(result, dict) and result.get("isError"):
            raise RuntimeError(f"MCP tool {name} failed: {result}")
        return result

    def _call_tool_once(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        """現在のMCP sessionでtool callを1回だけ送信する。

        Args:
            name: tool名。
            arguments: toolへ渡すarguments。

        Returns:
            JSON-RPC response。

        Raises:
            RuntimeError: MCP error responseを受け取った場合。
            urllib.error.HTTPError: HTTP errorが発生した場合。
        """

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
            raise RuntimeError(f"MCP tool {name} failed: {response['error']}")
        return response

    def write_page(self, path: str, content: str) -> None:
        """Markdown pageをllm-wikiへ書き込む。

        Args:
            path: wiki内のpage URI。
            content: Markdown本文。

        Returns:
            None。

        Side Effects:
            llm-wiki repository内のページ内容を更新する。
        """

        self.call_tool("wiki_content_write", {"wiki": self.wiki, "uri": path, "content": content})

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
