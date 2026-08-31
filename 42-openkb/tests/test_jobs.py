"""job多重実行制御とrun履歴を検証する。"""

from __future__ import annotations

import asyncio
from pathlib import Path

from llm_wiki_platform.jobs import JobCoordinator
from llm_wiki_platform.state import StateStore


async def test_running_job_keeps_only_one_pending_run(tmp_path: Path) -> None:
    """実行中の同一jobへの複数submitがcatch-up 1回に畳まれることを検証する。"""
    state_store = StateStore(tmp_path / "state.db")
    coordinator = JobCoordinator(state_store)
    release = asyncio.Event()
    started = asyncio.Event()
    calls: list[str] = []

    async def runner(trigger: str) -> dict[str, int]:
        """最初のrunだけ待機するtest runner。

        Args:
            trigger: runの起動理由。

        Returns:
            現在の呼出回数。
        """
        calls.append(trigger)
        started.set()
        if len(calls) == 1:
            await release.wait()
        return {"calls": len(calls)}

    first = await coordinator.submit("compile", "schedule", runner)
    await started.wait()
    second = await coordinator.submit("compile", "manual", runner)
    third = await coordinator.submit("compile", "schedule", runner)
    release.set()
    await coordinator.wait_for_idle("compile")

    assert first.accepted is True
    assert second.pending is True
    assert third.pending is True
    assert calls == ["schedule", "schedule"]
    assert [run["status"] for run in state_store.list_runs()] == ["succeeded", "succeeded"]


async def test_failed_job_releases_slot(tmp_path: Path) -> None:
    """job失敗後も同じkeyを再実行できることを検証する。"""
    state_store = StateStore(tmp_path / "state.db")
    coordinator = JobCoordinator(state_store)

    async def failing_runner(trigger: str) -> dict[str, str]:
        """常に失敗するtest runner。

        Args:
            trigger: runの起動理由。

        Returns:
            到達しない結果。

        Raises:
            RuntimeError: 常に発生する。
        """
        raise RuntimeError(f"failed: {trigger}")

    first = await coordinator.submit("ingest:gitlab", "manual", failing_runner)
    await coordinator.wait_for_idle("ingest:gitlab")
    second = await coordinator.submit("ingest:gitlab", "manual", failing_runner)
    await coordinator.wait_for_idle("ingest:gitlab")

    assert first.accepted is True
    assert second.accepted is True
    assert [run["status"] for run in state_store.list_runs()] == ["failed", "failed"]
