import importlib.util
from datetime import datetime, timezone
from pathlib import Path


def load_report_module():
    path = Path(__file__).resolve().parents[1] / "skills" / "llm-activity-report-skill" / "report.py"
    spec = importlib.util.spec_from_file_location("activity_report_module_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def ns(value):
    return int(value.timestamp() * 1_000_000_000)


def test_generate_activity_report_formats_channel_messages(monkeypatch):
    report = load_report_module()
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
    )

    assert result["ok"] is True
    assert "LLM活動レポート - report" in result["content_markdown"]
    assert "alice: 1 件の投稿" in result["content_markdown"]
    assert "参照ファイル数: 1" in result["content_markdown"]
