#!/usr/bin/env python3
"""PowerPointの文字がslideからはみ出していないかを検査する。

agentはrender画像を見ても、はみ出しを見落とすことがある。LibreOfficeでPDF化すると、
slideの外へはみ出した文字は描画されず、`pdftotext`の出力から消える。`officecli view text`の
各行がPDFの同じpageに残っているかを比べ、消えた行を報告する。

Usage:
    pptx-check out.pptx
"""

from __future__ import annotations

import logging
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
from collections.abc import Sequence
from pathlib import Path

logger = logging.getLogger("pptx-check")

SLIDE_HEADER = re.compile(r"^=== /slide\[(\d+)\] ===$")
# 行頭の箇条書き記号は、PDF上で別の記号に置き換わることがあるため比較から外す。
BULLET = re.compile(r"^[\s・\-*•●◦▪]+")
# pdftotextは折り返し位置のhyphenを落として語を連結するため、空白とhyphenを比較から外す。
IGNORED = re.compile(r"[\s\-‐-―]+")


def slide_lines(view_text: str) -> dict[int, list[str]]:
    """`officecli view <pptx> text`の出力をslideごとの行へ分ける。

    Args:
        view_text: `officecli view text`の標準出力。

    Returns:
        slide番号 (1始まり) から、空行を除いた本文行へのmapping。
    """
    slides: dict[int, list[str]] = {}
    current: list[str] | None = None
    for line in view_text.splitlines():
        header = SLIDE_HEADER.match(line.strip())
        if header:
            current = slides.setdefault(int(header.group(1)), [])
        elif current is not None and line.strip():
            current.append(line)
    return slides


def normalize(text: str) -> str:
    """比較用に表記を揃え、箇条書き記号と空白を除く。

    pdftotextは和文と英数字の間へ空白を入れ、折り返しで改行を入れ、hyphenを落とすため、それらを除く。

    Args:
        text: 比較する文字列。

    Returns:
        正規化した文字列。
    """
    # pdftotextは全角記号を半角で出すことがあるため、NFKCで表記を揃える。
    return IGNORED.sub("", BULLET.sub("", unicodedata.normalize("NFKC", text)))


def find_clipped(
    slides: dict[int, list[str]], pages: Sequence[str]
) -> list[tuple[int, str]]:
    """PDFのpageに描画されていない行を探す。

    Args:
        slides: slide番号ごとの本文行。
        pages: PDFの各pageから抽出した文字列。

    Returns:
        (slide番号, 行) のlist。
    """
    clipped = []
    for number, lines in sorted(slides.items()):
        page = normalize(pages[number - 1]) if number <= len(pages) else ""
        clipped += [
            (number, line.strip())
            for line in lines
            if normalize(line) and normalize(line) not in page
        ]
    return clipped


def main(argv: Sequence[str]) -> int:
    """pptxをPDF化して、はみ出した行を標準出力へ報告する。

    Args:
        argv: `sys.argv`。`argv[1]`は検査するpptx。

    Returns:
        はみ出しが無ければ0、あれば1、引数やrenderの失敗は2。
    """
    started = time.perf_counter()
    logging.basicConfig(
        level=logging.INFO, stream=sys.stderr, format="%(name)s: %(message)s"
    )
    if len(argv) != 2 or not argv[1].endswith(".pptx") or not Path(argv[1]).is_file():
        logger.error("usage: pptx-check <file.pptx>")
        return 2
    source = Path(argv[1]).resolve()
    view = subprocess.run(
        ["officecli", "view", str(source), "text"],
        capture_output=True,
        text=True,
        check=False,
    )
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            [
                "soffice",
                "--headless",
                "--convert-to",
                "pdf",
                "--outdir",
                tmp,
                str(source),
            ],
            capture_output=True,
            check=False,
        )
        pdf = Path(tmp) / f"{source.stem}.pdf"
        if view.returncode != 0 or not pdf.exists():
            logger.error("officecli viewまたはPDF変換に失敗しました。")
            return 2
        text = subprocess.run(
            ["pdftotext", str(pdf), "-"], capture_output=True, text=True, check=True
        ).stdout
    clipped = find_clipped(slide_lines(view.stdout), text.split("\f"))
    for number, line in clipped:
        print(f"slide {number}: はみ出して表示されない行: {line}")
    if not clipped:
        print("OK: 全slideの文字が表示範囲内にあります。")
    logger.info("checked in %.1fs", time.perf_counter() - started)
    return 1 if clipped else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
