#!/usr/bin/env python3
"""Open Terminalのuser processへOpen WebUI、LiteLLM、tool serverを中継するbroker。

multi-user modeのOpen Terminalでは、PiとshellがOpen WebUI userごとのOS userで動く。
API keyやLiteLLM master keyをそのuserのhomeや読めるfileへ置くと、prompt injectionで
agentに読まれて外部へ持ち出される。brokerは専用OS userで動き、keyを自分だけが読める
directoryへ保持する。接続元のOS userはloopback TCPの所有uidをkernelの
`/proc/net/tcp`から判定するため、clientは自己申告の識別子を送らない。

route:
    GET    /broker/health          死活確認。認証しない。
    GET    /broker/whoami          接続元OS userとAPI key登録状態。
    PUT    /broker/key             bodyのOpen WebUI API keyを検証して登録する。
    DELETE /broker/key             登録済みkeyを削除する。
    *      /owui/<path>            登録済みkeyでOpen WebUIへ中継する。allowlistはOpen WebUIが強制する。
    *      /litellm/v1/...         LiteLLM master keyでchat completionsとmodel一覧だけを中継する。
    *      /tools/<id>/<path>      Open WebUIでそのuserが使えるtool serverだけを中継する。
"""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import logging
import os
import pwd
import re
import sys
import time
import urllib.parse
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger("owui-broker")

# Open Terminalが作るOS userはuseraddの通常uid。system accountからの接続は扱わない。
MIN_UID = 1000
USERNAME_PATTERN = re.compile(r"[a-z_][a-z0-9_-]{0,31}")
API_KEY_PATTERN = re.compile(r"sk-[A-Za-z0-9_-]{8,256}")
SERVER_ID_PATTERN = re.compile(r"[A-Za-z0-9_.-]{1,128}")
# Piが使うOpenAI互換APIだけを許可する。master keyで管理APIを呼ばせないため。
LITELLM_ROUTES = frozenset({("POST", "/v1/chat/completions"), ("GET", "/v1/models")})
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
MAX_BODY_BYTES = 512 * 1024 * 1024
STREAM_CHUNK_BYTES = 64 * 1024


@dataclass(frozen=True)
class Upstream:
    """中継先serverと、brokerが付与するbearer key。

    Attributes:
        base_url: `http://host:port[/prefix]`形式のURL。
        api_key: Authorization headerへ付けるkey。空文字列なら付けない。
    """

    base_url: str
    api_key: str = ""


@dataclass(frozen=True)
class BrokerConfig:
    """brokerの設定。

    Attributes:
        owui: Open WebUI。keyはuserごとに差し替える。
        litellm: LiteLLMとmaster key。
        tool_servers: Open WebUIのtool server IDから中継先への対応。
        key_dir: userごとのAPI keyを置くdirectory。
        timeout: upstreamのsocket timeout秒。
    """

    owui: Upstream
    litellm: Upstream
    tool_servers: Mapping[str, Upstream]
    key_dir: Path
    timeout: float


class BrokerError(Exception):
    """clientへHTTP errorとして返す例外。

    Attributes:
        status: HTTP status code。
        detail: clientへ返す説明。
    """

    def __init__(self, status: int, detail: str) -> None:
        """例外を作成する。

        Args:
            status: HTTP status code。
            detail: clientへ返す説明。
        """
        super().__init__(detail)
        self.status = status
        self.detail = detail


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


def parse_tool_servers(raw: str) -> dict[str, Upstream]:
    """Open WebUIの`TOOL_SERVER_CONNECTIONS`形式から、OpenAPI tool serverの中継先を作る。

    Args:
        raw: `TOOL_SERVER_CONNECTIONS`と同じJSON文字列。

    Returns:
        `info.id`をkeyとする中継先。MCP接続など、OpenAPI以外は含めない。

    Raises:
        ValueError: JSONとして読めない場合。
        TypeError: JSONがlistでない場合。
    """
    connections = json.loads(raw or "[]")
    if not isinstance(connections, list):
        raise TypeError("tool server connections must be a JSON list")
    servers: dict[str, Upstream] = {}
    for connection in connections:
        if (
            not isinstance(connection, dict)
            or connection.get("type", "openapi") != "openapi"
        ):
            continue
        server_id = str((connection.get("info") or {}).get("id", ""))
        url = str(connection.get("url", ""))
        if not SERVER_ID_PATTERN.fullmatch(server_id) or not url.startswith(
            ("http://", "https://")
        ):
            continue
        key = (
            str(connection.get("key", ""))
            if connection.get("auth_type", "bearer") == "bearer"
            else ""
        )
        servers[server_id] = Upstream(url.rstrip("/"), key)
    return servers


def is_safe_path(path: str) -> bool:
    """中継先pathにtraversalや別host指定が含まれないか判定する。

    Args:
        path: query stringを除いたpath。`/`で始まる。

    Returns:
        安全な場合True。
    """
    if not path.startswith("/") or path.startswith("//") or "\\" in path:
        return False
    segments = urllib.parse.unquote(path).split("/")
    return not any(segment in {".", ".."} for segment in segments)


def resolve_os_user(uid: int) -> str:
    """uidからOpen Terminalが作成したOS user名を得る。

    Args:
        uid: 接続元socketのuid。

    Returns:
        OS user名。

    Raises:
        BrokerError: 対象外のuid、または不正なuser名の場合。
    """
    if uid < MIN_UID:
        raise BrokerError(403, "system accountからは利用できません。")
    try:
        name = pwd.getpwuid(uid).pw_name
    except KeyError as error:
        raise BrokerError(403, "接続元のOS userを特定できません。") from error
    if not USERNAME_PATTERN.fullmatch(name):
        raise BrokerError(403, "接続元のOS user名が不正です。")
    return name


class KeyStore:
    """OS userごとのOpen WebUI API keyを、broker専用directoryへ保存する。"""

    def __init__(self, directory: Path) -> None:
        """保存先を設定する。

        Args:
            directory: mode 700のdirectory。
        """
        self.directory = directory

    def path_for(self, user: str) -> Path:
        """userのkey file pathを返す。

        Args:
            user: `resolve_os_user`で検証済みのOS user名。

        Returns:
            key fileのpath。
        """
        return self.directory / user

    def load(self, user: str) -> str | None:
        """keyを読む。

        Args:
            user: OS user名。

        Returns:
            key。未登録の場合None。
        """
        try:
            return self.path_for(user).read_text(encoding="utf-8").strip() or None
        except FileNotFoundError:
            return None

    def save(self, user: str, key: str) -> None:
        """keyをmode 600で原子的に保存する。

        Args:
            user: OS user名。
            key: 検証済みのAPI key。
        """
        target = self.path_for(user)
        temporary = target.with_name(f".{user}.tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(key)
        temporary.replace(target)

    def delete(self, user: str) -> bool:
        """keyを削除する。

        Args:
            user: OS user名。

        Returns:
            削除した場合True。未登録の場合False。
        """
        try:
            self.path_for(user).unlink()
        except FileNotFoundError:
            return False
        return True


def open_connection(
    upstream: Upstream, timeout: float
) -> tuple[http.client.HTTPConnection, str]:
    """upstreamへのHTTP接続を作る。

    Args:
        upstream: 中継先。
        timeout: socket timeout秒。

    Returns:
        接続と、base URLのpath prefix。
    """
    parts = urllib.parse.urlsplit(upstream.base_url)
    connection_class = (
        http.client.HTTPSConnection
        if parts.scheme == "https"
        else http.client.HTTPConnection
    )
    connection = connection_class(parts.hostname or "", parts.port, timeout=timeout)
    return connection, parts.path.rstrip("/")


def request_target(prefix: str, path: str) -> str:
    """upstreamへ送るrequest targetを作る。

    clientが日本語などをURL encodeせずに送っても、http.clientはASCII以外を送れない。
    既存の`%XX`とURLの区切り文字は保ったまま、それ以外をpercent encodeする。

    Args:
        prefix: base URLのpath prefix。
        path: query stringを含むpath。

    Returns:
        ASCIIだけからなるrequest target。
    """
    target = prefix + path
    try:
        # http.serverはrequest lineをlatin-1で読むため、受信したbyte列へ戻してからencodeする。
        raw = target.encode("latin-1")
    except UnicodeEncodeError:
        raw = target.encode("utf-8")
    return urllib.parse.quote(raw, safe="/?&=%:@!$'()*+,;~-._[]")


def fetch_json(
    upstream: Upstream, path: str, key: str, timeout: float
) -> tuple[int, Any]:
    """upstreamへGETし、JSON responseを返す。broker内部の検証に使う。

    Args:
        upstream: 中継先。
        path: query stringを含むpath。
        key: bearer key。
        timeout: socket timeout秒。

    Returns:
        HTTP statusと、JSONとして読めた場合はその値 (読めない場合None)。
    """
    connection, prefix = open_connection(upstream, timeout)
    try:
        connection.request(
            "GET",
            request_target(prefix, path),
            headers={"Authorization": f"Bearer {key}"},
        )
        response = connection.getresponse()
        body = response.read()
    finally:
        connection.close()
    try:
        return response.status, json.loads(body)
    except ValueError:
        return response.status, None


class BrokerHandler(http.server.BaseHTTPRequestHandler):
    """1接続ごとのrequestを処理する。responseは接続終了で区切るHTTP/1.0で返す。"""

    server: BrokerServer
    server_version = "owui-broker"

    def do_GET(self) -> None:
        """GET requestを処理する。"""
        self.dispatch()

    def do_POST(self) -> None:
        """POST requestを処理する。"""
        self.dispatch()

    def do_PUT(self) -> None:
        """PUT requestを処理する。"""
        self.dispatch()

    def do_PATCH(self) -> None:
        """PATCH requestを処理する。"""
        self.dispatch()

    def do_DELETE(self) -> None:
        """DELETE requestを処理する。"""
        self.dispatch()

    def log_message(self, format: str, *args: Any) -> None:
        """標準のaccess logを無効にする。

        query stringに検索語などが含まれるため、`audit`だけを記録する。

        Args:
            format: 未使用。
            args: 未使用。
        """

    def dispatch(self) -> None:
        """routeを判定して処理し、監査logを記録する。"""
        started = time.perf_counter()
        path, _, query = self.path.partition("?")
        route = path.split("/", 2)[1] if path.count("/") >= 1 else ""
        user = "-"
        status = 500
        try:
            if path == "/broker/health":
                status = self.send_json(200, {"status": "ok"})
                return
            user = self.identify_user()
            status = self.route(user, path, query)
        except BrokerError as error:
            status = self.send_json(error.status, {"detail": error.detail})
        except (OSError, http.client.HTTPException) as error:
            logger.warning("upstream error: %s", type(error).__name__)
            status = self.send_json(502, {"detail": "中継先へ接続できません。"})
        except Exception:
            # 想定外の例外でも接続を黙って切らず、clientへ500を返して原因をlogへ残す。
            logger.exception("unexpected error")
            status = self.send_json(500, {"detail": "brokerの内部errorです。"})
        finally:
            if path != "/broker/health":
                elapsed_ms = round((time.perf_counter() - started) * 1000)
                logger.info(
                    "audit %s",
                    json.dumps(
                        {
                            "user": user,
                            "method": self.command,
                            "route": route,
                            "path": path,
                            "status": status,
                            "ms": elapsed_ms,
                        },
                        ensure_ascii=False,
                    ),
                )

    def route(self, user: str, path: str, query: str) -> int:
        """識別済みuserのrequestを振り分ける。

        Args:
            user: OS user名。
            path: query stringを除いたpath。
            query: query string。

        Returns:
            clientへ返したHTTP status。

        Raises:
            BrokerError: routeが無い、または拒否する場合。
        """
        config = self.server.config
        suffix = f"?{query}" if query else ""
        if path == "/broker/whoami" and self.command == "GET":
            return self.send_json(
                200,
                {
                    "os_user": user,
                    "api_key_registered": self.server.keys.load(user) is not None,
                },
            )
        if path == "/broker/key" and self.command == "PUT":
            return self.register_key(user)
        if path == "/broker/key" and self.command == "DELETE":
            return self.send_json(200, {"deleted": self.server.keys.delete(user)})
        if path.startswith("/owui/"):
            upstream_path = path.removeprefix("/owui")
            if not is_safe_path(upstream_path):
                raise BrokerError(400, "不正なpathです。")
            key = self.require_key(user)
            return self.forward(
                Upstream(config.owui.base_url, key), upstream_path + suffix, {}
            )
        if path.startswith("/litellm/"):
            upstream_path = path.removeprefix("/litellm")
            if (self.command, upstream_path) not in LITELLM_ROUTES:
                raise BrokerError(
                    403, "LiteLLMはchat completionsとmodel一覧だけを利用できます。"
                )
            # Langfuseでuser単位に集計できるよう、OS user名をtrace userとして付ける。
            return self.forward(
                config.litellm, upstream_path + suffix, {"langfuse_trace_user_id": user}
            )
        if path.startswith("/tools/"):
            server_id, _, rest = path.removeprefix("/tools/").partition("/")
            return self.forward_tool(user, server_id, f"/{rest}", suffix)
        raise BrokerError(404, "routeがありません。")

    def identify_user(self) -> str:
        """接続元socketの所有uidからOS user名を得る。

        Returns:
            OS user名。

        Raises:
            BrokerError: 特定できない場合。
        """
        client_port = self.client_address[1]
        server_port = self.server.server_address[1]
        uid = find_socket_uid(
            Path("/proc/net/tcp").read_text(encoding="ascii"), client_port, server_port
        )
        if uid is None:
            raise BrokerError(403, "接続元を特定できません。")
        return resolve_os_user(uid)

    def require_key(self, user: str) -> str:
        """userの登録済みkeyを返す。

        Args:
            user: OS user名。

        Returns:
            API key。

        Raises:
            BrokerError: 未登録の場合。
        """
        key = self.server.keys.load(user)
        if key is None:
            raise BrokerError(
                401,
                "Open WebUI API keyが未登録です。Open WebUIの設定 > アカウント > APIキーで発行し、"
                "'owui-api login'で登録してください。",
            )
        return key

    def register_key(self, user: str) -> int:
        """bodyのAPI keyを検証し、userのkeyとして保存する。

        Args:
            user: OS user名。

        Returns:
            clientへ返したHTTP status。

        Raises:
            BrokerError: keyの形式が不正、またはOpen WebUIが受け付けない場合。
        """
        key = self.read_body().decode("utf-8", errors="replace").strip()
        if not API_KEY_PATTERN.fullmatch(key):
            raise BrokerError(400, "Open WebUI API keyの形式ではありません。")
        config = self.server.config
        status, _ = fetch_json(config.owui, "/api/models", key, config.timeout)
        if status != 200:
            raise BrokerError(
                400, f"Open WebUIがAPI keyを受け付けません (HTTP {status})。"
            )
        self.server.keys.save(user, key)
        return self.send_json(200, {"os_user": user, "api_key_registered": True})

    def forward_tool(self, user: str, server_id: str, path: str, suffix: str) -> int:
        """tool serverへ中継する。Open WebUIでそのuserに見えるserverだけを許可する。

        Args:
            user: OS user名。
            server_id: Open WebUIのtool server ID (`info.id`)。
            path: tool server上のpath。
            suffix: `?`付きquery string、または空文字列。

        Returns:
            clientへ返したHTTP status。

        Raises:
            BrokerError: serverが無い、またはuserに利用権限が無い場合。
        """
        config = self.server.config
        upstream = config.tool_servers.get(server_id)
        if upstream is None or not is_safe_path(path):
            raise BrokerError(404, "tool serverがありません。")
        key = self.require_key(user)
        status, tools = fetch_json(config.owui, "/api/v1/tools/", key, config.timeout)
        visible = status == 200 and isinstance(tools, list)
        if not visible or not any(
            isinstance(tool, dict) and tool.get("id") == f"server:{server_id}"
            for tool in tools
        ):
            raise BrokerError(403, "このtool serverを利用する権限がありません。")
        return self.forward(upstream, path + suffix, {})

    def read_body(self) -> bytes:
        """request bodyを読む。Content-Lengthとchunked encodingに対応する。

        Returns:
            body。

        Raises:
            BrokerError: 上限を超える場合。
        """
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            chunks: list[bytes] = []
            total = 0
            while True:
                size = int(self.rfile.readline().split(b";", 1)[0].strip() or b"0", 16)
                if size == 0:
                    # 末尾のtrailerと空行を読み捨てる。
                    while self.rfile.readline() not in {b"\r\n", b"\n", b""}:
                        pass
                    return b"".join(chunks)
                total += size
                if total > MAX_BODY_BYTES:
                    raise BrokerError(413, "request bodyが大きすぎます。")
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY_BYTES:
            raise BrokerError(413, "request bodyが大きすぎます。")
        return self.rfile.read(length) if length else b""

    def forward(
        self, upstream: Upstream, path: str, extra_headers: Mapping[str, str]
    ) -> int:
        """requestをupstreamへ送り、responseを逐次clientへ返す。

        streaming responseはchunk単位でflushする。

        Args:
            upstream: 中継先とbrokerが付けるkey。
            path: query stringを含むupstream上のpath。
            extra_headers: 追加するrequest header。

        Returns:
            upstreamのHTTP status。
        """
        body = self.read_body()
        headers = {
            name: value
            for name, value in self.headers.items()
            if name.lower() not in DROP_REQUEST_HEADERS
        }
        headers.update(extra_headers)
        if upstream.api_key:
            headers["Authorization"] = f"Bearer {upstream.api_key}"
        if body or self.command in {"POST", "PUT", "PATCH"}:
            headers["Content-Length"] = str(len(body))
        connection, prefix = open_connection(upstream, self.server.config.timeout)
        try:
            connection.request(
                self.command,
                request_target(prefix, path),
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
    """設定とkey storeを持つthreading HTTP server。"""

    daemon_threads = True

    def __init__(self, address: tuple[str, int], config: BrokerConfig) -> None:
        """serverを作成してbindする。

        Args:
            address: listen address。loopbackだけを想定する。
            config: brokerの設定。
        """
        super().__init__(address, BrokerHandler)
        self.config = config
        self.keys = KeyStore(config.key_dir)


def load_config(
    environ: Mapping[str, str], key_dir: Path, timeout: float
) -> BrokerConfig:
    """環境変数から設定を読む。

    Args:
        environ: 環境変数。
        key_dir: API keyの保存先。
        timeout: upstreamのsocket timeout秒。

    Returns:
        brokerの設定。

    Raises:
        ValueError: LiteLLM keyが無い、またはtool server設定がJSONでない場合。
        TypeError: tool server設定がlistでない場合。
    """
    litellm_key = environ.get("OWUI_BROKER_LITELLM_API_KEY", "")
    if not litellm_key:
        raise ValueError("OWUI_BROKER_LITELLM_API_KEY is required")
    return BrokerConfig(
        owui=Upstream(
            environ.get("OWUI_BROKER_OWUI_URL", "http://open-webui:8080").rstrip("/")
        ),
        litellm=Upstream(
            environ.get("OWUI_BROKER_LITELLM_URL", "http://litellm:4000").rstrip("/"),
            litellm_key,
        ),
        tool_servers=parse_tool_servers(environ.get("OWUI_BROKER_TOOL_SERVERS", "[]")),
        key_dir=key_dir,
        timeout=timeout,
    )


def main(argv: Sequence[str]) -> int:
    """brokerを起動し、終了するまでrequestを処理する。

    Args:
        argv: `sys.argv`。

    Returns:
        終了code。設定errorは2。
    """
    started = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--host", default="127.0.0.1", help="listen address (loopbackのみを想定)"
    )
    parser.add_argument("--port", type=int, default=8765, help="listen port")
    parser.add_argument(
        "--key-dir",
        type=Path,
        default=Path("/var/lib/owui-broker/keys"),
        help="API keyの保存先",
    )
    parser.add_argument(
        "--timeout", type=float, default=3600.0, help="upstreamのsocket timeout秒"
    )
    args = parser.parse_args(argv[1:])
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    try:
        config = load_config(os.environ, args.key_dir, args.timeout)
    except (TypeError, ValueError) as error:
        logger.error("invalid configuration: %s", error)
        return 2
    args.key_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    server = BrokerServer((args.host, args.port), config)
    logger.info(
        "listening on %s:%d, tool servers: %s",
        args.host,
        args.port,
        ", ".join(sorted(config.tool_servers)) or "-",
    )
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
