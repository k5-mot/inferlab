"""owui-brokerのtest。

brokerはOpen WebUI API keyとLiteLLM master keyを保持し、接続元OS userを`/proc/net/tcp`で判定する。
ここではloopback上の偽upstreamを使い、keyの付け替え、route制限、tool serverのACL確認を検査する。
"""

from __future__ import annotations

import http.client
import http.server
import importlib.util
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any, ClassVar

REPO_ROOT = Path(__file__).resolve().parents[1]
BROKER = REPO_ROOT / "20-owui" / "open-terminal" / "broker" / "owui_broker.py"
VALID_KEY = "sk-test0123456789abcdef"


def load_broker() -> ModuleType:
    """brokerをmoduleとして読み込む。

    Returns:
        読み込んだmodule。

    Raises:
        RuntimeError: module specを作成できない場合。
    """
    spec = importlib.util.spec_from_file_location("owui_broker", BROKER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {BROKER}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


broker = load_broker()


class FakeUpstream(http.server.BaseHTTPRequestHandler):
    """受け取ったrequestを記録し、pathに応じたJSONを返す偽upstream。"""

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
        """requestを記録し、keyとpathに応じたresponseを返す。"""
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        FakeUpstream.requests.append(
            {
                "method": self.command,
                "path": self.path,
                "headers": dict(self.headers),
                "body": body,
            }
        )
        authorized = self.headers.get("Authorization") in {
            f"Bearer {VALID_KEY}",
            "Bearer master",
            "Bearer tool-key",
        }
        if self.path == "/api/v1/tools/":
            payload: Any = [{"id": "server:allowed"}]
        else:
            payload = {"path": self.path}
        data = json.dumps(payload).encode()
        self.send_response(200 if authorized else 401)
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


class PureFunctionTest(unittest.TestCase):
    """副作用の無い関数を検査する。"""

    def test_find_socket_uid_matches_client_side_only(self) -> None:
        """client側socket (local=client port、remote=broker port) のuidだけを返す。"""
        table = (
            "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
            "   0: 0100007F:223D 0100007F:C350 01 00000000:00000000 00:00000000 00000000   999        0 1\n"
            "   1: 0100007F:C350 0100007F:223D 01 00000000:00000000 00:00000000 00000000  1001        0 2\n"
        )
        self.assertEqual(broker.find_socket_uid(table, 0xC350, 0x223D), 1001)
        self.assertIsNone(broker.find_socket_uid(table, 0xC351, 0x223D))

    def test_parse_tool_servers_keeps_openapi_with_bearer_key(self) -> None:
        """OpenAPI serverだけを取り込み、bearer以外ではkeyを付けない。"""
        raw = json.dumps(
            [
                {
                    "type": "openapi",
                    "url": "http://mcpo:8000/",
                    "auth_type": "bearer",
                    "key": "k",
                    "info": {"id": "a"},
                },
                {
                    "type": "openapi",
                    "url": "http://lt:5000",
                    "auth_type": "none",
                    "key": "x",
                    "info": {"id": "b"},
                },
                {"type": "mcp", "url": "http://m", "info": {"id": "c"}},
                {"type": "openapi", "url": "file:///etc", "info": {"id": "d"}},
            ]
        )
        servers = broker.parse_tool_servers(raw)
        self.assertEqual(
            servers,
            {
                "a": broker.Upstream("http://mcpo:8000", "k"),
                "b": broker.Upstream("http://lt:5000", ""),
            },
        )

    def test_is_safe_path_rejects_traversal(self) -> None:
        """`..`、encodeされた`..`、別host指定を拒否する。"""
        self.assertTrue(broker.is_safe_path("/api/v1/notes/search"))
        for path in (
            "/api/../auths",
            "/api/%2e%2e/auths",
            "//evil/x",
            "api/x",
            "/a\\b",
        ):
            self.assertFalse(broker.is_safe_path(path), path)

    def test_key_store_writes_mode_600(self) -> None:
        """keyをmode 600で保存し、削除できる。"""
        with tempfile.TemporaryDirectory() as tmp:
            store = broker.KeyStore(Path(tmp))
            store.save("ualice", VALID_KEY)
            self.assertEqual(stat.S_IMODE(os.stat(Path(tmp) / "ualice").st_mode), 0o600)
            self.assertEqual(store.load("ualice"), VALID_KEY)
            self.assertTrue(store.delete("ualice"))
            self.assertIsNone(store.load("ualice"))


@unittest.skipUnless(
    Path("/proc/net/tcp").exists() and os.getuid() >= broker.MIN_UID,
    "Linuxの一般userで実行する",
)
class BrokerServerTest(unittest.TestCase):
    """loopback上でbrokerを起動し、HTTP経由の振る舞いを検査する。"""

    def setUp(self) -> None:
        """偽upstreamとbrokerを起動する。"""
        FakeUpstream.requests.clear()
        self.upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeUpstream)
        upstream_url = start(self.upstream)
        self.tmp = tempfile.TemporaryDirectory()
        config = broker.BrokerConfig(
            owui=broker.Upstream(upstream_url),
            litellm=broker.Upstream(upstream_url, "master"),
            tool_servers={
                "allowed": broker.Upstream(upstream_url, "tool-key"),
                "denied": broker.Upstream(upstream_url, "tool-key"),
            },
            key_dir=Path(self.tmp.name),
            timeout=10,
        )
        self.broker = broker.BrokerServer(("127.0.0.1", 0), config)
        self.port = self.broker.server_address[1]
        start(self.broker)

    def tearDown(self) -> None:
        """serverを停止する。"""
        for server in (self.broker, self.upstream):
            server.shutdown()
            server.server_close()
        self.tmp.cleanup()

    def call(
        self,
        method: str,
        path: str,
        body: str | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, Any]:
        """brokerへrequestを送る。

        Args:
            method: HTTP method。
            path: path。
            body: request body。
            headers: 追加header。

        Returns:
            HTTP statusとJSON body。
        """
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, json.loads(response.read() or b"null")
        finally:
            connection.close()

    def test_owui_requires_registered_key_and_replaces_authorization(self) -> None:
        """未登録なら401、登録後はclientのAuthorizationを捨ててuserのkeyで中継する。"""
        self.assertEqual(self.call("GET", "/owui/api/v1/notes/")[0], 401)
        self.assertEqual(self.call("PUT", "/broker/key", "not-a-key")[0], 400)
        status, payload = self.call("PUT", "/broker/key", VALID_KEY)
        self.assertEqual((status, payload["api_key_registered"]), (200, True))
        status, payload = self.call(
            "GET", "/owui/api/v1/notes/?q=x", headers={"Authorization": "Bearer forged"}
        )
        self.assertEqual((status, payload["path"]), (200, "/api/v1/notes/?q=x"))
        self.assertEqual(
            FakeUpstream.requests[-1]["headers"]["Authorization"], f"Bearer {VALID_KEY}"
        )
        self.assertEqual(self.call("GET", "/owui/api/%2e%2e/x")[0], 400)

    def test_litellm_allows_only_chat_and_models(self) -> None:
        """master keyはchat completionsとmodel一覧だけに付け、trace userを付ける。"""
        status, _ = self.call(
            "POST",
            "/litellm/v1/chat/completions",
            "{}",
            {"Content-Type": "application/json"},
        )
        self.assertEqual(status, 200)
        sent = FakeUpstream.requests[-1]["headers"]
        self.assertEqual(sent["Authorization"], "Bearer master")
        self.assertTrue(sent["langfuse_trace_user_id"])
        self.assertEqual(self.call("POST", "/litellm/key/generate", "{}")[0], 403)

    def test_tools_follow_open_webui_acl(self) -> None:
        """Open WebUIの`/api/v1/tools/`に見えるserverだけを中継する。"""
        self.call("PUT", "/broker/key", VALID_KEY)
        status, payload = self.call("POST", "/tools/allowed/translate", "{}")
        self.assertEqual((status, payload["path"]), (200, "/translate"))
        self.assertEqual(
            FakeUpstream.requests[-1]["headers"]["Authorization"], "Bearer tool-key"
        )
        self.assertEqual(self.call("POST", "/tools/denied/translate", "{}")[0], 403)
        self.assertEqual(self.call("POST", "/tools/unknown/translate", "{}")[0], 404)

    def test_whoami_reports_os_user(self) -> None:
        """接続元のOS user名を返す。"""
        status, payload = self.call("GET", "/broker/whoami")
        self.assertEqual(status, 200)
        self.assertEqual(payload["api_key_registered"], False)
        self.assertTrue(payload["os_user"])

    def test_raw_non_ascii_path_is_encoded_for_upstream(self) -> None:
        """URL encodeされていない日本語のpathも、接続を切らずにencodeして中継する。"""
        self.call("PUT", "/broker/key", VALID_KEY)
        with socket.create_connection(("127.0.0.1", self.port), timeout=10) as client:
            client.sendall(
                "GET /owui/api/v1/notes/?q=設計会議 HTTP/1.0\r\n\r\n".encode()
            )
            response = b""
            while chunk := client.recv(65536):
                response += chunk
        self.assertTrue(response.startswith(b"HTTP/1.0 200"), response[:80])
        self.assertEqual(
            FakeUpstream.requests[-1]["path"],
            "/api/v1/notes/?q=%E8%A8%AD%E8%A8%88%E4%BC%9A%E8%AD%B0",
        )


if __name__ == "__main__":
    unittest.main()
