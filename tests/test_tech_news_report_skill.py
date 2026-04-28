import importlib.util
from pathlib import Path


def load_report_module():
    path = Path(__file__).resolve().parents[1] / "skills" / "tech-news-report-skill" / "report.py"
    spec = importlib.util.spec_from_file_location("tech_news_module_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def test_format_news_report_uses_supplied_items():
    report = load_report_module()

    result = report.format_news_report(
        items=[
            {
                "title": "Cloud cost tool update",
                "source": "Vendor blog",
                "url": "https://example.test/news",
                "summary": "A FinOps workflow was improved.",
                "impact": "Review cost dashboards.",
            }
        ]
    )

    assert result["ok"] is True
    assert "Cloud cost tool update" in result["content_markdown"]
    assert "重要ポイント: Review cost dashboards." in result["content_markdown"]
