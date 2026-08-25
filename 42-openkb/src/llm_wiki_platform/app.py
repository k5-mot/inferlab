"""FastAPI管理APIとschedulerを構築するapplication factory。"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator, Mapping
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import httpx
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from fastapi import FastAPI, HTTPException, Query, status
from fastapi.responses import FileResponse

from llm_wiki_platform.config import AppConfig, load_config, resolve_credential
from llm_wiki_platform.connector_factory import ConnectorRegistry, build_connector_registry
from llm_wiki_platform.connectors.base import RetryingHttpClient
from llm_wiki_platform.ingestion import IngestionService
from llm_wiki_platform.jobs import JobCoordinator, SubmissionResult
from llm_wiki_platform.openkb_client import OpenKBClient
from llm_wiki_platform.pipeline import PipelineService
from llm_wiki_platform.publisher import Publisher
from llm_wiki_platform.source_store import SourceStore, serialize_document_state
from llm_wiki_platform.state import StateStore, decode_run_detail
from llm_wiki_platform.wikijs_publisher import WikiJSPublisher

_DASHBOARD_PATH = Path(__file__).parent / "static" / "dashboard.html"


@dataclass(slots=True)
class ApplicationContext:
    """FastAPI process内で共有するserviceとresource。"""

    config: AppConfig
    state_store: StateStore
    connector_registry: ConnectorRegistry
    coordinator: JobCoordinator
    pipeline: PipelineService
    scheduler: AsyncIOScheduler
    owned_clients: list[httpx.AsyncClient]

    async def aclose(self) -> None:
        """schedulerとHTTP resourceを終了する。

        Returns:
            なし。
        """
        if self.scheduler.running:
            self.scheduler.shutdown(wait=False)
        await self.connector_registry.aclose()
        for client in self.owned_clients:
            await client.aclose()


def create_app(
    config_path: Path,
    environ: Mapping[str, str] | None = None,
) -> FastAPI:
    """config.yamlをfail-fastで読みFastAPI applicationを構築する。

    Args:
        config_path: 起動時に一度だけ読み込むconfig.yaml。
        environ: credential参照を解決する環境変数。省略時はprocess環境。

    Returns:
        schedulerと管理routeを持つFastAPI application。

    Raises:
        ConfigLoadError: configまたはcredential参照が不正な場合。
    """
    environment = os.environ if environ is None else environ
    config = load_config(config_path, environment)
    context = _build_context(config, environment)

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        """schedulerを開始し終了時にresourceを解放する。

        Args:
            application: lifecycle対象FastAPI application。

        Yields:
            application稼働期間の制御。
        """
        del application
        context.scheduler.start()
        try:
            yield
        finally:
            await context.aclose()

    application = FastAPI(title="LLM Wiki Platform", version="0.1.0", lifespan=lifespan)
    application.state.context = context
    _register_routes(application, context)
    return application


def _build_context(config: AppConfig, environ: Mapping[str, str]) -> ApplicationContext:
    """設定からapplication serviceと外部HTTP clientを構築する。

    Args:
        config: 検証済み設定。
        environ: credential値を保持する環境変数。

    Returns:
        resource所有関係をまとめたApplicationContext。
    """
    state_store = StateStore(config.storage.state_database_path)
    source_store = SourceStore(config.storage.source_store_path, state_store)
    registry = build_connector_registry(config, environ)
    ingestion = IngestionService(registry.connectors, source_store, state_store)
    coordinator = JobCoordinator(state_store)
    owned_clients: list[httpx.AsyncClient] = []

    openkb: OpenKBClient | None = None
    if config.pipeline.compile.enabled:
        headers: dict[str, str] = {}
        token_env = config.openkb.credential.token_env
        if token_env:
            headers["Authorization"] = f"Bearer {environ[token_env]}"
        client = httpx.AsyncClient(
            base_url=str(config.openkb.base_url), headers=headers, timeout=600
        )
        owned_clients.append(client)
        retrying = RetryingHttpClient(
            client, config.defaults.ingest.retry, config.defaults.ingest.rate_limit
        )
        openkb = OpenKBClient(config, state_store, retrying, environ)

    publishers: dict[str, Publisher] = {}
    if config.pipeline.publish.enabled and "wikijs" in config.pipeline.publish.targets:
        credential = resolve_credential(config.wikijs.publisher_credential, environ)
        client = httpx.AsyncClient(
            base_url=str(config.wikijs.base_url),
            headers={"Authorization": f"Bearer {credential['token']}"},
            timeout=60,
        )
        owned_clients.append(client)
        retrying = RetryingHttpClient(
            client, config.defaults.ingest.retry, config.defaults.ingest.rate_limit
        )
        publishers["wikijs"] = WikiJSPublisher(
            config.wikijs,
            config.pipeline.publish,
            config.openkb.generated_wiki_path,
            state_store,
            retrying,
        )

    pipeline = PipelineService(config, ingestion, coordinator, openkb, publishers)
    scheduler = _build_scheduler(config, pipeline)
    return ApplicationContext(
        config=config,
        state_store=state_store,
        connector_registry=registry,
        coordinator=coordinator,
        pipeline=pipeline,
        scheduler=scheduler,
        owned_clients=owned_clients,
    )


def _build_scheduler(config: AppConfig, pipeline: PipelineService) -> AsyncIOScheduler:
    """config.yamlのcron式からAPScheduler jobを構築する。

    Args:
        config: scheduleとtimezoneを含む設定。
        pipeline: schedule callbackのsubmit先。

    Returns:
        未開始のAsyncIOScheduler。
    """
    timezone = ZoneInfo(config.scheduler.timezone)
    scheduler = AsyncIOScheduler(timezone=timezone)
    for source_name in config.enabled_source_names():
        schedule = config.effective_ingest(source_name).schedule
        scheduler.add_job(
            pipeline.schedule_ingest,
            CronTrigger.from_crontab(schedule, timezone=timezone),
            args=[source_name],
            id=f"ingest:{source_name}",
            max_instances=1,
            coalesce=True,
            replace_existing=True,
        )
    if config.pipeline.compile.enabled:
        scheduler.add_job(
            pipeline.schedule_compile,
            CronTrigger.from_crontab(config.pipeline.compile.schedule, timezone=timezone),
            id="compile",
            max_instances=1,
            coalesce=True,
            replace_existing=True,
        )
    return scheduler


def _register_routes(application: FastAPI, context: ApplicationContext) -> None:
    """管理API routeをFastAPI applicationへ登録する。

    Args:
        application: route登録先。
        context: routeが操作するapplication service。

    Returns:
        なし。
    """

    @application.get("/health")
    async def health() -> dict[str, Any]:
        """processとjob coordinatorの状態を返す。

        Returns:
            health statusとjob snapshot。
        """
        return {"status": "ok", "jobs": await context.coordinator.snapshot()}

    @application.get("/dashboard", response_class=FileResponse)
    async def dashboard() -> FileResponse:
        """同期状態の表示とmanual triggerを提供するdashboardを返す。

        Returns:
            package内のdashboard HTML response。
        """
        return FileResponse(_DASHBOARD_PATH)

    @application.get("/sources")
    async def sources() -> list[dict[str, Any]]:
        """設定済みsourceとcheckpoint、document件数を返す。

        Returns:
            sourceごとの運用状態。
        """
        document_counts: dict[str, int] = {}
        for document in context.state_store.list_documents():
            source_name = str(document["source"])
            document_counts[source_name] = document_counts.get(source_name, 0) + 1
        names = [*context.config.sources, "wikijs"]
        enabled = set(context.config.enabled_source_names())
        return [
            {
                "name": name,
                "enabled": name in enabled,
                "checkpoint": context.state_store.get_checkpoint(name),
                "documents": document_counts.get(name, 0),
            }
            for name in names
        ]

    @application.get("/connectors")
    async def connectors() -> dict[str, list[str]]:
        """起動時に構築されたConnector名を返す。

        Returns:
            enabled Connector一覧。
        """
        return {"enabled": list(context.connector_registry.connectors)}

    @application.get("/documents")
    async def documents(source: str | None = None) -> list[dict[str, Any]]:
        """Source Storeのdocument状態を返す。

        Args:
            source: 任意のsource絞り込み。

        Returns:
            document状態一覧。
        """
        return [
            serialize_document_state(item) for item in context.state_store.list_documents(source)
        ]

    @application.get("/runs")
    async def runs(limit: int = Query(default=100, ge=1, le=1000)) -> list[dict[str, Any]]:
        """新しい順にpipeline run履歴を返す。

        Args:
            limit: 最大取得件数。

        Returns:
            detailをdecodeしたrun一覧。
        """
        return [decode_run_detail(run) for run in context.state_store.list_runs(limit)]

    @application.post("/ingest/{connector}", status_code=status.HTTP_202_ACCEPTED)
    async def ingest(connector: str) -> dict[str, Any]:
        """指定Connectorのmanual ingestをsubmitする。

        Args:
            connector: enabled Connector名。

        Returns:
            acceptedまたはpending状態。

        Raises:
            HTTPException: Connectorが無効または未設定の場合。
        """
        if connector not in context.connector_registry.connectors:
            raise HTTPException(status_code=404, detail="Connectorは無効または未設定です")
        submission = await context.pipeline.submit_ingest(connector, "manual")
        return _submission_response(submission)

    @application.post("/compile", status_code=status.HTTP_202_ACCEPTED)
    async def compile_wiki() -> dict[str, Any]:
        """manual OpenKB compileをsubmitする。

        Returns:
            acceptedまたはpending状態。

        Raises:
            HTTPException: compileがconfigで無効な場合。
        """
        try:
            submission = await context.pipeline.submit_compile("manual")
        except RuntimeError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        return _submission_response(submission)

    @application.post("/publish", status_code=status.HTTP_202_ACCEPTED)
    async def publish_wiki() -> dict[str, Any]:
        """設定済みtargetへのmanual publishをsubmitする。

        Returns:
            acceptedまたはpending状態。

        Raises:
            HTTPException: publishがconfigで無効な場合。
        """
        try:
            submission = await context.pipeline.submit_publish("manual")
        except RuntimeError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        return _submission_response(submission)


def _submission_response(submission: SubmissionResult) -> dict[str, Any]:
    """JobCoordinatorの受付結果をAPI responseへ変換する。

    Args:
        submission: coordinatorの受付結果。

    Returns:
        job key、accepted、pendingを含むdict。
    """
    return {
        "job_key": submission.job_key,
        "accepted": submission.accepted,
        "pending": submission.pending,
    }
