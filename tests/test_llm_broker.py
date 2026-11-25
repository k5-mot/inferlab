"""llm-brokerのtest。

brokerはLiteLLM master keyを保持し、接続元OS userを`/proc/net/tcp`で判定する。
loopback上の偽LiteLLMを使い、keyの付け替え、route制限、trace userの付与を検査する。
"""

from __future__ import annotations

import http.client
import http.server
import importlib.util
import json
import os
import sys
import threading
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any, ClassVar

BROKER = (
    Path(__file__).resolve().parents[1]
    / "20-owui"
    / "open-terminal"
    / "broker"
    / "llm_broker.py"
)


def load_broker() -> ModuleType:
    """brokerをmoduleとして読み込む。

    Returns:
        読み込んだmodule。

    Raises:
        RuntimeError: module specを作成できない場合。
    """
    spec = importlib.util.spec_from_file_location("llm_broker", BROKER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {BROKER}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


broker = load_broker()


class FakeLiteLLM(http.server.BaseHTTPRequestHandler):
    """受け取ったrequestを記録し、pathを返す偽LiteLLM。"""

    requests: ClassVar[list[dict[str, Any]]] = []

    def do_GET(self) -> None:
        """GETを記録して応答する。"""
        self.respond()

    def do_POST(self) -> None:
        """POSTを記録して応答する。"""
        self.respond()

    def log_message(self, format: str, *args: Any) -> None:
        """test出力を汚さないため、access logを出さない。

        Args:
            format: 未使用。
            args: 未使用。
        """

    def respond(self) -> None:
        """requestを記録し、pathをJSONで返す。"""
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        FakeLiteLLM.requests.append({"path": self.path, "headers": dict(self.headers)})
        data = json.dumps({"path": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def start(server: http.server.HTTPServer) -> str:
    """serverをbackground threadで起動する。

    Args:
        server: 起動するserver。

    Returns:
        `http://127.0.0.1:<port>`。
    """
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


class FindSocketUidTest(unittest.TestCase):
    """`/proc/net/tcp`の解析を検査する。"""

    def test_matches_client_side_only(self) -> None:
        """client側socket (local=client port、remote=broker port) のuidだけを返す。"""
        table = (
            "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
            "   0: 0100007F:223D 0100007F:C350 01 00000000:00000000 00:00000000 00000000   999        0 1\n"
            "   1: 0100007F:C350 0100007F:223D 01 00000000:00000000 00:00000000 00000000  1001        0 2\n"
        )
        self.assertEqual(broker.find_socket_uid(table, 0xC350, 0x223D), 1001)
        self.assertIsNone(broker.find_socket_uid(table, 0xC351, 0x223D))


@unittest.skipUnless(
    Path("/proc/net/tcp").exists() and os.getuid() >= broker.MIN_UID,
    "Linuxの一般userで実行する",
)
class BrokerServerTest(unittest.TestCase):
    """loopback上でbrokerを起動し、HTTP経由の振る舞いを検査する。"""

    def setUp(self) -> None:
        """偽LiteLLMとbrokerを起動する。"""
        FakeLiteLLM.requests.clear()
        self.upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeLiteLLM)
        self.broker = broker.BrokerServer(
            ("127.0.0.1", 0), start(self.upstream), "master", 10
        )
        self.port = self.broker.server_address[1]
        start(self.broker)

    def tearDown(self) -> None:
        """serverを停止する。"""
        for server in (self.broker, self.upstream):
            server.shutdown()
            server.server_close()

    def call(
        self, method: str, path: str, headers: dict[str, str] | None = None
    ) -> int:
        """brokerへrequestを送る。

        Args:
            method: HTTP method。
            path: path。
            headers: 追加header。

        Returns:
            HTTP status。
        """
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            body = "{}" if method == "POST" else None
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            response.read()
            return response.status
        finally:
            connection.close()

    def test_chat_completions_get_master_key_and_trace_user(self) -> None:
        """clientのAuthorizationを捨ててmaster keyを付け、OS user名をtrace userとして付ける。"""
        self.assertEqual(
            self.call(
                "POST", "/v1/chat/completions", {"Authorization": "Bearer forged"}
            ),
            200,
        )
        sent = FakeLiteLLM.requests[-1]["headers"]
        self.assertEqual(sent["Authorization"], "Bearer master")
        self.assertTrue(sent["langfuse_trace_user_id"])

    def test_other_routes_are_forbidden(self) -> None:
        """LiteLLMの管理APIなど、chat completionsとmodel一覧以外は中継しない。"""
        self.assertEqual(self.call("POST", "/key/generate"), 403)
        self.assertEqual(self.call("GET", "/v1/chat/completions"), 403)
        self.assertEqual(FakeLiteLLM.requests, [])

    def test_health_does_not_need_identification(self) -> None:
        """死活確認は認証なしで200を返す。"""
        self.assertEqual(self.call("GET", "/health"), 200)


if __name__ == "__main__":
    unittest.main()
