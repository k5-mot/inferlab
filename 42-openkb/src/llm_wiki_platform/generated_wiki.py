"""OpenKB Generated WikiのMarkdown pageを読み込む。"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

_WIKILINK_PATTERN = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")


@dataclass(frozen=True, slots=True)
class GeneratedPage:
    """OpenKB Generated Wiki内の1 Markdown page。"""

    openkb_id: str
    title: str
    category: str
    markdown: str
    content_hash: str


def load_generated_pages(generated_wiki_path: Path) -> list[GeneratedPage]:
    """Generated Wiki directoryから公開対象Markdownを読み込む。

    Args:
        generated_wiki_path: read-only mountされたOpenKB wiki directory。

    Returns:
        stable relative path順のGenerated Page一覧。

    Raises:
        FileNotFoundError: wiki directoryが存在しない場合。
        ValueError: frontmatterがmappingではない場合。
    """
    if not generated_wiki_path.is_dir():
        raise FileNotFoundError(f"Generated Wiki directoryが存在しません: {generated_wiki_path}")
    pages: list[GeneratedPage] = []
    for path in sorted(generated_wiki_path.rglob("*.md")):
        relative = path.relative_to(generated_wiki_path)
        if relative.parts and relative.parts[0] in {"reports", "raw"}:
            continue
        text = path.read_text(encoding="utf-8")
        frontmatter, markdown = split_frontmatter(text)
        title = str(frontmatter.get("title") or first_heading(markdown) or path.stem)
        category = relative.parts[0].lower() if len(relative.parts) > 1 else "concepts"
        digest_input = f"{title}\0{category}\0{markdown}".encode()
        digest = hashlib.sha256(digest_input).hexdigest()
        pages.append(
            GeneratedPage(
                openkb_id=relative.as_posix(),
                title=title,
                category=category,
                markdown=markdown,
                content_hash=digest,
            )
        )
    return pages


def split_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    """Markdown frontmatterと本文を分離する。

    Args:
        text: Generated Wiki Markdown。

    Returns:
        frontmatter objectと本文。

    Raises:
        ValueError: frontmatterがmappingではない場合。
    """
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end < 0:
        return {}, text
    loaded = yaml.safe_load(text[4:end]) or {}
    if not isinstance(loaded, dict):
        raise ValueError("Generated Wiki frontmatterはmappingである必要があります")
    return dict(loaded), text[end + 5 :]


def first_heading(markdown: str) -> str | None:
    """Markdown最初のH1をtitle候補として取得する。

    Args:
        markdown: Markdown本文。

    Returns:
        H1 text。存在しなければNone。
    """
    for line in markdown.splitlines():
        if line.startswith("# "):
            return line.removeprefix("# ").strip()
    return None


def convert_wikilinks(markdown: str, page_urls: dict[str, str]) -> str:
    """解決可能なOpenKB wikilinkをMarkdown linkへ変換する。

    Args:
        markdown: OpenKB page本文。
        page_urls: page titleと公開先URLの対応。

    Returns:
        wikilink変換後のMarkdown。
    """

    def replace(match: re.Match[str]) -> str:
        """1つのwikilinkをURL解決できる場合だけMarkdown化する。

        Args:
            match: wikilink regex match。

        Returns:
            Markdown linkまたは元wikilink。
        """
        target = match.group(1).strip()
        label = (match.group(2) or target).strip()
        url = page_urls.get(target)
        return f"[{label}]({url})" if url else match.group(0)

    return _WIKILINK_PATTERN.sub(replace, markdown)
