"""Generate Japanese activity reports from Open WebUI Channels and optional Langfuse data."""

from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


def _load_open_webui_client() -> Any:
    client_path = Path(__file__).resolve().parents[1] / "open-webui-skill" / "client.py"
    spec = importlib.util.spec_from_file_location("openwebui_client_for_activity_report", client_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Unable to load open-webui-skill client from {client_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


list_channel_messages = _load_open_webui_client().list_channel_messages


def _parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _message_time_ns(message: dict[str, Any]) -> datetime | None:
    value = message.get("created_at")
    if value is None:
        return None
    try:
        return datetime.fromtimestamp(int(value) / 1_000_000_000, tz=timezone.utc)
    except (TypeError, ValueError, OSError):
        return None


def _default_since() -> datetime:
    return datetime.now(timezone.utc) - timedelta(hours=24)


def _user_label(message: dict[str, Any]) -> str:
    user = message.get("user")
    if isinstance(user, dict):
        return str(user.get("name") or user.get("email") or user.get("id") or message.get("user_id") or "unknown")
    return str(message.get("user_id") or "unknown")


def _extract_file_ids(message: dict[str, Any]) -> list[str]:
    file_ids: list[str] = []
    data = message.get("data")
    if isinstance(data, dict):
        for item in data.get("files") or []:
            if isinstance(item, dict) and item.get("id"):
                file_ids.append(str(item["id"]))
    return file_ids


def _fetch_langfuse_traces(since_dt: datetime, until_dt: datetime, limit: int = 50) -> dict[str, Any]:
    host = os.getenv("LANGFUSE_HOST", "").rstrip("/")
    public_key = os.getenv("LANGFUSE_PUBLIC_KEY", "")
    secret_key = os.getenv("LANGFUSE_SECRET_KEY", "")
    if not (host and public_key and secret_key):
        return {"ok": False, "error": "この実行ではLangfuse認証情報が設定されていません。"}

    query = urllib.parse.urlencode(
        {
            "fromTimestamp": since_dt.isoformat().replace("+00:00", "Z"),
            "toTimestamp": until_dt.isoformat().replace("+00:00", "Z"),
            "limit": min(max(limit, 1), 100),
        }
    )
    token = base64.b64encode(f"{public_key}:{secret_key}".encode("utf-8")).decode("ascii")
    request = urllib.request.Request(
        f"{host}/api/public/traces?{query}",
        headers={"Authorization": f"Basic {token}", "Accept": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.loads(response.read().decode("utf-8"))
        data = payload.get("data") if isinstance(payload, dict) else payload
        traces = data if isinstance(data, list) else []
        return {"ok": True, "traces": traces, "count": len(traces)}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def _langfuse_lines(since_dt: datetime, until_dt: datetime) -> list[str]:
    traces_result = _fetch_langfuse_traces(since_dt, until_dt)
    if not traces_result.get("ok"):
        return [f"- {traces_result.get('error', 'Langfuseデータを取得できませんでした。')}"]

    traces = traces_result.get("traces", [])
    names = Counter(str(trace.get("name") or "unnamed") for trace in traces if isinstance(trace, dict))
    users = Counter(str(trace.get("userId") or "unknown") for trace in traces if isinstance(trace, dict))
    lines = [f"- 確認したトレース数: {len(traces)}"]
    if names:
        lines.append("- 主なトレース名: " + ", ".join(f"{name} ({count})" for name, count in names.most_common(5)))
    if users:
        lines.append("- 主なLangfuseユーザー: " + ", ".join(f"{user} ({count})" for user, count in users.most_common(5)))
    if not traces:
        lines.append("- 指定期間のLangfuseトレースは返されませんでした。")
    return lines


def generate_activity_report(
    channel: str,
    since: str | None = None,
    until: str | None = None,
    limit: int = 100,
    include_threads: bool = True,
    include_langfuse: bool = True,
) -> dict[str, Any]:
    """Fetch channel messages and produce a Japanese Markdown activity report."""
    try:
        since_dt = _parse_time(since) or _default_since()
        until_dt = _parse_time(until) or datetime.now(timezone.utc)
        messages_result = list_channel_messages(channel, limit=limit, include_threads=include_threads)
        if not messages_result.get("ok"):
            return {"ok": False, "error": messages_result.get("error", "チャンネル投稿の取得に失敗しました"), "details": messages_result}

        messages = []
        for message in messages_result.get("messages", []):
            if not isinstance(message, dict):
                continue
            created = _message_time_ns(message)
            if created is None or created < since_dt or created > until_dt:
                continue
            messages.append(message)

        by_user: dict[str, list[dict[str, Any]]] = defaultdict(list)
        file_count = 0
        for message in messages:
            by_user[_user_label(message)].append(message)
            file_count += len(_extract_file_ids(message))

        channel_id = messages_result.get("channel_id", channel)
        report_date = until_dt.astimezone().date().isoformat()
        lines = [
            "---",
            f"# 📊 アクティビティレポート ({report_date})",
            "",
            f"- 🔢 合計LLM呼び出し回数：{len(messages)}回",
            f"- 📝 対象チャンネル `{channel}` (`{channel_id}`)、期間 {since_dt.isoformat()} 〜 {until_dt.isoformat()} の活動を集計。",
            f"- 👥 活動ユーザー数：{len(by_user)}名 / 参照ファイル数：{file_count}件",
            "",
            "## 🔥 本日の主要イベント",
        ]

        sorted_users = sorted(by_user.items(), key=lambda item: (-len(item[1]), item[0]))
        if sorted_users:
            for index, (user, user_messages) in enumerate(sorted_users[:3], start=1):
                snippets = [str(msg.get("content") or "").strip().replace("\n", " ")[:100] for msg in user_messages[:2]]
                message_ids = [str(msg.get("id") or "") for msg in user_messages[:3] if msg.get("id")]
                summary = " / ".join([text for text in snippets if text]) or "投稿内容の要約を生成できませんでした。"
                related_posts = ", ".join(f"message:{msg_id}" for msg_id in message_ids) or "なし"
                lines.extend(
                    [
                        f"{index}. {user}の主要アクティビティ",
                        f"   - 説明：{summary}",
                        f"   - 関連ユーザー：{user}",
                        f"   - 関連投稿：{related_posts}",
                    ]
                )
        else:
            lines.extend(
                [
                    "1. 主要イベントなし",
                    "   - 説明：指定期間内の投稿は見つかりませんでした。",
                    "   - 関連ユーザー：なし",
                    "   - 関連投稿：なし",
                ]
            )

        action_words = Counter()
        for message in messages:
            text = str(message.get("content") or "").lower()
            for word in ("deploy", "fix", "review", "investigate", "release", "error", "incident", "cost", "model", "障害", "費用", "調査", "修正", "リリース"):
                if word in text:
                    action_words[word] += 1

        lines.extend(["", "## ✅ 推奨アクションアイテム"])
        if action_words:
            for index, (word, count) in enumerate(action_words.most_common(3), start=1):
                lines.extend(
                    [
                        f"{index}. `{word}` に関する確認",
                        f"   - 詳細：`{word}` が {count} 件の投稿で言及されています。担当者と期限を確認してください。",
                        "   - 担当者：未定（チャンネルオーナー確認）",
                        "   - 期限：次回定例まで",
                    ]
                )
        else:
            lines.extend(
                [
                    "1. 継続監視",
                    "   - 詳細：目立ったアクションまたはリスク関連キーワードは検出されませんでした。",
                    "   - 担当者：チャンネル参加者全員",
                    "   - 期限：次回レポートまで",
                ]
            )

        lines.extend(["", "## ⚠️ 潜在的な問題"])
        risk_words = [(word, count) for word, count in action_words.items() if word in {"error", "incident", "障害"}]
        if risk_words:
            for index, (word, count) in enumerate(risk_words[:3], start=1):
                lines.extend(
                    [
                        f"{index}. `{word}` の継続監視が必要",
                        f"   - 詳細：`{word}` が {count} 件の投稿で言及されています。根本原因の特定状況を確認してください。",
                        "   - 関連ユーザー：未特定（該当スレッド確認）",
                        "   - 関連投稿：チャンネル内の該当メッセージを参照",
                    ]
                )
        else:
            lines.extend(
                [
                    "1. 顕在化した重大リスクなし",
                    "   - 詳細：エラー・障害系キーワードの集中は確認されませんでした。",
                    "   - 関連ユーザー：なし",
                    "   - 関連投稿：なし",
                ]
            )

        lines.extend(["", "### 👥 ユーザー別アクティビティ"])
        if sorted_users:
            for user, user_messages in sorted_users:
                snippets = [str(msg.get("content") or "").strip().replace("\n", " ")[:100] for msg in user_messages[:2]]
                lines.append(f"- {user}：🗨️ {len(user_messages)}件のチャンネル投稿、🤖 0件のチャット利用")
                for snippet in snippets:
                    if snippet:
                        lines.append(f"  - `{snippet}`")
        else:
            lines.append("- 対象ユーザーの投稿はありませんでした。")

        if include_langfuse:
            lines.extend(["", "### 🔍 Langfuse補足", *_langfuse_lines(since_dt, until_dt)])
        return {
            "ok": True,
            "content_markdown": "\n".join(lines),
            "metadata": {
                "channel": channel,
                "channel_id": channel_id,
                "since": since_dt.isoformat(),
                "until": until_dt.isoformat(),
                "messages": len(messages),
            },
        }
    except Exception as exc:
        return {"ok": False, "error": str(exc), "exception_type": exc.__class__.__name__}


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Open WebUI Channelsから日本語のLLM活動レポートを生成します。")
    parser.add_argument("--channel", default=os.getenv("OPEN_WEBUI_DEFAULT_CHANNEL", "report"))
    parser.add_argument("--since")
    parser.add_argument("--until")
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--no-threads", action="store_true")
    parser.add_argument("--no-langfuse", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    result = generate_activity_report(
        channel=args.channel,
        since=args.since,
        until=args.until,
        limit=args.limit,
        include_threads=not args.no_threads,
        include_langfuse=not args.no_langfuse,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
