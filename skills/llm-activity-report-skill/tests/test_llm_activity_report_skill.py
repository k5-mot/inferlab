import importlib.util
from datetime import datetime, timezone
from pathlib import Path


def load_report_module():
    path = Path(__file__).resolve().parents[1] / "scripts" / "report.py"
    spec = importlib.util.spec_from_file_location("activity_report_module_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def ns(value):
    return int(value.timestamp() * 1_000_000_000)


def test_channel_links_are_channel_only_and_deduplicated(monkeypatch):
    report = load_report_module()
    monkeypatch.setenv("OPEN_WEBUI_PUBLIC_URL", "http://192.168.3.10:31001")

    links = report._channel_links(
        [
            {"_channel_id": "2b63b27b-fc60-4b84-bb04-e51d2fced360", "_channel_name": "report", "id": "m1"},
            {"_channel_id": "2b63b27b-fc60-4b84-bb04-e51d2fced360", "_channel_name": "report", "id": "m2"},
        ]
    )

    expected = "http://192.168.3.10:31001/channels/2b63b27b-fc60-4b84-bb04-e51d2fced360"
    assert links == f"[#report]({expected})"
    assert "message" not in links


def test_generate_activity_report_formats_channel_messages(monkeypatch):
    report = load_report_module()
    monkeypatch.setenv("OPEN_WEBUI_PUBLIC_URL", "https://webui.example")
    created = datetime(2026, 4, 28, 3, 0, tzinfo=timezone.utc)

    def fake_messages(channel, limit=100, include_threads=True):
        return {
            "ok": True,
            "channel_id": "ch_report",
            "messages": [
                {
                    "id": "msg1",
                    "created_at": ns(created),
                    "content": "Investigate model cost and deploy fix",
                    "user": {"name": "alice"},
                    "data": {"files": [{"id": "file1"}]},
                }
            ],
        }

    monkeypatch.setattr(report, "list_channel_messages", fake_messages)

    result = report.generate_activity_report(
        "report",
        since="2026-04-28T00:00:00+00:00",
        until="2026-04-28T23:59:59+00:00",
        include_langfuse=False,
        include_all_openwebui=False,
    )

    assert result["ok"] is True
    markdown = result["content_markdown"]
    assert "## 📊 アクティビティレポート (2026-04-29)" in markdown
    assert "📅 集計期間：2026-04-28T00:00:00+00:00" in markdown
    assert "💬 チャネル投稿：1件 / 🤖 チャットメッセージ：0件 / 📚 新規ナレッジ：0件" in markdown
    assert "参照ファイル数" not in markdown
    assert "   - 🧭 概要：" in markdown
    assert "   - 👥 関連ユーザー：" in markdown
    assert "   - 🔗 URL：" in markdown
    assert "[#report](https://webui.example/channels/ch_report)" in markdown
    assert "message:msg1" not in markdown
    assert "   - ⏰ 期限：" in markdown
    assert "alice：🗨️ 1件のチャンネル投稿" in markdown
    assert result["summary_input"]["channel_messages"][0]["content"] == "Investigate model cost and deploy fix"
    assert result["summary_input"]["channel_messages"][0]["channel_url"] == "https://webui.example/channels/ch_report"


def test_generate_activity_report_collects_all_openwebui_activity(monkeypatch):
    report = load_report_module()
    monkeypatch.setenv("OPEN_WEBUI_PUBLIC_URL", "https://webui.example")
    created = datetime(2026, 4, 28, 3, 0, tzinfo=timezone.utc)

    monkeypatch.setattr(
        report,
        "list_channels",
        lambda: {"ok": True, "channels": [{"id": "ch1", "name": "general"}]},
    )
    monkeypatch.setattr(
        report,
        "list_all_channel_messages",
        lambda channel, page_size=100, max_pages=100, include_threads=True: {
            "ok": True,
            "channel_id": channel,
            "messages": [
                {
                    "id": "msg1",
                    "created_at": ns(created),
                    "content": "Investigate incident",
                    "user": {"name": "alice"},
                }
            ],
        },
    )
    monkeypatch.setattr(
        report,
        "list_all_db_chats",
        lambda: {
            "ok": True,
            "chats": [
                {
                    "id": "chat1",
                    "user": {"name": "bob"},
                    "updated_at": created.timestamp(),
                    "chat": {
                        "title": "Daily chat",
                        "history": {
                            "messages": {
                                "c1": {"id": "c1", "role": "user", "content": "Review model cost"}
                            }
                        },
                    },
                }
            ],
        },
    )
    monkeypatch.setattr(
        report,
        "list_all_knowledge",
        lambda include_details=True: {
            "ok": True,
            "knowledge": [{"id": "kb1", "name": "Runbook", "created_at": created.timestamp()}],
        },
    )

    result = report.generate_activity_report(
        since="2026-04-28T00:00:00+00:00",
        until="2026-04-28T23:59:59+00:00",
        include_langfuse=False,
    )

    assert result["ok"] is True
    markdown = result["content_markdown"]
    assert "📅 集計期間：2026-04-28T00:00:00+00:00" in markdown
    assert "チャネル投稿：1件 / 🤖 チャットメッセージ：1件 / 📚 新規ナレッジ：1件" in markdown
    assert "general (1)" in markdown
    assert "   - 🧭 概要：" in markdown
    assert "   - 👥 関連ユーザー：" in markdown
    assert "   - 🔗 URL：" in markdown
    assert "/c/chat1" not in markdown
    assert "message:c1" not in markdown
    assert "なし（チャットは個人情報保護のためリンク非掲載）" in markdown
    assert "bob：🗨️ 0件のチャンネル投稿、🤖 1件のチャット利用" in markdown
    assert "Runbook" in markdown
    assert result["summary_input"]["chat_messages"][0]["content"] == "Review model cost"
    assert "chat_id" not in result["summary_input"]["chat_messages"][0]
    assert result["metadata"]["channels"] == 1
    assert result["metadata"]["chats"] == 1
    assert result["metadata"]["knowledge"] == 1
