#!/usr/bin/env python3
"""Open Terminal上のPiへ、LiteLLMのchat completionsとmodel一覧だけを中継するbroker。

multi-user modeのOpen Terminalでは、PiがOpen WebUI userごとのOS userで動く。LiteLLM master keyを
Piが読めるfileや環境変数へ置くと、prompt injectionでagentに読まれ、LiteLLMの管理APIまで使われる。
brokerは専用OS userで動いてkeyを保持し、Piには`127.0.0.1:8765/v1`だけを見せる。
接続元のOS userはloopback TCPの所有uidをkernelの`/proc/net/tcp`から判定し、Langfuseのtrace userとして付ける。

route:
    GET  /health               死活確認。
    POST /v1/chat/completions  master keyを付けてLiteLLMへ中継する。
    GET  /v1/models            同上。
"""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import logging
import os
import pwd
import sys
import time
import urllib.parse
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

logger = logging.getLogger("llm-broker")

# Open Terminalが作るOS userはuseraddの通常uid。system accountからの接続は扱わない。
MIN_UID = 1000
# Piが使うOpenAI互換APIだけを許可する。master keyで管理APIを呼ばせないため。
ROUTES = frozenset({("POST", "/v1/chat/completions"), ("GET", "/v1/models")})
# upstreamへ渡さないrequest header。認証情報はbrokerが付け直す。
DROP_REQUEST_HEADERS = frozenset(
    {
        "authorization",
        "connection",
        "content-length",
        "cookie",
        "host",
        "keep-alive",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "x-api-key",
    }
)
# clientへ返さないresponse header。responseはHTTP/1.0の接続終了で区切る。
DROP_RESPONSE_HEADERS = frozenset(
    {"connection", "keep-alive", "set-cookie", "transfer-encoding", "upgrade"}
)
MAX_BODY_BYTES = 64 * 1024 * 1024
STREAM_CHUNK_BYTES = 64 * 1024


def find_socket_uid(
    proc_net_tcp: str, client_port: int, server_port: int
) -> int | None:
    """`/proc/net/tcp`の内容から、loopback接続のclient側socketの所有uidを探す。

    Args:
        proc_net_tcp: `/proc/net/tcp`の全文。
        client_port: brokerから見た接続元port。
        server_port: brokerのlisten port。

    Returns:
        client側socketのuid。該当行が無い場合はNone。
    """
    # IPv4 addressはhost byte order (little endian) の16進数、portはbig endianの16進数で表される。
    local = f"0100007F:{client_port:04X}"
    remote = f"0100007F:{server_port:04X}"
    for line in proc_net_tcp.splitlines()[1:]:
        fields = line.split()
        if len(fields) > 7 and fields[1] == local and fields[2] == remote:
            return int(fields[7])
    return None


class BrokerHandler(http.server.BaseHTTPRequestHandler):
    """1接続ごとのrequestを処理する。responseは接続終了で区切るHTTP/1.0で返す。"""

    server: BrokerServer
    server_version = "llm-broker"

    def do_GET(self) -> None:
        """GET requestを処理する。"""
        self.dispatch()

    def do_POST(self) -> None:
        """POST requestを処理する。"""
        self.dispatch()

    def log_message(self, format: str, *args: Any) -> None:
        """標準のaccess logを無効にし、`audit`だけを記録する。

        Args:
            format: 未使用。
            args: 未使用。
        """

    def dispatch(self) -> None:
        """routeを判定して中継し、監査logを記録する。"""
        started = time.perf_counter()
        path = self.path.partition("?")[0]
        if path == "/health":
            self.send_json(200, {"status": "ok"})
            return
        user = "-"
        status = 500
        try:
            user = self.identify_user()
            if (self.command, path) not in ROUTES:
                status = self.send_json(
                    403, {"detail": "chat completionsとmodel一覧だけを利用できます。"}
                )
            else:
                status = self.forward(path, user)
        except PermissionError as error:
            status = self.send_json(403, {"detail": str(error)})
        except (OSError, http.client.HTTPException) as error:
            logger.warning("upstream error: %s", type(error).__name__)
            status = self.send_json(502, {"detail": "LiteLLMへ接続できません。"})
        except Exception:
            # 想定外の例外でも接続を黙って切らず、clientへ500を返して原因をlogへ残す。
            logger.exception("unexpected error")
            status = self.send_json(500, {"detail": "brokerの内部errorです。"})
        finally:
            elapsed_ms = round((time.perf_counter() - started) * 1000)
            record = {
                "user": user,
                "method": self.command,
                "path": path,
                "status": status,
                "ms": elapsed_ms,
            }
            logger.info("audit %s", json.dumps(record, ensure_ascii=False))

    def identify_user(self) -> str:
        """接続元socketの所有uidからOS user名を得る。

        Returns:
            OS user名。

        Raises:
            PermissionError: 接続元を特定できない、またはsystem accountの場合。
        """
        table = Path("/proc/net/tcp").read_text(encoding="ascii")
        uid = find_socket_uid(
            table, self.client_address[1], self.server.server_address[1]
        )
        if uid is None or uid < MIN_UID:
            raise PermissionError("接続元のOS userを特定できません。")
        try:
            return pwd.getpwuid(uid).pw_name
        except KeyError as error:
            raise PermissionError("接続元のOS userを特定できません。") from error

    def read_body(self) -> bytes:
        """Content-Lengthで示されたrequest bodyを読む。

        Returns:
            body。

        Raises:
            PermissionError: 上限を超える場合。
        """
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY_BYTES:
            raise PermissionError("request bodyが大きすぎます。")
        return self.rfile.read(length) if length else b""

    def forward(self, path: str, user: str) -> int:
        """requestをLiteLLMへ送り、streaming responseをchunk単位で返す。

        Args:
            path: LiteLLM上のpath。
            user: Langfuseのtrace userとして付けるOS user名。

        Returns:
            LiteLLMのHTTP status。
        """
        body = self.read_body()
        headers = {
            name: value
            for name, value in self.headers.items()
            if name.lower() not in DROP_REQUEST_HEADERS
        }
        headers["Authorization"] = f"Bearer {self.server.api_key}"
        headers["langfuse_trace_user_id"] = user
        headers["Content-Length"] = str(len(body))
        parts = urllib.parse.urlsplit(self.server.upstream)
        connection_class = (
            http.client.HTTPSConnection
            if parts.scheme == "https"
            else http.client.HTTPConnection
        )
        connection = connection_class(
            parts.hostname or "", parts.port, timeout=self.server.timeout
        )
        try:
            connection.request(
                self.command,
                parts.path.rstrip("/") + path,
                body=body or None,
                headers=headers,
            )
            response = connection.getresponse()
            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                if name.lower() not in DROP_RESPONSE_HEADERS:
                    self.send_header(name, value)
            self.end_headers()
            while chunk := response.read1(STREAM_CHUNK_BYTES):
                self.wfile.write(chunk)
                self.wfile.flush()
            return response.status
        finally:
            connection.close()

    def send_json(self, status: int, payload: Mapping[str, Any]) -> int:
        """JSON responseを返す。

        Args:
            status: HTTP status code。
            payload: JSONへ変換する値。

        Returns:
            送ったHTTP status。
        """
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return status


class BrokerServer(http.server.ThreadingHTTPServer):
    """中継先とmaster keyを持つthreading HTTP server。"""

    daemon_threads = True

    def __init__(
        self, address: tuple[str, int], upstream: str, api_key: str, timeout: float
    ) -> None:
        """serverを作成してbindする。

        Args:
            address: listen address。loopbackだけを想定する。
            upstream: LiteLLMのbase URL。
            api_key: LiteLLM master key。
            timeout: upstreamのsocket timeout秒。
        """
        super().__init__(address, BrokerHandler)
        self.upstream = upstream.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout


def main(argv: Sequence[str]) -> int:
    """brokerを起動し、終了するまでrequestを処理する。

    Args:
        argv: `sys.argv`。

    Returns:
        終了code。keyが無い場合は2。
    """
    started = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--host", default="127.0.0.1", help="listen address (loopbackのみを想定)"
    )
    parser.add_argument("--port", type=int, default=8765, help="listen port")
    parser.add_argument(
        "--timeout", type=float, default=3600.0, help="upstreamのsocket timeout秒"
    )
    args = parser.parse_args(argv[1:])
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    api_key = os.environ.get("LLM_BROKER_LITELLM_API_KEY", "")
    if not api_key:
        logger.error("LLM_BROKER_LITELLM_API_KEY is required")
        return 2
    upstream = os.environ.get("LLM_BROKER_LITELLM_URL", "http://litellm:4000")
    server = BrokerServer((args.host, args.port), upstream, api_key, args.timeout)
    logger.info("listening on %s:%d", args.host, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        logger.info("stopped after %.1fs", time.perf_counter() - started)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
