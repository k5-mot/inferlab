from __future__ import annotations

import json
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from worker import SyncWorker


class SyncWorkerWebServer:
    """sync-workerの状態確認と手動実行を提供するWebUI server。"""

    def __init__(self, host: str, port: int, worker: SyncWorker) -> None:
        """WebUI serverを初期化する。

        Args:
            host: bind host。
            port: bind port。
            worker: 操作対象worker。

        Returns:
            None。
        """

        self.host = host
        self.port = port
        self.worker = worker
        self.httpd = ThreadingHTTPServer((host, port), build_handler(worker))

    def start_background(self) -> None:
        """WebUI serverをbackground threadで開始する。

        Args:
            None。

        Returns:
            None。

        Side Effects:
            daemon threadを開始してHTTP portをlistenする。
        """

        thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        thread.start()


def build_handler(worker: SyncWorker) -> type[BaseHTTPRequestHandler]:
    """workerを閉じ込めたHTTP handler classを作る。

    Args:
        worker: 操作対象worker。

    Returns:
        BaseHTTPRequestHandlerの派生class。
    """

    class Handler(BaseHTTPRequestHandler):
        """sync-worker WebUI用HTTP handler。"""

        def do_GET(self) -> None:
            """GET requestを処理する。

            Args:
                None。

            Returns:
                None。

            Side Effects:
                HTTP responseを書き込む。
            """

            if self.path == "/":
                self._send_html(render_html(worker.status()))
                return
            if self.path == "/api/status":
                self._send_json(worker.status())
                return
            self.send_error(HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:
            """POST requestを処理する。

            Args:
                None。

            Returns:
                None。

            Side Effects:
                worker操作を実行し、HTTP responseを書き込む。
            """

            if self.path == "/api/trigger":
                self._send_json(worker.trigger_manual(), HTTPStatus.ACCEPTED)
                return
            if self.path == "/api/check":
                self._send_json(worker.check_sources())
                return
            self.send_error(HTTPStatus.NOT_FOUND)

        def log_message(self, format: str, *args: Any) -> None:
            """標準HTTP access logを抑制する。

            Args:
                format: log format。
                args: format引数。

            Returns:
                None。
            """

        def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
            """JSON responseを送信する。

            Args:
                payload: response payload。
                status: HTTP status。

            Returns:
                None。

            Side Effects:
                HTTP responseを書き込む。
            """

            body = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send_html(self, html: str) -> None:
            """HTML responseを送信する。

            Args:
                html: response HTML。

            Returns:
                None。

            Side Effects:
                HTTP responseを書き込む。
            """

            body = html.encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def render_html(status: dict[str, Any]) -> str:
    """worker状態を表示するHTMLを作る。

    Args:
        status: worker.statusの戻り値。

    Returns:
        HTML文字列。
    """

    health = status.get("health", {})
    checks = status.get("source_check", {})
    sources = status.get("sources", [])
    rows = "\n".join(
        f"<tr><td>{escape_html(item.get('name', ''))}</td><td>{escape_html(item.get('type', ''))}</td><td>{'enabled' if item.get('enabled') else 'disabled'}</td></tr>"
        for item in sources
    )
    return f"""<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>LLMwiki Sync Worker</title>
  <style>
    body {{ margin: 0; font-family: system-ui, sans-serif; color: #17202a; background: #f6f8fa; }}
    main {{ max-width: 1100px; margin: 0 auto; padding: 24px; }}
    header {{ display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 20px; }}
    h1 {{ font-size: 24px; margin: 0; }}
    button {{ border: 1px solid #1f6feb; background: #1f6feb; color: white; border-radius: 6px; padding: 9px 14px; font-weight: 600; cursor: pointer; }}
    button.secondary {{ background: white; color: #1f6feb; }}
    section {{ background: white; border: 1px solid #d0d7de; border-radius: 8px; padding: 16px; margin-bottom: 16px; }}
    pre {{ overflow: auto; background: #0d1117; color: #c9d1d9; padding: 12px; border-radius: 6px; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ padding: 8px; border-bottom: 1px solid #d8dee4; text-align: left; }}
  </style>
</head>
<body>
<main>
  <header>
    <h1>LLMwiki Sync Worker</h1>
    <div>
      <button class="secondary" onclick="post('/api/check')">Status Check</button>
      <button onclick="post('/api/trigger')">Manual Trigger</button>
    </div>
  </header>
  <section>
    <h2>Sources</h2>
    <table><thead><tr><th>Name</th><th>Type</th><th>Enabled</th></tr></thead><tbody>{rows}</tbody></table>
  </section>
  <section>
    <h2>Last Sync</h2>
    <pre>{escape_html(json.dumps(health, ensure_ascii=False, indent=2, sort_keys=True))}</pre>
  </section>
  <section>
    <h2>Last Status Check</h2>
    <pre>{escape_html(json.dumps(checks, ensure_ascii=False, indent=2, sort_keys=True))}</pre>
  </section>
</main>
<script>
async function post(path) {{
  await fetch(path, {{ method: 'POST' }});
  location.reload();
}}
</script>
</body>
</html>
"""


def escape_html(value: Any) -> str:
    """HTML text node向けに文字列をescapeする。

    Args:
        value: escape対象。

    Returns:
        escape済み文字列。
    """

    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
