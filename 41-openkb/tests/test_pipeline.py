"""pipelineの公開結果記録を検証する。"""

from __future__ import annotations

from pathlib import Path

import yaml

from llm_wiki_platform.config import AppConfig
from llm_wiki_platform.ingestion import IngestResult
from llm_wiki_platform.jobs import JobCoordinator
from llm_wiki_platform.pipeline import PipelineService
from llm_wiki_platform.publisher import PublishResult
from llm_wiki_platform.state import StateStore, decode_run_detail


class _UnusedIngestion:
    """公開testでは呼ばれない取り込みservice。"""

    async def ingest(self, source_name: str) -> IngestResult:
        """誤って取り込みが呼ばれた場合にtestを失敗させる。

        Args:
            source_name: 取り込み対象名。

        Returns:
            到達しない取り込み結果。

        Raises:
            AssertionError: 常に発生する。
        """
        raise AssertionError(f"unexpected ingest: {source_name}")


class _FakePublisher:
    """固定結果を返す公開先。"""

    def __init__(self, created: int) -> None:
        """Fake Publisherを初期化する。

        Args:
            created: 公開結果へ設定する作成件数。

        Returns:
            なし。
        """
        self._created = created

    async def publish(self) -> PublishResult:
        """固定した公開集計を返す。

        Returns:
            test用PublishResult。
        """
        return PublishResult(
            generated=self._created,
            created=self._created,
            updated=0,
            unchanged=0,
            unavailable=0,
            dry_run=False,
        )


def _config() -> AppConfig:
    """Wiki.jsへの公開を有効にした設定を作成する。

    Returns:
        schema検証済みAppConfig。
    """
    source_path = Path(__file__).parents[1] / "config.yaml"
    loaded = yaml.safe_load(source_path.read_text(encoding="utf-8"))
    assert isinstance(loaded, dict)
    loaded["pipeline"]["publish"]["enabled"] = True
    loaded["pipeline"]["publish"]["targets"] = ["wikijs"]
    return AppConfig.model_validate(loaded)


async def test_publish_records_result_for_each_target(tmp_path: Path) -> None:
    """1回の公開jobが設定順に全targetの結果を記録することを検証する。"""
    state_store = StateStore(tmp_path / "state.db")
    coordinator = JobCoordinator(state_store)
    pipeline = PipelineService(
        _config(),
        _UnusedIngestion(),
        coordinator,
        None,
        {
            "wikijs": _FakePublisher(2),
        },
    )

    submission = await pipeline.submit_publish("manual")
    await coordinator.wait_for_idle("publish")
    run = decode_run_detail(state_store.list_runs()[0])

    assert submission.accepted is True
    assert run["status"] == "succeeded"
    assert run["detail"]["targets"]["wikijs"]["created"] == 2
