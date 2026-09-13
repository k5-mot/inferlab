"""OIKB同期とOpen WebUI停止ファイル削除を一元管理する。"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

from dotenv import load_dotenv

LOGGER = logging.getLogger(__name__)
DEFAULT_ENV_FILE = Path(__file__).resolve().parents[2] / ".env"
TERMINAL_SYNC_STATUSES = frozenset({"success", "partial", "error", "cancelled"})
DELETE_STATUSES = frozenset({"pending", "failed"})
FILE_LOG_INTERVAL_SECONDS = 60
LOG_LEVEL_STYLES = (
    (logging.DEBUG, "DEBUG", "36"),
    (logging.INFO, "INFO", "32"),
    (logging.WARNING, "WARNING", "33"),
    (logging.ERROR, "ERROR", "31"),
    (logging.CRITICAL, "CRITICAL", "1;31"),
)


@dataclass(frozen=True)
class SourceConfig:
    """OIKB sourceとOpen WebUI Knowledge Baseの対応を表す。"""

    key: str
    name: str
    knowledge_id: str


def configure_logging() -> None:
    """terminalでlog level名を色付きにしてroot loggerを設定する。

    Args:
        なし。

    Returns:
        なし。

    Side Effects:
        root loggerのhandlerとlevel名を更新する。`NO_COLOR`設定時は色を付けない。
    """
    use_color = sys.stderr.isatty() and "NO_COLOR" not in os.environ
    for level, name, color in LOG_LEVEL_STYLES:
        display_name = f"\033[{color}m{name}\033[0m" if use_color else name
        logging.addLevelName(level, display_name)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        force=True,
    )


def load_environment(env_file: Path) -> bool:
    """dotenv fileから未設定の環境変数を読み込む。

    Args:
        env_file: 読み込むdotenv fileのpath。

    Returns:
        dotenv fileから値を読み込めた場合はTrue、fileがない場合はFalse。

    Side Effects:
        processに未設定の環境変数を追加する。既存値は上書きしない。
    """
    return load_dotenv(dotenv_path=env_file, override=False)


def request_json(method: str, url: str, token: str | None = None) -> Any:
    """任意のBearer認証付きHTTP requestを送りJSON responseを返す。

    Args:
        method: HTTP method。
        url: request先URL。
        token: Bearer token。認証不要の場合はNone。

    Returns:
        JSON responseをdecodeした値。

    Raises:
        HTTPError: HTTP responseがerrorの場合。
        URLError: 接続に失敗した場合。
        json.JSONDecodeError: responseがJSONでない場合。
    """
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    request = Request(
        url,
        data=b"" if method != "GET" else None,
        headers=headers,
        method=method,
    )
    with urlopen(request, timeout=60) as response:
        return json.load(response)


def get_pending_files(
    open_webui_url: str,
    open_webui_api_key: str,
    knowledge_id: str,
) -> list[dict[str, Any]]:
    """Knowledge Baseへ未接続の処理中ファイルを取得する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        knowledge_id: 検索対象のKnowledge ID。

    Returns:
        pending file responseのlist。

    Raises:
        TypeError: Open WebUI responseがlistでない場合。
        HTTPError: Open WebUIがHTTP errorを返した場合。
        URLError: Open WebUIへ接続できない場合。
    """
    encoded_id = quote(knowledge_id, safe="")
    url = f"{open_webui_url.rstrip('/')}/api/v1/knowledge/{encoded_id}/files/pending"
    payload = request_json("GET", url, open_webui_api_key)
    if not isinstance(payload, list):
        raise TypeError("Open WebUI pending files response must be a list")
    return [item for item in payload if isinstance(item, dict)]


def list_open_webui_files(
    open_webui_url: str,
    open_webui_api_key: str,
) -> list[dict[str, Any]]:
    """Open WebUIで参照可能な全fileをpage単位で取得する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。

    Returns:
        Open WebUI file responseのlist。

    Raises:
        TypeError: Open WebUI responseの形式が不正な場合。
        HTTPError: Open WebUIがHTTP errorを返した場合。
        URLError: Open WebUIへ接続できない場合。
    """
    files: list[dict[str, Any]] = []
    limit = 1000
    while True:
        query = urlencode(
            {
                "filename": "*",
                "content": "false",
                "skip": len(files),
                "limit": limit,
            }
        )
        try:
            payload = request_json(
                "GET",
                f"{open_webui_url.rstrip('/')}/api/v1/files/search?{query}",
                open_webui_api_key,
            )
        except HTTPError as error:
            if error.code == 404:
                return files
            raise
        if not isinstance(payload, list):
            raise TypeError("Open WebUI file search response must be a list")
        items = [item for item in payload if isinstance(item, dict)]
        files.extend(items)
        if len(payload) < limit:
            return files


def get_file_knowledge_id(file_item: dict[str, Any]) -> str | None:
    """Open WebUI file metadataからKnowledge IDを取得する。

    Args:
        file_item: Open WebUI file response。

    Returns:
        metadataに含まれるKnowledge ID。取得できない場合はNone。
    """
    metadata = file_item.get("meta")
    if not isinstance(metadata, dict):
        return None
    nested = metadata.get("data")
    knowledge_id = nested.get("knowledge_id") if isinstance(nested, dict) else None
    if not isinstance(knowledge_id, str) or not knowledge_id:
        knowledge_id = metadata.get("knowledge_id")
    return knowledge_id if isinstance(knowledge_id, str) and knowledge_id else None


def select_delete_candidates(
    files: Sequence[dict[str, Any]],
    knowledge_ids: Sequence[str],
) -> list[dict[str, Any]]:
    """全KBのfileからpendingまたはfailedだけを削除候補にする。

    Args:
        files: Open WebUI file response。
        knowledge_ids: 対象Knowledge ID。空の場合は全Knowledge Baseを対象にする。

    Returns:
        対象KBに属する`pending`または`failed`状態のfile list。
    """
    target_ids = set(knowledge_ids)
    selected: list[dict[str, Any]] = []
    for file_item in files:
        data = file_item.get("data")
        status = data.get("status") if isinstance(data, dict) else None
        knowledge_id = get_file_knowledge_id(file_item)
        if (
            status in DELETE_STATUSES
            and knowledge_id is not None
            and (not target_ids or knowledge_id in target_ids)
            and isinstance(file_item.get("id"), str)
            and file_item["id"]
        ):
            selected.append(file_item)
    return selected


def delete_file(open_webui_url: str, open_webui_api_key: str, file_id: str) -> None:
    """Open WebUI APIを使ってfileと関連vectorを削除する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        file_id: 削除対象のfile ID。

    Returns:
        なし。

    Raises:
        HTTPError: Open WebUIがHTTP errorを返した場合。
        URLError: Open WebUIへ接続できない場合。

    Side Effects:
        Open WebUIのfile、Knowledge関連、vectorを削除する。
    """
    encoded_id = quote(file_id, safe="")
    request_json(
        "DELETE",
        f"{open_webui_url.rstrip('/')}/api/v1/files/{encoded_id}",
        open_webui_api_key,
    )


def cleanup_stuck_files(
    open_webui_url: str,
    open_webui_api_key: str,
    knowledge_ids: Sequence[str],
    dry_run: bool,
) -> int:
    """全Knowledge Baseのpendingとfailed fileを検出または削除する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        knowledge_ids: 調査対象のKnowledge ID。空の場合は全KBを対象にする。
        dry_run: Trueの場合は対象fileをlogへ記録するだけにする。

    Returns:
        検出した削除候補file数。

    Raises:
        HTTPError: Open WebUIがHTTP errorを返した場合。
        URLError: Open WebUIへ接続できない場合。

    Side Effects:
        dry_runがFalseの場合、停止fileと関連データを削除する。
    """
    candidates = select_delete_candidates(
        list_open_webui_files(open_webui_url, open_webui_api_key),
        knowledge_ids,
    )
    for file_item in candidates:
        file_id = file_item["id"]
        status = file_item["data"]["status"]
        knowledge_id = get_file_knowledge_id(file_item)
        filename = file_item.get("filename", "")
        LOGGER.warning(
            "Delete candidate: knowledge_id=%s file_id=%s status=%s file=%s",
            knowledge_id,
            file_id,
            status,
            filename,
        )
        if not dry_run:
            delete_file(open_webui_url, open_webui_api_key, file_id)
            LOGGER.info("Deleted a stuck file: file_id=%s", file_id)
    return len(candidates)


def get_source_states(oikb_url: str) -> dict[str, dict[str, Any]]:
    """OIKB health responseからsource状態を取得する。

    Args:
        oikb_url: OIKBのbase URL。

    Returns:
        source keyをkey、source状態をvalueとするdict。

    Raises:
        TypeError: OIKB health responseの形式が不正な場合。
        HTTPError: OIKBがHTTP errorを返した場合。
        URLError: OIKBへ接続できない場合。
    """
    payload = request_json("GET", f"{oikb_url.rstrip('/')}/health")
    if not isinstance(payload, dict) or not isinstance(payload.get("sources"), dict):
        raise TypeError("OIKB health response must contain a sources object")
    return {
        key: value
        for key, value in payload["sources"].items()
        if isinstance(key, str) and isinstance(value, dict)
    }


def discover_sources(oikb_url: str, source_order: Sequence[str]) -> list[SourceConfig]:
    """OIKB sourceを指定順または設定順で解決する。

    Args:
        oikb_url: OIKBのbase URL。
        source_order: 明示されたsource nameの順序。空ならhealthの順序を使う。

    Returns:
        同期順に並べたsource設定。

    Raises:
        ValueError: source nameが未知、またはKnowledge IDが取得できない場合。
        TypeError: OIKB health responseの形式が不正な場合。
    """
    states = get_source_states(oikb_url)
    by_name: dict[str, SourceConfig] = {}
    discovered_order: list[str] = []
    for key, state in states.items():
        name = state.get("name")
        knowledge_id = state.get("kb_id")
        if not isinstance(name, str) or not name:
            continue
        if not isinstance(knowledge_id, str) or not knowledge_id:
            raise ValueError(
                f"OIKB source has no kb_id: source={name}; rebuild the OIKB image"
            )
        by_name[name] = SourceConfig(key, name, knowledge_id)
        discovered_order.append(name)

    names = list(source_order) or discovered_order
    if not source_order:
        LOGGER.info(
            "OIKB source order is not configured; using all discovered sources: %s",
            ",".join(discovered_order),
        )
    unknown = [name for name in names if name not in by_name]
    if unknown:
        raise ValueError(f"Unknown OIKB source: {', '.join(unknown)}")
    if not names:
        raise ValueError("No sources are registered in OIKB")
    return [by_name[name] for name in names]


def trigger_sync(
    oikb_url: str,
    oikb_api_key: str,
    source: SourceConfig,
) -> dict[str, Any]:
    """指定したOIKB sourceの同期を非同期にtriggerする。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        source: trigger対象のsource設定。

    Returns:
        検証済みのOIKB trigger response。

    Raises:
        ValueError: OIKBがtrigger成功を返さない、またはKB IDが一致しない場合。
        HTTPError: OIKBがHTTP errorを返した場合。
        URLError: OIKBへ接続できない場合。

    Side Effects:
        OIKBの同期処理を開始する。
    """
    encoded_name = quote(source.name, safe="")
    payload = request_json(
        "POST",
        f"{oikb_url.rstrip('/')}/sync/{encoded_name}",
        oikb_api_key,
    )
    if not isinstance(payload, dict) or payload.get("triggered") is not True:
        raise ValueError(f"OIKB did not trigger source: {source.name}")
    if payload.get("kb_id") != source.knowledge_id:
        raise ValueError(f"OIKB trigger returned an unexpected KB ID: {source.name}")
    return payload


def preview_sync(
    oikb_url: str,
    oikb_api_key: str,
    source: SourceConfig,
) -> int:
    """指定したOIKB sourceの未同期fileをdry-runで記録する。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        source: 確認対象のsource設定。

    Returns:
        追加または更新が必要なfile数。

    Raises:
        ValueError: OIKBのdry-run responseが不正な場合。
        HTTPError: OIKBがHTTP errorを返した場合。
        URLError: OIKBへ接続できない場合。

    Side Effects:
        OIKBへdry-runを要求し、未同期fileをlogへ記録する。
    """
    encoded_name = quote(source.name, safe="")
    payload = request_json(
        "POST",
        f"{oikb_url.rstrip('/')}/sync/{encoded_name}?dry_run=true",
        oikb_api_key,
    )
    if (
        not isinstance(payload, dict)
        or payload.get("dry_run") is not True
        or payload.get("kb_id") != source.knowledge_id
        or not isinstance(payload.get("result"), dict)
    ):
        raise ValueError(f"OIKB dry-run returned an invalid response: {source.name}")
    result = payload["result"]
    files = result.get("files")
    changed_count = int(result.get("added", 0)) + int(result.get("modified", 0))
    if not isinstance(files, list):
        if changed_count:
            raise ValueError(
                "OIKB dry-run response has no file details; rebuild the OIKB2 image"
            )
        files = []
    for file_item in files:
        if not isinstance(file_item, dict):
            continue
        LOGGER.info(
            "Unsynced OIKB file: source=%s action=%s file=%s",
            source.name,
            file_item.get("action", "unknown"),
            file_item.get("path", "unknown"),
        )
    LOGGER.info(
        "OIKB dry-run completed: source=%s unsynced=%d unchanged=%s",
        source.name,
        changed_count,
        result.get("unmodified", 0),
    )
    return changed_count


def preview_all_syncs(
    oikb_url: str,
    oikb_api_key: str,
    source_order: Sequence[str],
) -> int:
    """全sourceの未同期fileを変更せずに記録する。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        source_order: source nameの確認順。空ならOIKB設定順。

    Returns:
        全sourceの追加または更新が必要なfile数。

    Raises:
        ValueError: source設定またはdry-run responseが不正な場合。

    Side Effects:
        OIKBへsourceごとのdry-runを要求し、未同期fileをlogへ記録する。
    """
    return sum(
        preview_sync(oikb_url, oikb_api_key, source)
        for source in discover_sources(oikb_url, source_order)
    )


def wait_for_oikb_sync(
    oikb_url: str,
    open_webui_url: str,
    open_webui_api_key: str,
    source: SourceConfig,
    previous_last_sync: float | None,
    triggered_at: float,
    poll_interval_seconds: int,
    timeout_seconds: int,
) -> dict[str, Any]:
    """今回triggerしたOIKB同期がterminal statusになるまで待つ。

    Args:
        oikb_url: OIKBのbase URL。
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        source: 監視対象のsource設定。
        previous_last_sync: trigger直前の最終同期Unix時刻。
        triggered_at: trigger request開始時のUnix時刻。
        poll_interval_seconds: 状態確認間隔の秒数。
        timeout_seconds: 最大待機秒数。

    Returns:
        今回の同期を示すterminal source状態。

    Raises:
        TimeoutError: 指定時間内に同期が終了しない場合。
        ValueError: sourceが消失、または同期がsuccess以外で終了した場合。
    """
    deadline = time.monotonic() + timeout_seconds
    file_log_interval_polls = max(
        1,
        FILE_LOG_INTERVAL_SECONDS // poll_interval_seconds,
    )
    poll_count = 0
    observed_current_run = False
    while time.monotonic() < deadline:
        state = get_source_states(oikb_url).get(source.key)
        if state is None:
            raise ValueError(f"Source disappeared from OIKB health: {source.name}")
        status = state.get("status")
        last_sync = state.get("last_sync")
        started_at = state.get("started_at")
        if (
            status == "running"
            and isinstance(started_at, (int, float))
            and started_at >= triggered_at
        ):
            observed_current_run = True
        has_new_last_sync = isinstance(last_sync, (int, float)) and (
            previous_last_sync is None or last_sync > previous_last_sync
        )
        if (
            observed_current_run or has_new_last_sync
        ) and status in TERMINAL_SYNC_STATUSES:
            if status != "success":
                raise ValueError(
                    f"OIKB sync finished with status={status}: {source.name}"
                )
            return state
        if poll_count % file_log_interval_polls == 0:
            pending_files = get_pending_files_by_id(
                open_webui_url,
                open_webui_api_key,
                source.knowledge_id,
            )
            for filename in sorted(pending_files.values()):
                LOGGER.info(
                    "Processing Open WebUI file: source=%s file=%s",
                    source.name,
                    filename,
                )
        poll_count += 1
        time.sleep(poll_interval_seconds)
    raise TimeoutError(f"OIKB sync timed out: {source.name}")


def wait_for_sync_history(
    oikb_url: str,
    oikb_api_key: str,
    source: SourceConfig,
    triggered_at: float,
    poll_interval_seconds: int,
    timeout_seconds: int,
) -> dict[str, Any]:
    """今回のOIKB同期履歴が永続化されるまで待つ。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        source: 監視対象のsource設定。
        triggered_at: trigger request開始時のUnix時刻。
        poll_interval_seconds: 状態確認間隔の秒数。
        timeout_seconds: 最大待機秒数。

    Returns:
        今回の同期に対応するhistory entry。

    Raises:
        TimeoutError: 指定時間内にhistory entryを取得できない場合。
        TypeError: history responseの形式が不正な場合。
        ValueError: 今回のhistory entryがsuccess以外の場合。
    """
    query = urlencode({"limit": 10, "kb_id": source.knowledge_id})
    url = f"{oikb_url.rstrip('/')}/history?{query}"
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        payload = request_json("GET", url, oikb_api_key)
        if not isinstance(payload, dict) or not isinstance(
            payload.get("entries"), list
        ):
            raise TypeError("OIKB history response must contain an entries list")
        for entry in payload["entries"]:
            if (
                isinstance(entry, dict)
                and entry.get("source") == source.key
                and entry.get("kb_id") == source.knowledge_id
                and isinstance(entry.get("started_at"), (int, float))
                and entry["started_at"] >= triggered_at
            ):
                if entry.get("status") != "success":
                    raise ValueError(
                        f"OIKB sync history has status={entry.get('status')}: {source.name}"
                    )
                return entry
        time.sleep(poll_interval_seconds)
    raise TimeoutError(f"OIKB sync history timed out: {source.name}")


def list_knowledge_files(
    open_webui_url: str,
    open_webui_api_key: str,
    knowledge_id: str,
) -> list[dict[str, Any]]:
    """Knowledge Baseへlink済みの全fileを取得する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        knowledge_id: 対象Knowledge ID。

    Returns:
        link済みfile responseのlist。

    Raises:
        TypeError: Open WebUI responseの形式が不正な場合。
    """
    files: list[dict[str, Any]] = []
    page = 1
    while True:
        query = urlencode({"page": page, "limit": 1000})
        payload = request_json(
            "GET",
            f"{open_webui_url.rstrip('/')}/api/v1/knowledge/{quote(knowledge_id, safe='')}/files?{query}",
            open_webui_api_key,
        )
        if not isinstance(payload, dict) or not isinstance(payload.get("items"), list):
            raise TypeError("Open WebUI knowledge files response must contain items")
        items = [item for item in payload["items"] if isinstance(item, dict)]
        files.extend(items)
        total = payload.get("total")
        if not items or not isinstance(total, int) or len(files) >= total:
            return files
        page += 1


def list_linked_file_ids(
    open_webui_url: str,
    open_webui_api_key: str,
    knowledge_id: str,
) -> set[str]:
    """Knowledge Baseへlink済みの全file IDを取得する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        knowledge_id: 対象Knowledge ID。

    Returns:
        link済みfile IDのset。
    """
    return {
        item["id"]
        for item in list_knowledge_files(
            open_webui_url,
            open_webui_api_key,
            knowledge_id,
        )
        if isinstance(item.get("id"), str) and item["id"]
    }


def get_pending_files_by_id(
    open_webui_url: str,
    open_webui_api_key: str,
    knowledge_id: str,
) -> dict[str, str]:
    """Knowledge Baseで処理中かつ未linkのfile名をIDごとに取得する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        knowledge_id: 対象Knowledge ID。

    Returns:
        pendingまたはprocessing状態のfile IDをkey、表示名をvalueとするdict。

    Raises:
        TypeError: Open WebUI responseがlistでない場合。
        HTTPError: Open WebUIがHTTP errorを返した場合。
        URLError: Open WebUIへ接続できない場合。
    """
    result: dict[str, str] = {}
    for item in get_pending_files(
        open_webui_url,
        open_webui_api_key,
        knowledge_id,
    ):
        file_id = item.get("id")
        if not isinstance(file_id, str) or not file_id:
            continue
        filename = item.get("filename")
        result[file_id] = (
            filename if isinstance(filename, str) and filename else file_id
        )
    return result


def wait_for_existing_pending_files(
    open_webui_url: str,
    open_webui_api_key: str,
    source: SourceConfig,
    poll_interval_seconds: int,
    timeout_seconds: int,
) -> None:
    """同期開始前からあるpending fileの処理完了を待つ。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        source: 監視対象のsource設定。
        poll_interval_seconds: 状態確認間隔の秒数。
        timeout_seconds: 最大待機秒数。

    Returns:
        なし。

    Raises:
        TimeoutError: 指定時間内のpending fileが解消しない場合。
        ValueError: pending fileの処理が失敗した場合。
    """
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        pending_files = get_pending_files_by_id(
            open_webui_url,
            open_webui_api_key,
            source.knowledge_id,
        )
        if not pending_files:
            return

        LOGGER.info(
            "Waiting for existing Open WebUI files: source=%s pending=%d files=%s",
            source.name,
            len(pending_files),
            ", ".join(sorted(pending_files.values())),
        )
        time.sleep(poll_interval_seconds)

    raise TimeoutError(
        f"Existing Open WebUI files timed out: source={source.name}. Run "
        "python3 scripts/oikb/oikb_sync.py delete --dry-run "
        f"--knowledge-id {source.knowledge_id} first; then rerun without "
        "--dry-run to delete"
    )


def wait_for_open_webui_registration(
    open_webui_url: str,
    open_webui_api_key: str,
    source: SourceConfig,
    previous_linked_ids: set[str] | None,
    history: dict[str, Any],
    poll_interval_seconds: int,
    timeout_seconds: int,
) -> None:
    """KB内の全file完了と今回uploadされたfileのlink完了を待つ。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        source: 監視対象のsource設定。
        previous_linked_ids: trigger直前のlink済みfile ID set。再開時はNone。
        history: 今回のOIKB history entry。
        poll_interval_seconds: 状態確認間隔の秒数。
        timeout_seconds: 最大待機秒数。

    Returns:
        なし。

    Raises:
        TimeoutError: 指定時間内に登録が完了しない場合。
        ValueError: file失敗、同時upload、またはfile数不整合の場合。
    """
    added = int(history.get("files_added", 0))
    modified = int(history.get("files_modified", 0))
    deleted = int(history.get("files_deleted", 0))
    expected_new_count = added + modified
    # 中断前のlink集合は復元できないため、再開時は状態だけを検証する。
    resumed = previous_linked_ids is None
    baseline_linked_ids = previous_linked_ids or set()
    expected_linked_count = len(baseline_linked_ids) + added - deleted
    observed_new_ids: set[str] = set()
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        pending_files = get_pending_files_by_id(
            open_webui_url,
            open_webui_api_key,
            source.knowledge_id,
        )
        pending_ids = set(pending_files)
        observed_new_ids.update(pending_ids - baseline_linked_ids)
        if not resumed and len(observed_new_ids) > expected_new_count:
            raise ValueError(f"Detected another upload during sync: {source.name}")

        if pending_ids:
            LOGGER.info(
                "Waiting for Open WebUI registration: source=%s "
                "discovered=%d/%d pending=%d files=%s",
                source.name,
                len(observed_new_ids),
                expected_new_count,
                len(pending_ids),
                ", ".join(sorted(pending_files.values())),
            )
            time.sleep(poll_interval_seconds)
            continue

        linked_files = list_knowledge_files(
            open_webui_url,
            open_webui_api_key,
            source.knowledge_id,
        )
        status_files = linked_files
        if any(
            not isinstance(item.get("data"), dict) or "status" not in item["data"]
            for item in linked_files
        ):
            files_by_id = {
                item["id"]: item
                for item in list_open_webui_files(
                    open_webui_url,
                    open_webui_api_key,
                )
                if isinstance(item.get("id"), str) and item["id"]
            }
            status_files = [
                files_by_id.get(item.get("id"), item) for item in linked_files
            ]
        failed_files = [
            item
            for item in status_files
            if isinstance(item.get("data"), dict)
            and item["data"].get("status") == "failed"
        ]
        if failed_files:
            names = [
                str(item.get("filename") or item.get("id")) for item in failed_files
            ]
            raise ValueError(
                f"Open WebUI file processing failed: source={source.name} "
                f"files={', '.join(names)}"
            )
        incomplete_files = [
            item
            for item in status_files
            if not isinstance(item.get("data"), dict)
            or item["data"].get("status") != "completed"
        ]
        if incomplete_files:
            LOGGER.info(
                "Waiting for every Knowledge file to complete: source=%s files=%s",
                source.name,
                ", ".join(
                    str(item.get("filename") or item.get("id"))
                    for item in incomplete_files
                ),
            )
            time.sleep(poll_interval_seconds)
            continue

        linked_ids = {
            item["id"]
            for item in linked_files
            if isinstance(item.get("id"), str) and item["id"]
        }
        new_linked_ids = linked_ids - baseline_linked_ids
        observed_new_ids.update(new_linked_ids)
        if not resumed and len(observed_new_ids) > expected_new_count:
            raise ValueError(f"Detected another upload during sync: {source.name}")
        if not resumed and (
            len(linked_ids) != expected_linked_count
            or len(new_linked_ids) != expected_new_count
        ):
            raise ValueError(
                f"Open WebUI file count mismatch: source={source.name} "
                f"linked={len(linked_ids)}/{expected_linked_count} "
                f"new={len(new_linked_ids)}/{expected_new_count}"
            )

        LOGGER.info(
            "Open WebUI registration completed: source=%s files=%d",
            source.name,
            len(linked_files) if resumed else expected_new_count,
        )
        return

    raise TimeoutError(f"Open WebUI registration timed out: {source.name}")


def sync_source(
    oikb_url: str,
    oikb_api_key: str,
    open_webui_url: str,
    open_webui_api_key: str,
    source: SourceConfig,
    poll_interval_seconds: int,
    oikb_timeout_seconds: int,
    open_webui_timeout_seconds: int,
) -> None:
    """1 sourceをtriggerしOpen WebUIへの登録完了まで待つ。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        source: 同期対象のsource設定。
        poll_interval_seconds: 状態確認間隔の秒数。
        oikb_timeout_seconds: OIKB同期の最大待機秒数。
        open_webui_timeout_seconds: Open WebUI登録の最大待機秒数。

    Returns:
        なし。

    Raises:
        ValueError: 事前状態または同期結果が不正な場合。
        TimeoutError: OIKBまたはOpen WebUIが時間内に完了しない場合。

    Side Effects:
        OIKB同期を開始し、Open WebUIへfileを登録する。
    """
    state = get_source_states(oikb_url).get(source.key, {})
    previous_last_sync = state.get("last_sync")
    if not isinstance(previous_last_sync, (int, float)):
        previous_last_sync = None

    if state.get("status") == "running":
        started_at = state.get("started_at")
        if not isinstance(started_at, (int, float)):
            raise ValueError(f"Running OIKB source has no started_at: {source.name}")
        previous_linked_ids = None
        triggered_at = float(started_at)
        LOGGER.info("Resuming OIKB sync: source=%s", source.name)
    else:
        wait_for_existing_pending_files(
            open_webui_url,
            open_webui_api_key,
            source,
            poll_interval_seconds,
            open_webui_timeout_seconds,
        )
        previous_linked_ids = list_linked_file_ids(
            open_webui_url,
            open_webui_api_key,
            source.knowledge_id,
        )
        triggered_at = time.time()
        trigger_sync(oikb_url, oikb_api_key, source)
        LOGGER.info("Triggered OIKB sync: source=%s", source.name)
    terminal_state = wait_for_oikb_sync(
        oikb_url,
        open_webui_url,
        open_webui_api_key,
        source,
        previous_last_sync,
        triggered_at,
        poll_interval_seconds,
        oikb_timeout_seconds,
    )
    for warning in terminal_state.get("warnings", []):
        LOGGER.warning("OIKB sync warning: source=%s detail=%s", source.name, warning)
    history = wait_for_sync_history(
        oikb_url,
        oikb_api_key,
        source,
        triggered_at,
        poll_interval_seconds,
        oikb_timeout_seconds,
    )
    wait_for_open_webui_registration(
        open_webui_url,
        open_webui_api_key,
        source,
        previous_linked_ids,
        history,
        poll_interval_seconds,
        open_webui_timeout_seconds,
    )


def trigger_all_syncs(
    oikb_url: str,
    oikb_api_key: str,
    open_webui_url: str,
    open_webui_api_key: str,
    source_order: Sequence[str],
    poll_interval_seconds: int,
    oikb_timeout_seconds: int,
    open_webui_timeout_seconds: int,
) -> int:
    """全sourceを指定順に同期し、それぞれの登録完了まで待つ。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        source_order: source nameの実行順。空ならOIKB設定順。
        poll_interval_seconds: 状態確認間隔の秒数。
        oikb_timeout_seconds: OIKB同期の最大待機秒数。
        open_webui_timeout_seconds: Open WebUI登録の最大待機秒数。

    Returns:
        登録完了したsource数。

    Raises:
        ValueError: source設定または同期結果が不正な場合。
        TimeoutError: OIKBまたはOpen WebUIが時間内に完了しない場合。

    Side Effects:
        sourceを1つずつOIKBへtriggerし、Open WebUIへ登録する。
    """
    sources = discover_sources(oikb_url, source_order)
    for source in sources:
        sync_source(
            oikb_url,
            oikb_api_key,
            open_webui_url,
            open_webui_api_key,
            source,
            poll_interval_seconds,
            oikb_timeout_seconds,
            open_webui_timeout_seconds,
        )
    return len(sources)


def run_scheduler(
    oikb_url: str,
    oikb_api_key: str,
    open_webui_url: str,
    open_webui_api_key: str,
    source_order: Sequence[str],
    interval_seconds: int,
    poll_interval_seconds: int,
    oikb_timeout_seconds: int,
    open_webui_timeout_seconds: int,
) -> None:
    """指定間隔で全sourceの逐次同期を継続する。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        source_order: source nameの実行順。空ならOIKB設定順。
        interval_seconds: 同期周期の秒数。
        poll_interval_seconds: 状態確認間隔の秒数。
        oikb_timeout_seconds: OIKB同期の最大待機秒数。
        open_webui_timeout_seconds: Open WebUI登録の最大待機秒数。

    Returns:
        なし。processを停止するまで継続する。

    Side Effects:
        各周期で全sourceを逐次同期し、周期の間sleepする。
    """
    while True:
        cycle_started_at = time.perf_counter()
        try:
            count = trigger_all_syncs(
                oikb_url,
                oikb_api_key,
                open_webui_url,
                open_webui_api_key,
                source_order,
                poll_interval_seconds,
                oikb_timeout_seconds,
                open_webui_timeout_seconds,
            )
            LOGGER.info("Sequential sync completed: sources=%d", count)
        except (
            HTTPError,
            URLError,
            TypeError,
            ValueError,
            TimeoutError,
            json.JSONDecodeError,
        ) as error:
            LOGGER.error("Sequential sync failed: %s", error)
        LOGGER.info(
            "Cycle duration: %.3f seconds", time.perf_counter() - cycle_started_at
        )
        time.sleep(interval_seconds)


def build_parser() -> argparse.ArgumentParser:
    """command line option parserを作成する。

    Args:
        なし。

    Returns:
        OIKB保守CLI用ArgumentParser。
    """
    parser = argparse.ArgumentParser(
        description="OIKB同期とOpen WebUI停止ファイル削除を実行します。",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    trigger_parser = subparsers.add_parser(
        "trigger",
        help="OIKB sourceをKnowledge登録完了まで1つずつ同期します。",
    )
    trigger_parser.add_argument(
        "--source",
        action="append",
        default=None,
        help=(
            "同期するsource名です。繰り返し指定すると順序を定義し、"
            "未指定時はOIKBの全sourceを設定順に処理します。"
        ),
    )
    trigger_parser.add_argument(
        "--interval-seconds",
        type=int,
        default=int(os.environ.get("OIKB_TRIGGER_INTERVAL_SECONDS", "3600")),
        help="--watch時の同期間隔です。",
    )
    trigger_parser.add_argument(
        "--poll-interval-seconds",
        type=int,
        default=int(os.environ.get("OIKB_TRIGGER_POLL_INTERVAL_SECONDS", "3")),
        help="OIKBとOpen WebUIの状態確認間隔です。",
    )
    trigger_parser.add_argument(
        "--oikb-timeout-seconds",
        type=int,
        default=int(os.environ.get("OIKB_TRIGGER_SYNC_TIMEOUT_SECONDS", "21600")),
        help="1 sourceのOIKB同期完了待ちtimeoutです。",
    )
    trigger_parser.add_argument(
        "--open-webui-timeout-seconds",
        type=int,
        default=int(os.environ.get("OPEN_WEBUI_PROCESS_TIMEOUT_SECONDS", "21600")),
        help="1 sourceのOpen WebUI登録完了待ちtimeoutです。",
    )
    trigger_mode = trigger_parser.add_mutually_exclusive_group()
    trigger_mode.add_argument(
        "--watch",
        action="store_true",
        help="全sourceの完了後も指定間隔で同期を繰り返します。",
    )
    trigger_mode.add_argument(
        "--dry-run",
        action="store_true",
        help="変更せず、まだ同期されていないfileをlogへ記録します。",
    )

    delete_parser = subparsers.add_parser(
        "delete",
        help="Open WebUIで停止したKnowledge fileを削除します。",
    )
    delete_parser.add_argument(
        "--knowledge-id",
        action="append",
        default=[],
        help=(
            "対象Knowledge IDです。繰り返し指定でき、"
            "未指定時はOpen WebUIの全KBを処理します。"
        ),
    )
    delete_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="削除せずpendingとfailed fileをlogへ記録します。",
    )
    return parser


def run_trigger_command(
    args: argparse.Namespace,
    parser: argparse.ArgumentParser,
    oikb_url: str,
    oikb_api_key: str | None,
    open_webui_url: str,
    open_webui_api_key: str | None,
) -> int:
    """trigger subcommandを実行する。

    Args:
        args: trigger subcommandの解析済み引数。
        parser: 設定errorの報告に使うroot parser。
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。

    Returns:
        正常終了時は0。

    Side Effects:
        OIKB sourceを逐次同期する。`--watch`指定時は同期を繰り返す。
    """
    if not oikb_api_key:
        parser.error("OIKB_API_KEY environment variable is required")
    env_source_order = [
        name.strip()
        for name in os.environ.get("OIKB_SOURCE_ORDER", "").split(",")
        if name.strip()
    ]
    source_order = args.source if args.source is not None else env_source_order
    if args.dry_run:
        count = preview_all_syncs(oikb_url, oikb_api_key, source_order)
        LOGGER.info("OIKB dry-run completed: unsynced=%d", count)
        return 0

    if not open_webui_api_key:
        parser.error("OPEN_WEBUI_API_KEY environment variable is required")
    for option_name in (
        "interval_seconds",
        "poll_interval_seconds",
        "oikb_timeout_seconds",
        "open_webui_timeout_seconds",
    ):
        if getattr(args, option_name) <= 0:
            parser.error(f"--{option_name.replace('_', '-')} must be at least 1")

    common_args = (
        oikb_url,
        oikb_api_key,
        open_webui_url,
        open_webui_api_key,
        source_order,
    )
    if args.watch:
        run_scheduler(
            *common_args,
            args.interval_seconds,
            args.poll_interval_seconds,
            args.oikb_timeout_seconds,
            args.open_webui_timeout_seconds,
        )
        return 0

    count = trigger_all_syncs(
        *common_args,
        args.poll_interval_seconds,
        args.oikb_timeout_seconds,
        args.open_webui_timeout_seconds,
    )
    LOGGER.info("Sequential sync completed: sources=%d", count)
    return 0


def run_delete_command(
    args: argparse.Namespace,
    parser: argparse.ArgumentParser,
    open_webui_url: str,
    open_webui_api_key: str | None,
) -> int:
    """delete subcommandを実行する。

    Args:
        args: delete subcommandの解析済み引数。
        parser: 設定errorの報告に使うroot parser。
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。

    Returns:
        正常終了時は0。

    Side Effects:
        `--dry-run`時は削除候補をlogへ記録する。それ以外は停止fileをOpen
        WebUIから削除する。
    """
    if not open_webui_api_key:
        parser.error("OPEN_WEBUI_API_KEY environment variable is required")
    if not args.knowledge_id:
        LOGGER.info("Knowledge ID is not configured; using all Knowledge Bases")
    if not args.dry_run:
        LOGGER.warning("Delete mode enabled: stuck files cannot be restored")
    count = cleanup_stuck_files(
        open_webui_url,
        open_webui_api_key,
        args.knowledge_id,
        args.dry_run,
    )
    mode = "dry-run" if args.dry_run else "delete"
    LOGGER.info("Delete command completed: mode=%s files=%d", mode, count)
    return 0


def main(argv: Sequence[str]) -> int:
    """OIKB保守CLIのcommand line処理を実行する。

    Args:
        argv: プログラム名を含むcommand line引数。

    Returns:
        正常終了時は0、設定または通信error時は1、不正な引数では2。

    Side Effects:
        環境変数を読み込み、選択された処理と実行時間をlogへ記録する。
    """
    started_at = time.perf_counter()
    try:
        load_environment(DEFAULT_ENV_FILE)
        parser = build_parser()
        args = parser.parse_args(argv[1:])
        oikb_url = os.environ.get("OIKB_API_URL", "http://localhost:32001")
        oikb_api_key = os.environ.get("OIKB_API_KEY")
        open_webui_url = os.environ.get(
            "OPEN_WEBUI_API_URL",
            "http://localhost:32000",
        )
        open_webui_api_key = os.environ.get("OPEN_WEBUI_API_KEY")
        if args.command == "trigger":
            return run_trigger_command(
                args,
                parser,
                oikb_url,
                oikb_api_key,
                open_webui_url,
                open_webui_api_key,
            )
        return run_delete_command(
            args,
            parser,
            open_webui_url,
            open_webui_api_key,
        )
    except KeyboardInterrupt:
        LOGGER.info("Stop requested")
        return 0
    except (
        HTTPError,
        URLError,
        TypeError,
        ValueError,
        TimeoutError,
        json.JSONDecodeError,
    ) as error:
        LOGGER.error("OIKB command failed: %s", error)
        return 1
    finally:
        LOGGER.info("Elapsed time: %.3f seconds", time.perf_counter() - started_at)


if __name__ == "__main__":
    configure_logging()
    raise SystemExit(main(sys.argv))
