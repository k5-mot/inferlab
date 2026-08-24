"""ConnectorからSource Storeまでのingest orchestration。"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from llm_wiki_platform.connectors.base import SourceConnector
from llm_wiki_platform.models import ChangeKind
from llm_wiki_platform.source_store import SourceStore
from llm_wiki_platform.state import StateStore


@dataclass(frozen=True, slots=True)
class IngestResult:
    """1 sourceのingest集計結果。"""

    source: str
    discovered: int
    new: int
    updated: int
    unchanged: int
    unavailable: int

    def as_dict(self) -> dict[str, Any]:
        """run detailへ保存するJSON互換dictを返す。

        Returns:
            ingest集計値。
        """
        return {
            "source": self.source,
            "discovered": self.discovered,
            "new": self.new,
            "updated": self.updated,
            "unchanged": self.unchanged,
            "unavailable": self.unavailable,
        }


class IngestionService:
    """Connector実行、正規化、差分保存、checkpoint更新を一括管理する。"""

    def __init__(
        self,
        connectors: dict[str, SourceConnector],
        source_store: SourceStore,
        state_store: StateStore,
    ) -> None:
        """IngestionServiceを初期化する。

        Args:
            connectors: source名とConnectorの対応。
            source_store: Canonical Source Store。
            state_store: checkpointとstagingの保存先。

        Returns:
            なし。
        """
        self._connectors = connectors
        self._source_store = source_store
        self._state_store = state_store

    async def ingest(self, source_name: str) -> IngestResult:
        """指定sourceを取得し変更分を次回compileへstagingする。

        Args:
            source_name: 実行対象Connector名。

        Returns:
            差分種別ごとの集計結果。

        Raises:
            KeyError: Connectorが登録されていない場合。
            Exception: discover、fetch、normalize、storeが失敗した場合。
        """
        connector = self._connectors[source_name]
        previous_checkpoint = self._state_store.get_checkpoint(source_name)
        batch = await connector.discover(previous_checkpoint)
        counters = {kind: 0 for kind in ChangeKind}
        seen_ids: set[str] = set()
        successful_objects = []
        for source in batch.objects:
            raw = await connector.fetch(source)
            document = connector.normalize(source, raw)
            stored = self._source_store.store(document, raw, connector.raw_filename(source))
            counters[stored.change] += 1
            seen_ids.add(document.id)
            successful_objects.append(source)
            if stored.change is not ChangeKind.UNCHANGED:
                self._state_store.stage_openkb_document(
                    source_id=document.id,
                    source=document.source,
                    content_hash=stored.content_hash,
                    normalized_path=stored.normalized_path,
                    raw_path=stored.raw_path,
                )
        unavailable = (
            self._source_store.reconcile(source_name, seen_ids) if batch.complete_snapshot else 0
        )
        next_checkpoint = connector.checkpoint(tuple(successful_objects), previous_checkpoint)
        if next_checkpoint is not None:
            self._state_store.set_checkpoint(source_name, next_checkpoint)
        return IngestResult(
            source=source_name,
            discovered=len(batch.objects),
            new=counters[ChangeKind.NEW],
            updated=counters[ChangeKind.UPDATED],
            unchanged=counters[ChangeKind.UNCHANGED],
            unavailable=unavailable,
        )

    def connector_names(self) -> tuple[str, ...]:
        """登録済みConnector名を列挙する。

        Returns:
            source名のtuple。
        """
        return tuple(self._connectors)
