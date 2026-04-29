"""Format technology news findings into a Japanese Markdown report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from datetime import datetime, timezone
from typing import Any


def format_news_report(
    items: list[dict[str, Any]] | None = None,
    title: str = "技術ニュースレポート",
    focus: str = "生成AI、クラウド、FinOps、開発ツール",
) -> dict[str, Any]:
    """Format already-collected news items into Japanese Markdown.

    News collection itself should be done by Hermes with web/search tools so
    citations and source freshness remain visible to the user.
    """
    try:
        items = items or []
        report_date = datetime.now(timezone.utc).date().isoformat()
        lines = [
            "---",
            f"# {title} ({report_date})",
            "",
            f"- 📝 対象領域: {focus}",
            "",
            "## 🔥 本日の主要ニュース",
        ]
        if not items:
            lines.append("\n### 1. 情報不足: ニュース項目が渡されていません")
            lines.append("- URL：N/A")
            lines.append("- 概要：先に web/search や mcp_rss_get_feed で情報を収集してください。")
            lines.append("- 重要ポイント：要約済み項目が必要です。")
        for index, item in enumerate(items, start=1):
            headline = str(item.get("title") or item.get("headline") or "タイトル未設定")
            category = str(item.get("category") or item.get("genre") or "トピック")
            source = str(item.get("source") or "")
            url = str(item.get("url") or "")
            summary = str(item.get("summary") or "")
            impact = str(item.get("impact") or "")
            lines.append(f"\n### {index}. {category}: {headline}")
            if source and not url:
                lines.append(f"- URL：{source}")
            else:
                lines.append(f"- URL：{url or 'N/A'}")
            lines.append(f"- 概要：{summary or '概要未設定'}")
            lines.append(f"- 重要ポイント：{impact or '重要ポイント未設定'}")

        return {"ok": True, "content_markdown": "\n".join(lines), "metadata": {"items": len(items), "focus": focus}}
    except Exception as exc:
        return {"ok": False, "error": str(exc), "exception_type": exc.__class__.__name__}


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="JSON項目から日本語の技術ニュースレポートを整形します。")
    parser.add_argument("--items-json", help="JSON array of news items")
    parser.add_argument("--items-file", help="Path to a JSON file containing an array of news items")
    parser.add_argument("--title", default="技術ニュースレポート")
    parser.add_argument("--focus", default="生成AI、クラウド、FinOps、開発ツール")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.items_file:
        items = json.loads(Path(args.items_file).read_text(encoding="utf-8"))
    else:
        items = json.loads(args.items_json) if args.items_json else []
    result = format_news_report(items=items, title=args.title, focus=args.focus)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
