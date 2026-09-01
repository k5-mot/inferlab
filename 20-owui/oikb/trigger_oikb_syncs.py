#!/usr/bin/env python3
"""OIKB sourceをOpen WebUIの登録完了まで逐次的に同期する。"""

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


@dataclass(frozen=True)
class SourceConfig:
    """OIKB sourceとOpen WebUI Knowledge Baseの対応を表す。"""

    key: str
    name: str
    knowledge_id: str


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
                f"OIKB sourceにkb_idがありません: source={name}; imageを再buildしてください"
            )
        by_name[name] = SourceConfig(key, name, knowledge_id)
        discovered_order.append(name)

    names = list(source_order) or discovered_order
    unknown = [name for name in names if name not in by_name]
    if unknown:
        raise ValueError(f"未知のOIKB sourceです: {', '.join(unknown)}")
    if not names:
        raise ValueError("OIKBにsourceが登録されていません")
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


def wait_for_oikb_sync(
    oikb_url: str,
    source: SourceConfig,
    previous_last_sync: float | None,
    triggered_at: float,
    poll_interval_seconds: int,
    timeout_seconds: int,
) -> dict[str, Any]:
    """今回triggerしたOIKB同期がterminal statusになるまで待つ。

    Args:
        oikb_url: OIKBのbase URL。
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
    while time.monotonic() < deadline:
        state = get_source_states(oikb_url).get(source.key)
        if state is None:
            raise ValueError(f"OIKB healthからsourceが消失しました: {source.name}")
        status = state.get("status")
        last_sync = state.get("last_sync")
        is_new_run = (
            isinstance(last_sync, (int, float))
            and last_sync >= triggered_at
            and (previous_last_sync is None or last_sync > previous_last_sync)
        )
        if is_new_run and status in TERMINAL_SYNC_STATUSES:
            if status != "success":
                raise ValueError(f"OIKB同期が{status}で終了しました: {source.name}")
            return state
        time.sleep(poll_interval_seconds)
    raise TimeoutError(f"OIKB同期がtimeoutしました: {source.name}")


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
                        f"OIKB同期履歴が{entry.get('status')}です: {source.name}"
                    )
                return entry
        time.sleep(poll_interval_seconds)
    raise TimeoutError(f"OIKB同期履歴がtimeoutしました: {source.name}")


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

    Raises:
        TypeError: Open WebUI responseの形式が不正な場合。
    """
    file_ids: set[str] = set()
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
        file_ids.update(
            item["id"]
            for item in items
            if isinstance(item.get("id"), str) and item["id"]
        )
        total = payload.get("total")
        if not items or not isinstance(total, int) or len(file_ids) >= total:
            return file_ids
        page += 1


def get_pending_file_ids(
    open_webui_url: str,
    open_webui_api_key: str,
    knowledge_id: str,
) -> set[str]:
    """Knowledge Baseで処理中かつ未linkのfile IDを取得する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        knowledge_id: 対象Knowledge ID。

    Returns:
        pendingまたはprocessing状態のfile ID set。

    Raises:
        TypeError: Open WebUI responseがlistでない場合。
    """
    encoded_id = quote(knowledge_id, safe="")
    payload = request_json(
        "GET",
        f"{open_webui_url.rstrip('/')}/api/v1/knowledge/{encoded_id}/files/pending",
        open_webui_api_key,
    )
    if not isinstance(payload, list):
        raise TypeError("Open WebUI pending files response must be a list")
    return {
        item["id"]
        for item in payload
        if isinstance(item, dict) and isinstance(item.get("id"), str) and item["id"]
    }


def get_file_status(
    open_webui_url: str,
    open_webui_api_key: str,
    file_id: str,
) -> str:
    """Open WebUI fileの処理statusを取得する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        file_id: 対象file ID。

    Returns:
        fileの処理status。

    Raises:
        TypeError: status responseの形式が不正な場合。
    """
    payload = request_json(
        "GET",
        f"{open_webui_url.rstrip('/')}/api/v1/files/{quote(file_id, safe='')}/process/status",
        open_webui_api_key,
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("status"), str):
        raise TypeError("Open WebUI file status response must contain status")
    return payload["status"]


def wait_for_open_webui_registration(
    open_webui_url: str,
    open_webui_api_key: str,
    source: SourceConfig,
    previous_linked_ids: set[str],
    history: dict[str, Any],
    poll_interval_seconds: int,
    timeout_seconds: int,
) -> None:
    """今回uploadされた全fileの処理とKnowledge link完了を待つ。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        source: 監視対象のsource設定。
        previous_linked_ids: trigger直前のlink済みfile ID set。
        history: 今回のOIKB history entry。
        poll_interval_seconds: 状態確認間隔の秒数。
        timeout_seconds: 最大待機秒数。

    Returns:
        なし。

    Raises:
        TimeoutError: 指定時間内に登録が完了しない場合。
        ValueError: file処理失敗、同時upload、またはfile数不整合の場合。
    """
    added = int(history.get("files_added", 0))
    modified = int(history.get("files_modified", 0))
    deleted = int(history.get("files_deleted", 0))
    expected_new_count = added + modified
    expected_linked_count = len(previous_linked_ids) + added - deleted
    observed_new_ids: set[str] = set()
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        linked_ids = list_linked_file_ids(
            open_webui_url,
            open_webui_api_key,
            source.knowledge_id,
        )
        pending_ids = get_pending_file_ids(
            open_webui_url,
            open_webui_api_key,
            source.knowledge_id,
        )
        observed_new_ids.update(
            (linked_ids | pending_ids) - previous_linked_ids,
        )
        if len(observed_new_ids) > expected_new_count:
            raise ValueError(f"同期中に別のuploadを検出しました: {source.name}")

        statuses = {
            file_id: get_file_status(
                open_webui_url,
                open_webui_api_key,
                file_id,
            )
            for file_id in observed_new_ids
        }
        failed_ids = [
            file_id for file_id, status in statuses.items() if status == "failed"
        ]
        if failed_ids:
            raise ValueError(
                f"Open WebUI file処理が失敗しました: source={source.name} files={len(failed_ids)}"
            )

        completed_ids = {
            file_id for file_id, status in statuses.items() if status == "completed"
        }
        if (
            len(observed_new_ids) == expected_new_count
            and completed_ids == observed_new_ids
            and observed_new_ids <= linked_ids
            and not pending_ids
            and len(linked_ids) == expected_linked_count
        ):
            LOGGER.info(
                "Open WebUI登録完了: source=%s files=%d",
                source.name,
                expected_new_count,
            )
            return

        LOGGER.info(
            "Open WebUI登録待機中: source=%s discovered=%d/%d completed=%d linked=%d pending=%d",
            source.name,
            len(observed_new_ids),
            expected_new_count,
            len(completed_ids),
            len(observed_new_ids & linked_ids),
            len(pending_ids),
        )
        time.sleep(poll_interval_seconds)

    raise TimeoutError(f"Open WebUI登録がtimeoutしました: {source.name}")


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
    if state.get("status") == "running":
        raise ValueError(f"OIKB sourceは既に同期中です: {source.name}")
    pending_ids = get_pending_file_ids(
        open_webui_url,
        open_webui_api_key,
        source.knowledge_id,
    )
    if pending_ids:
        raise ValueError(
            f"同期前からOpen WebUIに処理中fileがあります: source={source.name} files={len(pending_ids)}"
        )

    previous_linked_ids = list_linked_file_ids(
        open_webui_url,
        open_webui_api_key,
        source.knowledge_id,
    )
    previous_last_sync = state.get("last_sync")
    if not isinstance(previous_last_sync, (int, float)):
        previous_last_sync = None

    triggered_at = time.time()
    trigger_sync(oikb_url, oikb_api_key, source)
    LOGGER.info("OIKB同期をtriggerしました: source=%s", source.name)
    terminal_state = wait_for_oikb_sync(
        oikb_url,
        source,
        previous_last_sync,
        triggered_at,
        poll_interval_seconds,
        oikb_timeout_seconds,
    )
    for warning in terminal_state.get("warnings", []):
        LOGGER.warning("OIKB同期warning: source=%s detail=%s", source.name, warning)
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
            LOGGER.info("逐次同期完了: sources=%d", count)
        except (
            HTTPError,
            URLError,
            TypeError,
            ValueError,
            TimeoutError,
            json.JSONDecodeError,
        ) as error:
            LOGGER.error("逐次同期に失敗しました: %s", error)
        LOGGER.info("周期処理時間: %.3f秒", time.perf_counter() - cycle_started_at)
        time.sleep(interval_seconds)


def build_parser() -> argparse.ArgumentParser:
    """command line option parserを作成する。

    Args:
        なし。

    Returns:
        OIKB逐次同期script用ArgumentParser。
    """
    parser = argparse.ArgumentParser(
        description="OIKB sourceをOpen WebUIの登録完了まで逐次同期します。",
    )
    parser.add_argument(
        "--oikb-url",
        default=os.environ.get("OIKB_URL", "http://localhost:32001"),
    )
    parser.add_argument("--oikb-api-key", default=os.environ.get("OIKB_API_KEY"))
    parser.add_argument(
        "--open-webui-url",
        default=os.environ.get("OPEN_WEBUI_URL", "http://localhost:32000"),
    )
    parser.add_argument(
        "--open-webui-api-key",
        default=os.environ.get("OPEN_WEBUI_API_KEY"),
    )
    parser.add_argument(
        "--source",
        action="append",
        default=None,
        help="同期するsource nameを順番に指定します。複数回指定できます。",
    )
    parser.add_argument(
        "--interval-seconds",
        type=int,
        default=int(os.environ.get("OIKB_TRIGGER_INTERVAL_SECONDS", "3600")),
    )
    parser.add_argument(
        "--poll-interval-seconds",
        type=int,
        default=int(os.environ.get("OIKB_TRIGGER_POLL_INTERVAL_SECONDS", "3")),
    )
    parser.add_argument(
        "--oikb-timeout-seconds",
        type=int,
        default=int(os.environ.get("OIKB_TRIGGER_SYNC_TIMEOUT_SECONDS", "21600")),
    )
    parser.add_argument(
        "--open-webui-timeout-seconds",
        type=int,
        default=int(os.environ.get("OPEN_WEBUI_PROCESS_TIMEOUT_SECONDS", "21600")),
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="1周期だけ同期して終了します。",
    )
    return parser


def main(argv: Sequence[str]) -> int:
    """OIKB逐次同期のcommand line処理を実行する。

    Args:
        argv: プログラム名を含むcommand line引数。

    Returns:
        正常終了時は0、設定または通信error時は1、不正な引数では2。

    Side Effects:
        OIKB sourceを逐次同期し、実行時間をlogへ記録する。
    """
    started_at = time.perf_counter()
    load_environment(DEFAULT_ENV_FILE)
    parser = build_parser()
    args = parser.parse_args(argv[1:])
    if not args.oikb_api_key:
        parser.error("--oikb-api-keyまたはOIKB_API_KEYが必要です")
    if not args.open_webui_api_key:
        parser.error("--open-webui-api-keyまたはOPEN_WEBUI_API_KEYが必要です")
    for option_name in (
        "interval_seconds",
        "poll_interval_seconds",
        "oikb_timeout_seconds",
        "open_webui_timeout_seconds",
    ):
        if getattr(args, option_name) <= 0:
            parser.error(f"--{option_name.replace('_', '-')}は1以上で指定してください")

    env_source_order = [
        name.strip()
        for name in os.environ.get("OIKB_SOURCE_ORDER", "").split(",")
        if name.strip()
    ]
    source_order = args.source if args.source is not None else env_source_order

    try:
        common_args = (
            args.oikb_url,
            args.oikb_api_key,
            args.open_webui_url,
            args.open_webui_api_key,
            source_order,
        )
        if args.once:
            count = trigger_all_syncs(
                *common_args,
                args.poll_interval_seconds,
                args.oikb_timeout_seconds,
                args.open_webui_timeout_seconds,
            )
            LOGGER.info("逐次同期完了: sources=%d", count)
        else:
            run_scheduler(
                *common_args,
                args.interval_seconds,
                args.poll_interval_seconds,
                args.oikb_timeout_seconds,
                args.open_webui_timeout_seconds,
            )
        return 0
    except KeyboardInterrupt:
        LOGGER.info("停止要求を受け付けました")
        return 0
    except (
        HTTPError,
        URLError,
        TypeError,
        ValueError,
        TimeoutError,
        json.JSONDecodeError,
    ) as error:
        LOGGER.error("逐次同期に失敗しました: %s", error)
        return 1
    finally:
        LOGGER.info("処理時間: %.3f秒", time.perf_counter() - started_at)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    raise SystemExit(main(sys.argv))
