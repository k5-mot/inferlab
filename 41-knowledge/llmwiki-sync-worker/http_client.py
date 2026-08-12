from __future__ import annotations

import json
import ssl
import urllib.request
from typing import Any


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
