from __future__ import annotations

import base64
import copy
import datetime as dt
import hashlib
import json
import os
import re
import urllib.parse
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any

import yaml

from http_client import HttpClient


SECRET_FIELD_RE = re.compile(r"(password|secret|token|key|authorization|cookie|session)", re.IGNORECASE)


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


class SourceConnector(ABC):
    """データソース固有処理を隠蔽するconnector親class。"""

    def __init__(self, source_config: dict[str, Any], http_client: HttpClient) -> None:
        """connectorを初期化する。

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

    @abstractmethod
    def sync(self, state: dict[str, Any]) -> SyncBatch:
        """同期対象ページと次回checkpointを作る。

        Args:
            state: 前回成功時のsource別checkpoint。

        Returns:
            書き込み対象pageと更新後state。
        """

    @abstractmethod
    def check_status(self) -> dict[str, Any]:
        """sourceの接続状態を確認する。

        Args:
            None。

        Returns:
            source状態を表すdict。
        """

    def clone_state(self, state: dict[str, Any]) -> dict[str, Any]:
        """checkpoint stateを更新用にcopyする。

        Args:
            state: 前回成功時のsource別checkpoint。

        Returns:
            deep copyしたstate。
        """

        return copy.deepcopy(state)


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
        source_type: source connector種別。
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
        SyncError: 未対応認証方式が指定された場合。
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
    return f"{base_url.rstrip('/')}{normalized_path}" + (f"?{encoded_query}" if encoded_query else "")


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
