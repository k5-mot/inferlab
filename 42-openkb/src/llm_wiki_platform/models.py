"""パイプライン全体で共有するドメインモデル。"""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class Authority(StrEnum):
    """情報源の位置付けを表す。"""

    AUTHORITATIVE = "authoritative"
    OPERATIONAL = "operational"
    DISCUSSION = "discussion"
    REFERENCE = "reference"


class SourceObject(BaseModel):
    """Connectorが発見した取得対象を表す。"""

    model_config = ConfigDict(extra="forbid", frozen=True)

    id: str
    source: str
    source_type: str
    source_instance: str
    source_id: str
    title: str
    url: str | None = None
    updated_at: datetime | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class KnowledgeDocument(BaseModel):
    """Source固有形式を正規化したCanonical Documentを表す。"""

    model_config = ConfigDict(extra="forbid", frozen=True)

    id: str
    source: str
    source_type: str
    source_instance: str
    source_id: str
    title: str
    content: str
    content_format: str = "markdown"
    url: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    authors: tuple[str, ...] = ()
    labels: tuple[str, ...] = ()
    scope: dict[str, str] = Field(default_factory=dict)
    authority: Authority = Authority.REFERENCE
    metadata: dict[str, Any] = Field(default_factory=dict)

    def render_markdown(self) -> str:
        """OpenKBへ渡すprovenance付きMarkdownを生成する。

        Returns:
            文書本文とsource metadataを含むMarkdown。
        """
        metadata_lines = [
            "---",
            f'source_id: "{self.id}"',
            f'source: "{self.source}"',
            f'authority: "{self.authority.value}"',
        ]
        if self.url:
            metadata_lines.append(f'source_url: "{self.url}"')
        metadata_lines.extend(["---", "", f"# {self.title}", "", self.content.strip(), ""])
        return "\n".join(metadata_lines)


class DocumentState(StrEnum):
    """Source Store上の文書状態を表す。"""

    ACTIVE = "active"
    UNAVAILABLE = "unavailable"


class ChangeKind(StrEnum):
    """前回取り込み結果との差分種別を表す。"""

    NEW = "new"
    UPDATED = "updated"
    UNCHANGED = "unchanged"
    DELETED = "deleted"
