"""Generated Wiki公開先の共通interfaceと結果型を提供する。"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True, slots=True)
class PublishResult:
    """1つの公開先に対するpublish集計結果。"""

    generated: int
    created: int
    updated: int
    unchanged: int
    unavailable: int
    dry_run: bool

    def as_dict(self) -> dict[str, int | bool]:
        """run detailへ保存するJSON互換dictを返す。

        Returns:
            publish集計値。
        """
        return {
            "generated": self.generated,
            "created": self.created,
            "updated": self.updated,
            "unchanged": self.unchanged,
            "unavailable": self.unavailable,
            "dry_run": self.dry_run,
        }


class Publisher(Protocol):
    """Generated Wiki公開先が実装する共通interface。"""

    async def publish(self) -> PublishResult:
        """Generated Wikiを公開先へ反映する。

        Returns:
            公開先単位のpublish集計結果。
        """
        ...
