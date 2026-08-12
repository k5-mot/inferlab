from __future__ import annotations

import copy
import datetime as dt
import json
import threading
import urllib.error
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from connectors import create_connector
from connectors.base import MissingCredentialError, SyncError, to_bool, to_int
from http_client import HttpClient
from llmwiki_client import LlmWikiClient
from state_store import read_json, read_state, write_json


class SyncWorker:
    """設定駆動で複数sourceをLLMwikiへ同期するworker。"""

    def __init__(self, config: dict[str, Any]) -> None:
        """workerを初期化する。

        Args:
            config: 展開済み設定dict。

        Returns:
            None。
        """

        self.config = config
        self.worker_config = config.get("worker", {})
        self.checkpoint_path = Path(str(self.worker_config.get("checkpoint_path", "/state/checkpoint.json")))
        self.health_path = Path(str(self.worker_config.get("health_path", "/state/health.json")))
        self.status_path = Path(str(self.worker_config.get("status_path", "/state/status.json")))
        self.http_client = HttpClient(to_int(self.worker_config.get("http_timeout_seconds", 30), 30))
        wiki_config = config.get("llm_wiki", {})
        self.llmwiki = LlmWikiClient(str(wiki_config["mcp_url"]), str(wiki_config["wiki"]), self.http_client)
        self.sync_lock = threading.Lock()
        self.check_lock = threading.Lock()
        self.last_manual_trigger: dict[str, Any] | None = None

    def run_once(self, trigger: str = "scheduled") -> dict[str, Any]:
        """全enabled sourceを1回同期する。

        Args:
            trigger: 実行理由。scheduledまたはmanual。

        Returns:
            health fileへ保存する実行結果。

        Side Effects:
            llm-wiki page、checkpoint、health JSONを更新する。
        """

        acquired = self.sync_lock.acquire(blocking=False)
        if not acquired:
            return self._busy_health(trigger)
        try:
            return self._run_once_locked(trigger)
        finally:
            self.sync_lock.release()

    def trigger_manual(self) -> dict[str, Any]:
        """手動同期をbackground threadで開始する。

        Args:
            None。

        Returns:
            trigger受付状態。

        Side Effects:
            同期threadを開始する可能性がある。
        """

        if self.sync_lock.locked():
            return {"accepted": False, "status": "busy"}
        thread = threading.Thread(target=self.run_once, kwargs={"trigger": "manual"}, daemon=True)
        thread.start()
        self.last_manual_trigger = {"accepted": True, "status": "started", "started_at": utc_now()}
        return self.last_manual_trigger

    def check_sources(self) -> dict[str, Any]:
        """enabled sourceの接続状態を確認する。

        Args:
            None。

        Returns:
            source別接続状態。

        Side Effects:
            status JSONを更新する。
        """

        acquired = self.check_lock.acquire(blocking=False)
        if not acquired:
            return {"status": "busy", "checked_at": utc_now(), "sources": []}
        try:
            results: list[dict[str, Any]] = []
            for source_config in self.config.get("sources", []):
                source_name = str(source_config.get("name", "unnamed"))
                if not to_bool(source_config.get("enabled", False)):
                    results.append({"source": source_name, "status": "disabled"})
                    continue
                try:
                    connector = create_connector(source_config, self.http_client)
                    results.append(connector.check_status())
                except MissingCredentialError as exc:
                    results.append({"source": source_name, "status": "credential_error", "error": str(exc)})
                except (SyncError, urllib.error.URLError, ET.ParseError, json.JSONDecodeError) as exc:
                    results.append({"source": source_name, "status": "error", "error": str(exc)})
            status = {"status": "degraded" if any(item.get("status") not in {"ok", "disabled"} for item in results) else "ok", "checked_at": utc_now(), "sources": results}
            write_json(self.status_path, status)
            return status
        finally:
            self.check_lock.release()

    def status(self) -> dict[str, Any]:
        """WebUIとAPIへ返す現在状態を作る。

        Args:
            None。

        Returns:
            worker状態、last health、last source checkを含むdict。
        """

        return {
            "status": "running",
            "sync_busy": self.sync_lock.locked(),
            "check_busy": self.check_lock.locked(),
            "manual_trigger": self.last_manual_trigger,
            "health": read_json(self.health_path, {}),
            "source_check": read_json(self.status_path, {}),
            "sources": self._source_summaries(),
        }

    def interval_seconds(self) -> int:
        """同期loopのinterval秒を返す。

        Args:
            None。

        Returns:
            interval秒。
        """

        return to_int(self.worker_config.get("interval_seconds", 3600), 3600)

    def _run_once_locked(self, trigger: str) -> dict[str, Any]:
        """lock取得済み状態で同期を実行する。

        Args:
            trigger: 実行理由。

        Returns:
            health dict。

        Side Effects:
            checkpoint、health JSON、LLMwikiを更新する。
        """

        state = read_state(self.checkpoint_path)
        started_at = utc_now()
        source_results: list[dict[str, Any]] = []
        any_error = False
        any_updates = False
        for source_config in self.config.get("sources", []):
            result, updated = self._sync_source(source_config, state)
            any_error = any_error or result.get("status") not in {"ok", "disabled"}
            any_updates = any_updates or updated
            source_results.append(result)
        if any_updates:
            self.llmwiki.rebuild_index()
        health = {"status": "degraded" if any_error else "ok", "trigger": trigger, "started_at": started_at, "finished_at": utc_now(), "sources": source_results}
        write_json(self.health_path, health)
        print(json.dumps(health, ensure_ascii=False, sort_keys=True), flush=True)
        return health

    def _sync_source(self, source_config: dict[str, Any], state: dict[str, Any]) -> tuple[dict[str, Any], bool]:
        """source 1件を同期する。

        Args:
            source_config: source設定。
            state: checkpoint全体。

        Returns:
            source結果と更新有無。
        """

        source_name = str(source_config.get("name", "unnamed"))
        if not to_bool(source_config.get("enabled", False)):
            return {"source": source_name, "status": "disabled", "updated": 0, "skipped": 0}, False
        try:
            connector = create_connector(source_config, self.http_client)
            batch = connector.sync(source_state_for(state, source_name))
            for page in batch.pages:
                self.llmwiki.write_page(page.path, page.content)
            if batch.pages:
                for ingest_path in batch.ingest_paths:
                    self.llmwiki.ingest(ingest_path)
            state.setdefault("sources", {})[source_name] = batch.state
            write_json(self.checkpoint_path, state)
            return {
                "source": source_name,
                "status": "ok",
                "updated": len(batch.pages),
                "skipped": batch.skipped,
                "ingested": batch.ingest_paths if batch.pages else [],
            }, bool(batch.pages)
        except MissingCredentialError as exc:
            return {"source": source_name, "status": "credential_error", "error": str(exc)}, False
        except (SyncError, RuntimeError, urllib.error.URLError, ET.ParseError, json.JSONDecodeError) as exc:
            return {"source": source_name, "status": "error", "error": str(exc)}, False

    def _busy_health(self, trigger: str) -> dict[str, Any]:
        """同期中に追加実行された場合のhealth dictを作る。

        Args:
            trigger: 実行理由。

        Returns:
            busy状態のhealth dict。
        """

        return {"status": "busy", "trigger": trigger, "started_at": utc_now(), "sources": []}

    def _source_summaries(self) -> list[dict[str, Any]]:
        """設定済みsourceの概要を返す。

        Args:
            None。

        Returns:
            source名、type、有効化状態の一覧。
        """

        return [
            {
                "name": str(source_config.get("name", "unnamed")),
                "type": str(source_config.get("type", "")),
                "enabled": to_bool(source_config.get("enabled", False)),
            }
            for source_config in self.config.get("sources", [])
        ]


def source_state_for(state: dict[str, Any], source_name: str) -> dict[str, Any]:
    """source別checkpointを取り出す。

    Args:
        state: checkpoint全体。
        source_name: source名。

    Returns:
        source別checkpoint。旧CouchDB専用形式の場合は互換変換した値。
    """

    sources = state.setdefault("sources", {})
    if source_name in sources:
        return copy.deepcopy(sources[source_name])
    if source_name == "couchdb" and isinstance(state.get("legacy_couchdb"), dict):
        return {"databases": state["legacy_couchdb"]}
    return {}


def utc_now() -> str:
    """現在UTC時刻を秒精度ISO 8601で返す。

    Args:
        None。

    Returns:
        UTC時刻文字列。
    """

    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
