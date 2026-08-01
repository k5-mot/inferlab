from __future__ import annotations

import asyncio
import os
import sqlite3
import threading
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable
from zoneinfo import ZoneInfo

import httpx
import yaml
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field
from prometheus_client import REGISTRY, generate_latest
from prometheus_client.core import CounterMetricFamily, GaugeMetricFamily

DB_PATH = Path(os.getenv("DB_PATH", "/data/usage.db"))
QUOTA_CONFIG_PATH = Path(os.getenv("QUOTA_CONFIG_PATH", "/config/quotas.yaml"))
POLL_INTERVAL_SECONDS = max(15, int(os.getenv("POLL_INTERVAL_SECONDS", "60")))
REQUEST_TIMEOUT_SECONDS = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "10"))
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "").strip()
OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://host.docker.internal:11434").rstrip("/")
INGEST_TOKEN = os.getenv("INGEST_TOKEN", "").strip()
CHATGPT_PRO_STATUS = os.getenv("CHATGPT_PRO_STATUS", "unknown").strip().lower()
CHATGPT_PRO_RESET_TIMESTAMP = float(os.getenv("CHATGPT_PRO_RESET_TIMESTAMP", "0") or 0)

DB_LOCK = threading.RLock()
SNAPSHOT_LOCK = threading.RLock()
SNAPSHOTS: dict[str, Any] = {
    "provider_up": {"openrouter": 0.0, "ollama": 0.0},
    "last_scrape": {},
    "openrouter": {},
    "ollama": {"installed_models": 0.0, "running_models": 0.0},
}


class IngestEvent(BaseModel):
    provider: str = Field(min_length=1, max_length=64)
    model: str = Field(default="unknown", max_length=256)
    input_tokens: int = Field(default=0, ge=0)
    output_tokens: int = Field(default=0, ge=0)
    requests: int = Field(default=1, ge=0)
    cost_usd: float = Field(default=0.0, ge=0.0)
    status: str = Field(default="success", max_length=32)
    timestamp: float | None = None


@dataclass(frozen=True)
class Quota:
    provider: str
    model: str
    dimension: str
    window: str
    limit: float
    reset_timezone: str = "UTC"
    rolling: bool = True
    source: str = "configured"


def db_connect() -> sqlite3.Connection:
    """SQLiteへ接続します。

    引数はありません。

    Returns:
        sqlite3.Connection: row_factoryを設定したSQLite接続。

    Side Effects:
        DB配置directoryが存在しない場合に作成します。
    """
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    """usage event保存用のSQLite schemaを初期化します。

    引数はありません。

    Returns:
        None: 戻り値はありません。

    Side Effects:
        SQLite DBにtableとindexを作成し、transactionをcommitします。
    """
    with DB_LOCK, db_connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS usage_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                requests INTEGER NOT NULL,
                cost_usd REAL NOT NULL,
                status TEXT NOT NULL
            )
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_events(ts)")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_usage_provider_model_ts "
            "ON usage_events(provider, model, ts)"
        )
        conn.commit()


def load_quotas() -> list[Quota]:
    """YAML設定からquota定義を読み込みます。

    引数はありません。

    Returns:
        list[Quota]: 読み込めたquota定義の一覧。

    Side Effects:
        不正なquota項目は例外にせず読み飛ばします。
    """
    if not QUOTA_CONFIG_PATH.exists():
        return []
    raw = yaml.safe_load(QUOTA_CONFIG_PATH.read_text(encoding="utf-8")) or {}
    quotas: list[Quota] = []
    for item in raw.get("quotas", []):
        try:
            quotas.append(
                Quota(
                    provider=str(item["provider"]).strip().lower(),
                    model=str(item.get("model", "*")).strip(),
                    dimension=str(item["dimension"]).strip().lower(),
                    window=str(item["window"]).strip().lower(),
                    limit=float(item["limit"]),
                    reset_timezone=str(item.get("reset_timezone", "UTC")),
                    rolling=bool(item.get("rolling", True)),
                    source=str(item.get("source", "configured")),
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    return quotas


def window_bounds(quota: Quota, now_ts: float) -> tuple[float, float]:
    """quota windowの開始時刻と次回reset時刻を計算します。

    Args:
        quota: 計算対象のquota定義。
        now_ts: 現在時刻のUnix timestamp。

    Returns:
        tuple[float, float]: window開始timestampとreset timestamp。rolling windowの場合resetは0。
    """
    now_utc = datetime.fromtimestamp(now_ts, timezone.utc)
    if quota.rolling:
        seconds = {
            "minute": 60,
            "hour": 3600,
            "day": 86400,
            "week": 7 * 86400,
            "month": 30 * 86400,
            "session_5h": 5 * 3600,
            "week_7d": 7 * 86400,
        }.get(quota.window, 86400)
        return now_ts - seconds, 0.0

    try:
        tz = ZoneInfo(quota.reset_timezone)
    except Exception:
        tz = timezone.utc
    local = now_utc.astimezone(tz)

    if quota.window == "minute":
        start = local.replace(second=0, microsecond=0)
        end = start + timedelta(minutes=1)
    elif quota.window == "hour":
        start = local.replace(minute=0, second=0, microsecond=0)
        end = start + timedelta(hours=1)
    elif quota.window == "week":
        start = (local - timedelta(days=local.weekday())).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        end = start + timedelta(days=7)
    elif quota.window == "month":
        start = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        if start.month == 12:
            end = start.replace(year=start.year + 1, month=1)
        else:
            end = start.replace(month=start.month + 1)
    else:
        start = local.replace(hour=0, minute=0, second=0, microsecond=0)
        end = start + timedelta(days=1)
    return start.timestamp(), end.timestamp()


def query_usage(provider: str, model: str, since_ts: float) -> dict[str, float]:
    """指定window内の利用量を集計します。

    Args:
        provider: 集計対象provider名。
        model: 集計対象model名。`*`の場合はprovider全体。
        since_ts: 集計開始Unix timestamp。

    Returns:
        dict[str, float]: input_tokens、output_tokens、requests、cost_usdの集計値。

    Side Effects:
        SQLite DBを読み取ります。
    """
    model_clause = "" if model == "*" else " AND model = ?"
    params: list[Any] = [provider, since_ts]
    if model != "*":
        params.append(model)
    sql = f"""
        SELECT
            COALESCE(SUM(input_tokens), 0) AS input_tokens,
            COALESCE(SUM(output_tokens), 0) AS output_tokens,
            COALESCE(SUM(requests), 0) AS requests,
            COALESCE(SUM(cost_usd), 0) AS cost_usd
        FROM usage_events
        WHERE provider = ? AND ts >= ? {model_clause}
    """
    with DB_LOCK, db_connect() as conn:
        row = conn.execute(sql, params).fetchone()
    return {key: float(row[key]) for key in row.keys()}


def aggregate_totals() -> Iterable[sqlite3.Row]:
    """保存済みusage eventをprovider/model/status単位で集計します。

    引数はありません。

    Returns:
        Iterable[sqlite3.Row]: Prometheus counter生成に使う集計行。

    Side Effects:
        SQLite DBを読み取ります。
    """
    with DB_LOCK, db_connect() as conn:
        return conn.execute(
            """
            SELECT provider, model, status,
                   SUM(input_tokens) AS input_tokens,
                   SUM(output_tokens) AS output_tokens,
                   SUM(requests) AS requests,
                   SUM(cost_usd) AS cost_usd
            FROM usage_events
            GROUP BY provider, model, status
            """
        ).fetchall()


class LLMCollector:
    def collect(self):
        """Prometheus exposition用のmetric familyを生成します。

        引数はありません。

        Returns:
            Iterable[Any]: prometheus_clientが収集するmetric family。

        Side Effects:
            SQLite DB、quota YAML、polling snapshotを読み取ります。
        """
        now_ts = time.time()

        provider_up = GaugeMetricFamily(
            "llm_provider_up", "Provider polling status", labels=["provider"]
        )
        last_scrape = GaugeMetricFamily(
            "llm_provider_last_scrape_timestamp_seconds",
            "Unix timestamp of the last provider poll",
            labels=["provider"],
        )
        with SNAPSHOT_LOCK:
            snapshot = {
                "provider_up": dict(SNAPSHOTS["provider_up"]),
                "last_scrape": dict(SNAPSHOTS["last_scrape"]),
                "openrouter": dict(SNAPSHOTS["openrouter"]),
                "ollama": dict(SNAPSHOTS["ollama"]),
            }
        for provider, value in snapshot["provider_up"].items():
            provider_up.add_metric([provider], value)
        for provider, value in snapshot["last_scrape"].items():
            last_scrape.add_metric([provider], value)
        yield provider_up
        yield last_scrape

        token_total = CounterMetricFamily(
            "llm_usage_tokens",
            "Metered tokens received through POST /ingest",
            labels=["provider", "model", "type"],
        )
        request_total = CounterMetricFamily(
            "llm_usage_requests",
            "Metered requests received through POST /ingest",
            labels=["provider", "model", "status"],
        )
        cost_total = CounterMetricFamily(
            "llm_usage_cost_usd",
            "Metered cost in USD received through POST /ingest",
            labels=["provider", "model"],
        )
        costs: dict[tuple[str, str], float] = {}
        for row in aggregate_totals():
            provider, model, status = row["provider"], row["model"], row["status"]
            token_total.add_metric([provider, model, "input"], float(row["input_tokens"]))
            token_total.add_metric([provider, model, "output"], float(row["output_tokens"]))
            request_total.add_metric([provider, model, status], float(row["requests"]))
            costs[(provider, model)] = costs.get((provider, model), 0.0) + float(row["cost_usd"])
        for (provider, model), value in costs.items():
            cost_total.add_metric([provider, model], value)
        yield token_total
        yield request_total
        yield cost_total

        quota_limit = GaugeMetricFamily(
            "llm_quota_limit",
            "Configured or API-reported quota limit",
            labels=["provider", "model", "dimension", "window", "source"],
        )
        quota_used = GaugeMetricFamily(
            "llm_quota_used",
            "Usage in the current quota window",
            labels=["provider", "model", "dimension", "window", "source"],
        )
        quota_remaining = GaugeMetricFamily(
            "llm_quota_remaining",
            "Remaining quota; estimates are labelled by source",
            labels=["provider", "model", "dimension", "window", "source"],
        )
        quota_reset = GaugeMetricFamily(
            "llm_quota_reset_timestamp_seconds",
            "Next fixed reset timestamp; zero for rolling windows",
            labels=["provider", "model", "dimension", "window", "source"],
        )

        for quota in load_quotas():
            start_ts, reset_ts = window_bounds(quota, now_ts)
            usage = query_usage(quota.provider, quota.model, start_ts)
            if quota.dimension == "tokens":
                used = usage["input_tokens"] + usage["output_tokens"]
            else:
                used = usage.get(quota.dimension, 0.0)
            labels = [
                quota.provider,
                quota.model,
                quota.dimension,
                quota.window,
                quota.source,
            ]
            quota_limit.add_metric(labels, quota.limit)
            quota_used.add_metric(labels, used)
            quota_remaining.add_metric(labels, max(quota.limit - used, 0.0))
            quota_reset.add_metric(labels, reset_ts)

        # OpenRouterのkey endpointはcredit capの信頼できるmetricを返す。
        or_data = snapshot["openrouter"]
        if or_data:
            label = or_data.get("label", "api-key")
            limit = or_data.get("limit")
            remaining = or_data.get("limit_remaining")
            if limit is not None:
                labels = ["openrouter", label, "cost_usd", str(or_data.get("limit_reset") or "none"), "api"]
                quota_limit.add_metric(labels, float(limit))
                quota_used.add_metric(labels, max(float(limit) - float(remaining or 0), 0.0))
                quota_remaining.add_metric(labels, float(remaining or 0))
                quota_reset.add_metric(labels, 0.0)

        yield quota_limit
        yield quota_used
        yield quota_remaining
        yield quota_reset

        openrouter_usage = GaugeMetricFamily(
            "openrouter_usage_usd",
            "OpenRouter usage values from GET /api/v1/key",
            labels=["window", "kind"],
        )
        for window in ("all", "daily", "weekly", "monthly"):
            suffix = "" if window == "all" else f"_{window}"
            for kind, prefix in (("openrouter", "usage"), ("byok", "byok_usage")):
                key = f"{prefix}{suffix}"
                if key in or_data:
                    openrouter_usage.add_metric([window, kind], float(or_data[key]))
        yield openrouter_usage

        openrouter_free = GaugeMetricFamily(
            "openrouter_is_free_tier", "Whether OpenRouter reports free-tier status"
        )
        openrouter_free.add_metric([], 1.0 if or_data.get("is_free_tier") else 0.0)
        yield openrouter_free

        ollama_models = GaugeMetricFamily(
            "ollama_models", "Ollama model counts", labels=["state"]
        )
        ollama_models.add_metric(["installed"], float(snapshot["ollama"].get("installed_models", 0)))
        ollama_models.add_metric(["running"], float(snapshot["ollama"].get("running_models", 0)))
        yield ollama_models

        chatgpt_status = GaugeMetricFamily(
            "chatgpt_pro_status",
            "Manual ChatGPT Pro status: unknown=0, available=1, limited=2, exhausted=3",
            labels=["status", "source"],
        )
        valid = {"unknown", "available", "limited", "exhausted"}
        status = CHATGPT_PRO_STATUS if CHATGPT_PRO_STATUS in valid else "unknown"
        chatgpt_status.add_metric([status, "manual"], {"unknown": 0, "available": 1, "limited": 2, "exhausted": 3}[status])
        yield chatgpt_status

        chatgpt_reset = GaugeMetricFamily(
            "chatgpt_pro_reset_timestamp_seconds",
            "Manual reset timestamp copied from the ChatGPT UI",
            labels=["source"],
        )
        chatgpt_reset.add_metric(["manual"], CHATGPT_PRO_RESET_TIMESTAMP)
        yield chatgpt_reset


init_db()
REGISTRY.register(LLMCollector())


async def poll_openrouter(client: httpx.AsyncClient) -> None:
    """OpenRouter key APIからcredit利用状況を取得します。

    Args:
        client: 共有HTTP client。

    Returns:
        None: 戻り値はありません。

    Side Effects:
        OpenRouter APIへHTTP requestを送り、snapshotを更新します。
    """
    if not OPENROUTER_API_KEY:
        return
    now = time.time()
    try:
        response = await client.get(
            "https://openrouter.ai/api/v1/key",
            headers={"Authorization": f"Bearer {OPENROUTER_API_KEY}"},
        )
        response.raise_for_status()
        data = response.json().get("data", {})
        with SNAPSHOT_LOCK:
            SNAPSHOTS["openrouter"] = data
            SNAPSHOTS["provider_up"]["openrouter"] = 1.0
            SNAPSHOTS["last_scrape"]["openrouter"] = now
    except Exception:
        with SNAPSHOT_LOCK:
            SNAPSHOTS["provider_up"]["openrouter"] = 0.0
            SNAPSHOTS["last_scrape"]["openrouter"] = now


async def poll_ollama(client: httpx.AsyncClient) -> None:
    """Ollama APIからmodel状態を取得します。

    Args:
        client: 共有HTTP client。

    Returns:
        None: 戻り値はありません。

    Side Effects:
        Ollama APIへHTTP requestを送り、snapshotを更新します。
    """
    now = time.time()
    try:
        tags, ps = await asyncio.gather(
            client.get(f"{OLLAMA_BASE_URL}/api/tags"),
            client.get(f"{OLLAMA_BASE_URL}/api/ps"),
        )
        tags.raise_for_status()
        ps.raise_for_status()
        installed = len(tags.json().get("models", []))
        running = len(ps.json().get("models", []))
        with SNAPSHOT_LOCK:
            SNAPSHOTS["ollama"] = {
                "installed_models": float(installed),
                "running_models": float(running),
            }
            SNAPSHOTS["provider_up"]["ollama"] = 1.0
            SNAPSHOTS["last_scrape"]["ollama"] = now
    except Exception:
        with SNAPSHOT_LOCK:
            SNAPSHOTS["provider_up"]["ollama"] = 0.0
            SNAPSHOTS["last_scrape"]["ollama"] = now


async def poll_loop() -> None:
    """provider pollingを定期実行します。

    引数はありません。

    Returns:
        None: 通常は返らず、task cancel時に終了します。

    Side Effects:
        provider APIへ定期的にHTTP requestを送ります。
    """
    timeout = httpx.Timeout(REQUEST_TIMEOUT_SECONDS)
    async with httpx.AsyncClient(timeout=timeout) as client:
        while True:
            await asyncio.gather(
                poll_openrouter(client),
                poll_ollama(client),
                return_exceptions=True,
            )
            await asyncio.sleep(POLL_INTERVAL_SECONDS)


@asynccontextmanager
async def lifespan(_: FastAPI):
    """FastAPI application lifecycleでpolling taskを管理します。

    Args:
        _: FastAPI application instance。処理では使用しません。

    Returns:
        AsyncIterator[None]: FastAPI lifespanへ制御を返す非同期iterator。

    Side Effects:
        DB初期化とpolling taskの作成・cancelを行います。
    """
    init_db()
    task = asyncio.create_task(poll_loop())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


app = FastAPI(title="LLM Quota Exporter", lifespan=lifespan)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """healthcheck endpointの状態を返します。

    引数はありません。

    Returns:
        dict[str, str]: service状態。
    """
    return {"status": "ok"}


@app.get("/metrics", response_class=PlainTextResponse)
def metrics() -> PlainTextResponse:
    """Prometheus metricsを返します。

    引数はありません。

    Returns:
        PlainTextResponse: Prometheus text exposition formatのresponse。
    """
    return PlainTextResponse(generate_latest(REGISTRY), media_type="text/plain; version=0.0.4")


@app.post("/ingest")
def ingest(event: IngestEvent, authorization: str | None = Header(default=None)) -> dict[str, Any]:
    """LLM利用eventを受け取りSQLiteへ保存します。

    Args:
        event: provider、model、token数、request数、costを含む利用event。
        authorization: optionalなBearer token header。

    Returns:
        dict[str, Any]: 保存したeventのprovider、model、timestamp。

    Raises:
        HTTPException: INGEST_TOKEN設定時にBearer tokenが一致しない場合。

    Side Effects:
        SQLite DBへusage eventをinsertします。
    """
    if INGEST_TOKEN:
        expected = f"Bearer {INGEST_TOKEN}"
        if authorization != expected:
            raise HTTPException(status_code=401, detail="invalid ingest token")

    ts = event.timestamp if event.timestamp is not None else time.time()
    provider = event.provider.strip().lower()
    model = event.model.strip() or "unknown"
    status = event.status.strip().lower() or "success"
    with DB_LOCK, db_connect() as conn:
        conn.execute(
            """
            INSERT INTO usage_events
            (ts, provider, model, input_tokens, output_tokens, requests, cost_usd, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                ts,
                provider,
                model,
                event.input_tokens,
                event.output_tokens,
                event.requests,
                event.cost_usd,
                status,
            ),
        )
        conn.commit()
    return {"accepted": True, "provider": provider, "model": model, "timestamp": ts}
