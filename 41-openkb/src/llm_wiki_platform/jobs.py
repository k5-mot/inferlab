"""同一jobの多重実行を防ぎpendingを1件に制限する実行制御。"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

from llm_wiki_platform.state import StateStore

LOGGER = logging.getLogger(__name__)
JobRunner = Callable[[str], Awaitable[dict[str, Any]]]


@dataclass(slots=True)
class JobSlot:
    """job key単位のrunningとpending状態。"""

    running: bool = False
    pending: bool = False
    pending_trigger: str | None = None
    runner: JobRunner | None = None


@dataclass(frozen=True, slots=True)
class SubmissionResult:
    """job submit時点の受付結果。"""

    job_key: str
    accepted: bool
    pending: bool


class JobCoordinator:
    """job keyごとに実行を直列化しcatch-upを管理する。"""

    def __init__(self, state_store: StateStore) -> None:
        """JobCoordinatorを初期化する。

        Args:
            state_store: run履歴の保存先。

        Returns:
            なし。
        """
        self._state_store = state_store
        self._guard = asyncio.Lock()
        self._slots: dict[str, JobSlot] = {}
        self._tasks: dict[str, asyncio.Task[None]] = {}

    async def submit(self, job_key: str, trigger: str, runner: JobRunner) -> SubmissionResult:
        """jobを開始するかpending 1件として記録する。

        Args:
            job_key: 多重実行を制御するkey。
            trigger: scheduleまたはmanualなどの起動理由。
            runner: 実際のjob処理。

        Returns:
            即時開始またはpending化を示す受付結果。
        """
        async with self._guard:
            slot = self._slots.setdefault(job_key, JobSlot())
            if slot.running:
                slot.pending = True
                slot.pending_trigger = trigger
                slot.runner = runner
                return SubmissionResult(job_key=job_key, accepted=False, pending=True)
            slot.running = True
            slot.runner = runner
            task = asyncio.create_task(self._drain(job_key, trigger), name=f"job:{job_key}")
            self._tasks[job_key] = task
            return SubmissionResult(job_key=job_key, accepted=True, pending=False)

    async def _drain(self, job_key: str, initial_trigger: str) -> None:
        """先行runとpending catch-upを順番に実行する。

        Args:
            job_key: 実行対象job key。
            initial_trigger: 最初のrunの起動理由。

        Returns:
            なし。

        Side Effects:
            run履歴を更新し、pendingがあれば追加runを開始する。
        """
        trigger = initial_trigger
        while True:
            async with self._guard:
                runner = self._slots[job_key].runner
            if runner is None:
                raise RuntimeError(f"runnerが登録されていません: {job_key}")
            run_id = self._state_store.start_run(job_key, trigger)
            status = "succeeded"
            try:
                detail = await runner(trigger)
            except Exception as error:
                status = "failed"
                detail = {"error": str(error), "error_type": type(error).__name__}
                LOGGER.exception("jobが失敗しました: job_key=%s run_id=%s", job_key, run_id)
            self._state_store.finish_run(run_id, status, detail)
            async with self._guard:
                slot = self._slots[job_key]
                if slot.pending:
                    trigger = slot.pending_trigger or "catch_up"
                    slot.pending = False
                    slot.pending_trigger = None
                    continue
                slot.running = False
                slot.runner = None
                self._tasks.pop(job_key, None)
                return

    async def wait_for_idle(self, job_key: str) -> None:
        """指定jobがpendingを含めて完了するまで待つ。

        Args:
            job_key: 待機対象job key。

        Returns:
            なし。
        """
        while True:
            async with self._guard:
                task = self._tasks.get(job_key)
            if task is None:
                return
            await asyncio.shield(task)

    async def snapshot(self) -> dict[str, dict[str, bool]]:
        """現在のjob実行状態を取得する。

        Returns:
            job keyごとのrunningとpending状態。
        """
        async with self._guard:
            return {
                key: {"running": slot.running, "pending": slot.pending}
                for key, slot in self._slots.items()
            }
