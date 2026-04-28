"""Open WebUI API helpers focused on Channels and related files."""

from __future__ import annotations

import argparse
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

try:  # pragma: no cover - runtime convenience when requests exists.
    import requests  # type: ignore
except ImportError:  # pragma: no cover - standard-library fallback.
    requests = None  # type: ignore

DEFAULT_CHANNELS_LIST_PATH = "/api/v1/channels/"
DEFAULT_POST_PATH_TEMPLATE = "/api/v1/channels/{channel_id}/messages/post"
DEFAULT_TIMEOUT_SECONDS = 30
DEFAULT_MAX_MESSAGE_CHARS = 20000
DEFAULT_MAX_RETRIES = 3
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{15,}$")
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


class _UrllibResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text

    def json(self) -> Any:
        return json.loads(self.text)


class _UrllibRequests:
    @staticmethod
    def get(url: str, headers: dict[str, str] | None = None, timeout: int = DEFAULT_TIMEOUT_SECONDS) -> _UrllibResponse:
        request = urllib.request.Request(url, headers=headers or {}, method="GET")
        return _UrllibRequests._open(request, timeout)

    @staticmethod
    def post(
        url: str,
        headers: dict[str, str] | None = None,
        json: dict[str, Any] | None = None,
        timeout: int = DEFAULT_TIMEOUT_SECONDS,
    ) -> _UrllibResponse:
        body = None if json is None else __import__("json").dumps(json).encode("utf-8")
        request = urllib.request.Request(url, data=body, headers=headers or {}, method="POST")
        return _UrllibRequests._open(request, timeout)

    @staticmethod
    def _open(request: urllib.request.Request, timeout: int) -> _UrllibResponse:
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return _UrllibResponse(response.status, response.read().decode("utf-8", errors="replace"))
        except urllib.error.HTTPError as exc:
            return _UrllibResponse(exc.code, exc.read().decode("utf-8", errors="replace"))


def _http_client() -> Any:
    return requests or _UrllibRequests


def _env_int(name: str, default: int, *, minimum: int | None = None, maximum: int | None = None) -> int:
    value = os.getenv(name)
    try:
        parsed = int(value) if value else default
    except ValueError:
        parsed = default
    if minimum is not None:
        parsed = max(minimum, parsed)
    if maximum is not None:
        parsed = min(maximum, parsed)
    return parsed


def _base_url() -> str | None:
    value = os.getenv("OPEN_WEBUI_BASE_URL", "").strip()
    return value.rstrip("/") if value else None


def _api_key() -> str | None:
    return os.getenv("OPEN_WEBUI_API_KEY", "").strip() or None


def _timeout() -> int:
    return _env_int("OPEN_WEBUI_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS, minimum=1)


def _max_message_chars() -> int:
    return _env_int("OPEN_WEBUI_MAX_MESSAGE_CHARS", DEFAULT_MAX_MESSAGE_CHARS, minimum=1)


def _max_retries() -> int:
    return _env_int("OPEN_WEBUI_MAX_RETRIES", DEFAULT_MAX_RETRIES, minimum=1, maximum=3)


def _headers(api_key: str) -> dict[str, str]:
    return {
        "Accept": "application/json",
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }


def _redact(value: object) -> str:
    text = str(value)
    api_key = _api_key()
    if api_key:
        text = text.replace(api_key, "[REDACTED]")
    return text


def _config_error() -> dict[str, Any] | None:
    missing = []
    if not _base_url():
        missing.append("OPEN_WEBUI_BASE_URL")
    if not _api_key():
        missing.append("OPEN_WEBUI_API_KEY")
    if missing:
        return {"ok": False, "error": f"Missing required environment variable(s): {', '.join(missing)}"}
    return None


def _parse_response(response: Any) -> tuple[Any | None, str]:
    text = getattr(response, "text", "") or ""
    try:
        return response.json(), text
    except Exception:
        return None, text


def _error_message(status_code: int, payload: Any, text: str) -> str:
    if isinstance(payload, dict):
        detail = payload.get("detail") or payload.get("error") or payload.get("message")
        if detail:
            return f"Open WebUI API returned HTTP {status_code}: {_redact(detail)}"
    if text:
        return f"Open WebUI API returned HTTP {status_code}: {_redact(text)[:500]}"
    return f"Open WebUI API returned HTTP {status_code}"


def _request(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    config_error = _config_error()
    if config_error:
        return config_error

    base_url = _base_url()
    api_key = _api_key()
    assert base_url and api_key
    url = f"{base_url}{path}"
    client = _http_client()
    last_error: dict[str, Any] | None = None

    for attempt in range(1, _max_retries() + 1):
        try:
            if method == "GET":
                response = client.get(url, headers=_headers(api_key), timeout=_timeout())
            elif method == "POST":
                response = client.post(url, headers=_headers(api_key), json=body or {}, timeout=_timeout())
            else:
                return {"ok": False, "error": f"Unsupported HTTP method: {method}"}

            status_code = int(getattr(response, "status_code", 0))
            payload, text = _parse_response(response)
            if 200 <= status_code < 300:
                return {"ok": True, "status_code": status_code, "json": payload, "text": _redact(text)}

            last_error = {
                "ok": False,
                "error": _error_message(status_code, payload, text),
                "status_code": status_code,
                "response_text": _redact(text),
            }
            if isinstance(payload, dict):
                last_error["response"] = json.loads(_redact(json.dumps(payload, ensure_ascii=False)))
            if status_code < 500 or attempt >= _max_retries():
                return last_error
        except Exception as exc:
            last_error = {"ok": False, "error": _redact(exc)}
            if attempt >= _max_retries():
                return last_error

        time.sleep(0.1 * (2 ** (attempt - 1)))

    return last_error or {"ok": False, "error": "Open WebUI request failed"}


def _path_with_query(path: str, query: dict[str, Any]) -> str:
    clean = {key: value for key, value in query.items() if value is not None}
    if not clean:
        return path
    return f"{path}?{urllib.parse.urlencode(clean)}"


def _channels_from_payload(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        candidates = payload
    elif isinstance(payload, dict):
        candidates = payload.get("channels") if isinstance(payload.get("channels"), list) else payload.get("data", [])
    else:
        candidates = []

    channels: list[dict[str, Any]] = []
    for item in candidates or []:
        if not isinstance(item, dict):
            continue
        channel_id = item.get("id") or item.get("channel_id")
        if not channel_id:
            continue
        channels.append(
            {
                "id": str(channel_id),
                "name": str(item.get("name") or item.get("title") or ""),
                "description": item.get("description"),
                "raw": item,
            }
        )
    return channels


def list_channels() -> dict[str, Any]:
    """Fetch channels visible to the configured Open WebUI user."""
    path = os.getenv("OPEN_WEBUI_CHANNELS_LIST_PATH", DEFAULT_CHANNELS_LIST_PATH)
    if not path.startswith("/"):
        path = f"/{path}"
    result = _request("GET", path)
    if not result.get("ok"):
        return result
    return {"ok": True, "channels": _channels_from_payload(result.get("json"))}


def _normalize_channel_name(channel: str) -> str:
    return channel.strip().lstrip("#").strip()


def _looks_like_channel_id(channel: str) -> bool:
    value = channel.strip()
    return bool(UUID_RE.match(value) or ID_RE.match(value))


def resolve_channel_id(channel: str) -> dict[str, Any]:
    """Resolve a channel ID or #channel-name to an Open WebUI channel ID."""
    if not channel or not channel.strip():
        default_channel = os.getenv("OPEN_WEBUI_DEFAULT_CHANNEL", "").strip()
        if not default_channel:
            return {"ok": False, "error": "channel is required"}
        channel = default_channel

    value = channel.strip()
    if not value.startswith("#") and _looks_like_channel_id(value):
        return {"ok": True, "channel_id": value, "channel_name": None}

    channel_name = _normalize_channel_name(value)
    channels_result = list_channels()
    if not channels_result.get("ok"):
        return {
            "ok": False,
            "error": channels_result.get("error", "failed to list channels"),
            "status_code": channels_result.get("status_code"),
            "response_text": channels_result.get("response_text"),
        }

    for item in channels_result.get("channels", []):
        if item.get("name") == channel_name:
            return {"ok": True, "channel_id": str(item["id"]), "channel_name": channel_name}

    return {"ok": False, "error": f"channel not found: {channel_name}"}


def _post_path(channel_id: str) -> str:
    template = os.getenv("OPEN_WEBUI_CHANNELS_POST_PATH_TEMPLATE", DEFAULT_POST_PATH_TEMPLATE)
    path = template.format(channel_id=channel_id)
    return path if path.startswith("/") else f"/{path}"


def _message_id(payload: Any) -> str | None:
    if not isinstance(payload, dict):
        return None
    for key in ("id", "message_id"):
        if payload.get(key):
            return str(payload[key])
    data = payload.get("data")
    if isinstance(data, dict):
        for key in ("id", "message_id"):
            if data.get(key):
                return str(data[key])
    return None


def get_channel(channel: str) -> dict[str, Any]:
    resolved = resolve_channel_id(channel)
    if not resolved.get("ok"):
        return resolved
    channel_id = str(resolved["channel_id"])
    result = _request("GET", f"/api/v1/channels/{channel_id}")
    if not result.get("ok"):
        return result
    return {"ok": True, "channel_id": channel_id, "channel": result.get("json")}


def list_channel_messages(
    channel: str,
    skip: int = 0,
    limit: int = 50,
    include_threads: bool = False,
) -> dict[str, Any]:
    """Fetch channel messages, optionally including thread replies per message."""
    resolved = resolve_channel_id(channel)
    if not resolved.get("ok"):
        return resolved
    channel_id = str(resolved["channel_id"])
    path = _path_with_query(f"/api/v1/channels/{channel_id}/messages", {"skip": skip, "limit": limit})
    result = _request("GET", path)
    if not result.get("ok"):
        return result

    messages = result.get("json")
    if not isinstance(messages, list):
        messages = []
    if include_threads:
        for message in messages:
            if not isinstance(message, dict) or not message.get("id"):
                continue
            thread = get_message_thread(channel_id, str(message["id"]))
            if thread.get("ok"):
                message["thread"] = thread.get("messages", [])
    return {"ok": True, "channel_id": channel_id, "messages": messages}


def get_message_thread(channel: str, message_id: str, skip: int = 0, limit: int = 50) -> dict[str, Any]:
    resolved = resolve_channel_id(channel)
    if not resolved.get("ok"):
        return resolved
    channel_id = str(resolved["channel_id"])
    path = _path_with_query(
        f"/api/v1/channels/{channel_id}/messages/{message_id}/thread",
        {"skip": skip, "limit": limit},
    )
    result = _request("GET", path)
    if not result.get("ok"):
        return result
    messages = result.get("json")
    return {"ok": True, "channel_id": channel_id, "message_id": message_id, "messages": messages if isinstance(messages, list) else []}


def get_file_metadata(file_id: str) -> dict[str, Any]:
    result = _request("GET", f"/api/v1/files/{urllib.parse.quote(file_id)}")
    if not result.get("ok"):
        return result
    return {"ok": True, "file_id": file_id, "file": result.get("json")}


def get_file_content(file_id: str, *, data_content: bool = True) -> dict[str, Any]:
    """Fetch extracted text content, falling back to raw file endpoint when needed."""
    encoded = urllib.parse.quote(file_id)
    if data_content:
        result = _request("GET", f"/api/v1/files/{encoded}/data/content")
        if result.get("ok"):
            payload = result.get("json")
            content = payload.get("content") if isinstance(payload, dict) else None
            return {"ok": True, "file_id": file_id, "content": content or "", "response": payload}
    result = _request("GET", f"/api/v1/files/{encoded}/content")
    if not result.get("ok"):
        return result
    return {"ok": True, "file_id": file_id, "content": result.get("text", ""), "response": result.get("json")}


def post_message(
    channel: str,
    content: str,
    thread_id: str | None = None,
    metadata: dict | None = None,
    data: dict | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Post Markdown content to an Open WebUI channel."""
    if not content or not content.strip():
        return {"ok": False, "error": "content is required"}
    max_chars = _max_message_chars()
    if len(content) > max_chars:
        return {"ok": False, "error": f"content exceeds OPEN_WEBUI_MAX_MESSAGE_CHARS ({max_chars})"}

    meta = {"source": "hermes-agent", "skill": "open-webui-skill", **(metadata or {})}
    request_body: dict[str, Any] = {"content": content, "meta": meta}
    if data:
        request_body["data"] = data
    if thread_id:
        request_body["parent_id"] = thread_id

    if dry_run:
        preview_channel = channel.strip() if channel else os.getenv("OPEN_WEBUI_DEFAULT_CHANNEL", "").strip()
        if not preview_channel:
            return {"ok": False, "error": "channel is required"}
        preview_channel_id = preview_channel if _looks_like_channel_id(preview_channel) else _normalize_channel_name(preview_channel)
        return {
            "ok": True,
            "dry_run": True,
            "channel_id": preview_channel_id,
            "request": {
                "method": "POST",
                "path": _post_path(preview_channel_id),
                "channel_id": preview_channel_id,
                "body": request_body,
                "requires_resolution": not _looks_like_channel_id(preview_channel),
            },
        }

    resolved = resolve_channel_id(channel)
    if not resolved.get("ok"):
        return resolved

    channel_id = str(resolved["channel_id"])
    result = _request("POST", _post_path(channel_id), request_body)
    if not result.get("ok"):
        return result

    payload = result.get("json")
    response: dict[str, Any] = payload if isinstance(payload, dict) else {}
    output = {"ok": True, "channel_id": channel_id, "message_id": _message_id(payload), "response": response}
    if not response and result.get("text"):
        output["response_text"] = str(result["text"])
    return output


def _read_content(path_or_text: str | None) -> str:
    if not path_or_text:
        return ""
    path = Path(path_or_text)
    if path.exists():
        return path.read_text(encoding="utf-8")
    return path_or_text


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Open WebUI Channels helper.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list-channels")

    channel_parser = subparsers.add_parser("get-channel")
    channel_parser.add_argument("--channel", required=True)

    resolve_parser = subparsers.add_parser("resolve-channel")
    resolve_parser.add_argument("--channel", required=True)

    messages_parser = subparsers.add_parser("messages")
    messages_parser.add_argument("--channel", required=True)
    messages_parser.add_argument("--skip", type=int, default=0)
    messages_parser.add_argument("--limit", type=int, default=50)
    messages_parser.add_argument("--include-threads", action="store_true")

    thread_parser = subparsers.add_parser("thread")
    thread_parser.add_argument("--channel", required=True)
    thread_parser.add_argument("--message-id", required=True)
    thread_parser.add_argument("--skip", type=int, default=0)
    thread_parser.add_argument("--limit", type=int, default=50)

    file_parser = subparsers.add_parser("file-content")
    file_parser.add_argument("--file-id", required=True)
    file_parser.add_argument("--raw", action="store_true")

    post_parser = subparsers.add_parser("post")
    post_parser.add_argument("--channel", required=True)
    post_parser.add_argument("--file")
    post_parser.add_argument("--content")
    post_parser.add_argument("--thread-id")
    post_parser.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.command == "list-channels":
        result = list_channels()
    elif args.command == "get-channel":
        result = get_channel(args.channel)
    elif args.command == "resolve-channel":
        result = resolve_channel_id(args.channel)
    elif args.command == "messages":
        result = list_channel_messages(args.channel, skip=args.skip, limit=args.limit, include_threads=args.include_threads)
    elif args.command == "thread":
        result = get_message_thread(args.channel, args.message_id, skip=args.skip, limit=args.limit)
    elif args.command == "file-content":
        result = get_file_content(args.file_id, data_content=not args.raw)
    elif args.command == "post":
        content = _read_content(args.file) if args.file else _read_content(args.content)
        result = post_message(args.channel, content, thread_id=args.thread_id, dry_run=args.dry_run)
    else:
        result = {"ok": False, "error": f"unknown command: {args.command}"}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())

