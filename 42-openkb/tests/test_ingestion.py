"""ingest orchestrationとSource Storeの差分管理を検証する。"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from llm_wiki_platform.connectors.base import ConnectorBatch, SourceConnector
from llm_wiki_platform.ingestion import IngestionService
from llm_wiki_platform.models import Authority, KnowledgeDocument, SourceObject
from llm_wiki_platform.source_store import SourceStore
from llm_wiki_platform.state import StateStore


@dataclass(frozen=True, slots=True)
class FakeItem:
    """test Connectorへ渡すsource item。"""

    source_id: str
    content: str


class FakeConnector(SourceConnector):
    """filesystemと外部APIに依存しないtest Connector。"""

    name = "fake"

    def __init__(self, items: list[FakeItem]) -> None:
        """FakeConnectorを初期化する。

        Args:
            items: discoverで返す初期item。

        Returns:
            なし。
        """
        self.items = items

    async def discover(self, checkpoint: str | None) -> ConnectorBatch:
        """現在のitemsを完全snapshotとして返す。

        Args:
            checkpoint: 前回checkpoint。testでは使用しない。

        Returns:
            現在のSource Object一覧。
        """
        del checkpoint
        objects = tuple(
            SourceObject(
                id=f"fake:test:item:{item.source_id}",
                source=self.name,
                source_type="item",
                source_instance="test",
                source_id=item.source_id,
                title=f"Item {item.source_id}",
                metadata={"content": item.content},
            )
            for item in self.items
        )
        return ConnectorBatch(objects=objects, complete_snapshot=True)

    async def fetch(self, source: SourceObject) -> bytes:
        """Source Object内のtest contentをbytesで返す。

        Args:
            source: test Source Object。

        Returns:
            UTF-8 content。
        """
        return str(source.metadata["content"]).encode("utf-8")

    def normalize(self, source: SourceObject, raw: bytes) -> KnowledgeDocument:
        """test contentをCanonical Documentへ変換する。

        Args:
            source: test Source Object。
            raw: UTF-8 content。

        Returns:
            reference authorityのKnowledgeDocument。
        """
        return KnowledgeDocument(
            id=source.id,
            source=source.source,
            source_type=source.source_type,
            source_instance=source.source_instance,
            source_id=source.source_id,
            title=source.title,
            content=raw.decode("utf-8"),
            authority=Authority.REFERENCE,
        )

    def checkpoint(self, objects: tuple[SourceObject, ...], previous: str | None) -> str | None:
        """処理件数をtest checkpointとして返す。

        Args:
            objects: 処理済みSource Object。
            previous: 前回checkpoint。

        Returns:
            objectがあれば件数、なければprevious。
        """
        return str(len(objects)) if objects else previous


async def test_ingest_stages_changes_and_skips_unchanged_documents(tmp_path: Path) -> None:
    """新規と更新だけがOpenKB stagingへ登録されることを検証する。"""
    state_store = StateStore(tmp_path / "state.db")
    source_store = SourceStore(tmp_path / "source", state_store)
    connector = FakeConnector([FakeItem("1", "alpha"), FakeItem("2", "beta")])
    service = IngestionService({"fake": connector}, source_store, state_store)

    first = await service.ingest("fake")
    second = await service.ingest("fake")
    connector.items = [FakeItem("1", "alpha updated"), FakeItem("2", "beta")]
    third = await service.ingest("fake")

    assert first.as_dict() | {"source": "fake"} == {
        "source": "fake",
        "discovered": 2,
        "new": 2,
        "updated": 0,
        "unchanged": 0,
        "unavailable": 0,
    }
    assert second.unchanged == 2
    assert third.updated == 1
    assert third.unchanged == 1
    assert len(state_store.list_openkb_staging()) == 2
    assert state_store.get_checkpoint("fake") == "2"


async def test_complete_snapshot_marks_missing_document_unavailable(tmp_path: Path) -> None:
    """完全snapshotから消えたdocumentが即時削除されないことを検証する。"""
    state_store = StateStore(tmp_path / "state.db")
    source_store = SourceStore(tmp_path / "source", state_store)
    connector = FakeConnector([FakeItem("1", "alpha"), FakeItem("2", "beta")])
    service = IngestionService({"fake": connector}, source_store, state_store)
    await service.ingest("fake")

    connector.items = [FakeItem("1", "alpha")]
    result = await service.ingest("fake")

    documents = {item["source_id"]: item for item in state_store.list_documents("fake")}
    assert result.unavailable == 1
    assert documents["fake:test:item:1"]["state"] == "active"
    assert documents["fake:test:item:2"]["state"] == "unavailable"
    unavailable_path = Path(documents["fake:test:item:2"]["normalized_path"])
    assert "Source unavailable" in unavailable_path.read_text(encoding="utf-8")
