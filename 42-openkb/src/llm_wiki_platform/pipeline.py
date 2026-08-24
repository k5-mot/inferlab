"""ingest、compile、publish jobを実行制御へ接続する。"""

from __future__ import annotations

from typing import Any

from llm_wiki_platform.config import AppConfig
from llm_wiki_platform.ingestion import IngestionService
from llm_wiki_platform.jobs import JobCoordinator, SubmissionResult
from llm_wiki_platform.openkb_client import OpenKBClient
from llm_wiki_platform.publisher import Publisher


class PipelineService:
    """3段階pipelineのmanual・schedule起動を統一する。"""

    def __init__(
        self,
        config: AppConfig,
        ingestion: IngestionService,
        coordinator: JobCoordinator,
        openkb: OpenKBClient | None,
        publishers: dict[str, Publisher],
    ) -> None:
        """PipelineServiceを初期化する。

        Args:
            config: pipeline起動条件を含む設定。
            ingestion: source ingest service。
            coordinator: 多重実行を防止するjob coordinator。
            openkb: compile有効時のOpenKB client。
            publishers: target名と有効なPublisherの対応。

        Returns:
            なし。
        """
        self._config = config
        self._ingestion = ingestion
        self._coordinator = coordinator
        self._openkb = openkb
        self._publishers = publishers

    async def submit_ingest(self, source_name: str, trigger: str) -> SubmissionResult:
        """source ingestをjob coordinatorへsubmitする。

        Args:
            source_name: Connector名。
            trigger: manualまたはschedule。

        Returns:
            即時開始またはpending化を示す受付結果。
        """

        async def runner(run_trigger: str) -> dict[str, Any]:
            """1回のsource ingestを実行する。

            Args:
                run_trigger: coordinatorが確定した起動理由。

            Returns:
                ingest集計と起動理由。
            """
            result = await self._ingestion.ingest(source_name)
            return result.as_dict() | {"trigger": run_trigger}

        return await self._coordinator.submit(f"ingest:{source_name}", trigger, runner)

    async def submit_compile(self, trigger: str) -> SubmissionResult:
        """OpenKB compileをjob coordinatorへsubmitする。

        Args:
            trigger: manualまたはschedule。

        Returns:
            即時開始またはpending化を示す受付結果。

        Raises:
            RuntimeError: compileが無効またはclient未構築の場合。
        """
        openkb = self._openkb
        if not self._config.pipeline.compile.enabled or openkb is None:
            raise RuntimeError("compileはconfig.yamlで無効です")

        async def runner(run_trigger: str) -> dict[str, Any]:
            """OpenKB compileと成功後publish submitを実行する。

            Args:
                run_trigger: coordinatorが確定した起動理由。

            Returns:
                OpenKB結果とpublish受付状態。
            """
            result = await openkb.compile()
            detail: dict[str, Any] = {"trigger": run_trigger, "openkb": result}
            publish_config = self._config.pipeline.publish
            if publish_config.enabled and publish_config.mode == "after_successful_compile":
                submission = await self.submit_publish("compile")
                detail["publish"] = {
                    "accepted": submission.accepted,
                    "pending": submission.pending,
                }
            return detail

        return await self._coordinator.submit("compile", trigger, runner)

    async def submit_publish(self, trigger: str) -> SubmissionResult:
        """設定済みtargetへのpublishをjob coordinatorへsubmitする。

        Args:
            trigger: manualまたはcompile。

        Returns:
            即時開始またはpending化を示す受付結果。

        Raises:
            RuntimeError: publishが無効またはpublisher未構築の場合。
        """
        publishers = self._publishers
        if not self._config.pipeline.publish.enabled or not publishers:
            raise RuntimeError("publishはconfig.yamlで無効です")

        async def runner(run_trigger: str) -> dict[str, Any]:
            """設定された全targetへpublishを1回実行する。

            Args:
                run_trigger: coordinatorが確定した起動理由。

            Returns:
                target別publish集計と起動理由。
            """
            results: dict[str, dict[str, int | bool]] = {}
            for target, publisher in publishers.items():
                results[target] = (await publisher.publish()).as_dict()
            return {"trigger": run_trigger, "targets": results}

        return await self._coordinator.submit("publish", trigger, runner)

    async def schedule_ingest(self, source_name: str) -> None:
        """APSchedulerからsource ingestを起動する。

        Args:
            source_name: Connector名。

        Returns:
            なし。
        """
        await self.submit_ingest(source_name, "schedule")

    async def schedule_compile(self) -> None:
        """APSchedulerからOpenKB compileを起動する。

        Returns:
            なし。
        """
        await self.submit_compile("schedule")
