"""pptx-checkの判定関数のtest。

LibreOfficeとpdftotextの出力の癖 (全角記号の半角化、和欧間の空白、折り返し位置のhyphen削除) を
はみ出しと誤判定しないことを検査する。
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from types import ModuleType

CHECKER = (
    Path(__file__).resolve().parents[1]
    / "20-owui"
    / "open-terminal"
    / "pi"
    / "pptx_check.py"
)


def load_checker() -> ModuleType:
    """pptx_check.pyをmoduleとして読み込む。

    Returns:
        読み込んだmodule。

    Raises:
        RuntimeError: module specを作成できない場合。
    """
    spec = importlib.util.spec_from_file_location("pptx_check", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {CHECKER}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checker = load_checker()

VIEW_TEXT = """=== /slide[1] ===
認証基盤 概要

=== /slide[2] ===
方針
  - アクセストークン：15分（auth-design-memo.md）
  - 監査ログは1年間保存する。
"""


class PptxCheckTest(unittest.TestCase):
    """slide本文とPDF本文の比較を検査する。"""

    def test_slide_lines_groups_lines_by_slide(self) -> None:
        """slide見出しごとに空行を除いた行を集める。"""
        self.assertEqual(
            checker.slide_lines(VIEW_TEXT),
            {
                1: ["認証基盤 概要"],
                2: [
                    "方針",
                    "  - アクセストークン：15分（auth-design-memo.md）",
                    "  - 監査ログは1年間保存する。",
                ],
            },
        )

    def test_render_quirks_are_not_reported(self) -> None:
        """半角化、空白、折り返しhyphenの削除は、表示されている行として扱う。"""
        pages = [
            "認証基盤 概要",
            "方針\n- アクセストークン: 15 分 (auth-design\nmemo.md)\n- 監査ログは 1 年間保存する。",
        ]
        self.assertEqual(
            checker.find_clipped(checker.slide_lines(VIEW_TEXT), pages), []
        )

    def test_missing_lines_and_pages_are_reported(self) -> None:
        """PDFに無い行と、pageごと無いslideの行を報告する。"""
        pages = [
            "認証基盤 概要",
            "方針\n- アクセストークン: 15 分 (auth-design-memo.md)",
        ]
        self.assertEqual(
            checker.find_clipped(checker.slide_lines(VIEW_TEXT), pages),
            [(2, "- 監査ログは1年間保存する。")],
        )
        self.assertEqual(checker.find_clipped({3: ["本文"]}, pages), [(3, "本文")])


if __name__ == "__main__":
    unittest.main()
