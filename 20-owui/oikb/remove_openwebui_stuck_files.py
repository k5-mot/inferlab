#!/usr/bin/env python3
"""Open WebUIの処理停止ファイルを安全に検出・削除する。"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from collections.abc import Sequence
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

LOGGER = logging.getLogger(__name__)
STUCK_STATUSES = frozenset({"pending", "processing"})


def request_json(method: str, url: str, token: str) -> Any:
    """Bearer認証付きHTTP requestを送りJSON responseを返す。

    Args:
        method: HTTP method。
        url: request先URL。
        token: Bearer token。

    Returns:
        JSON responseをdecodeした値。

    Raises:
        HTTPError: HTTP responseがerrorの場合。
        URLError: 接続に失敗した場合。
        json.JSONDecodeError: responseがJSONでない場合。
    """
    request = Request(
        url,
        data=b"" if method != "GET" else None,
        headers={"Authorization": f"Bearer {token}"},
        method=method,
    )
    with urlopen(request, timeout=60) as response:
        return json.load(response)


def discover_knowledge_ids(oikb_url: str, oikb_api_key: str) -> list[str]:
    """OIKBの現行sourceに対応するKnowledge IDを取得する。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。

    Returns:
        現在登録されているsourceのKnowledge IDを昇順にしたlist。

    Raises:
        TypeError: OIKB responseの形式が不正な場合。
        HTTPError: OIKBがHTTP errorを返した場合。
        URLError: OIKBへ接続できない場合。
    """
    base_url = oikb_url.rstrip("/")
    health = request_json("GET", f"{base_url}/health", oikb_api_key)
    history = request_json("GET", f"{base_url}/history", oikb_api_key)
    if not isinstance(health, dict) or not isinstance(health.get("sources"), dict):
        raise TypeError("OIKB health response must contain a sources object")
    if not isinstance(history, dict) or not isinstance(history.get("entries"), list):
        raise TypeError("OIKB history response must contain an entries list")

    current_sources = set(health["sources"])
    knowledge_ids = {
        entry["kb_id"]
        for entry in history["entries"]
        if isinstance(entry, dict)
        and entry.get("source") in current_sources
        and isinstance(entry.get("kb_id"), str)
        and entry["kb_id"]
    }
    return sorted(knowledge_ids)


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


def select_stuck_files(
    files: Sequence[dict[str, Any]],
    cutoff_epoch: int,
) -> list[dict[str, Any]]:
    """状態と最終更新時刻から削除候補を選択する。

    Args:
        files: Open WebUIのpending file response。
        cutoff_epoch: このUnix時刻以前を停止状態とみなす境界値。

    Returns:
        `pending`または`processing`で境界時刻以前のfile list。
    """
    selected: list[dict[str, Any]] = []
    for file_item in files:
        data = file_item.get("data")
        status = data.get("status") if isinstance(data, dict) else None
        updated_at = file_item.get("updated_at") or file_item.get("created_at")
        if (
            status in STUCK_STATUSES
            and isinstance(updated_at, int)
            and updated_at <= cutoff_epoch
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
    min_age_seconds: int,
    delete: bool,
) -> int:
    """全Knowledge Baseの停止ファイルを検出し、指定時のみ削除する。

    Args:
        open_webui_url: Open WebUIのbase URL。
        open_webui_api_key: Open WebUI API key。
        knowledge_ids: 調査対象のKnowledge ID。
        min_age_seconds: 停止と判断する最小経過秒数。
        delete: Trueの場合だけ実際に削除する。

    Returns:
        検出した停止ファイル数。

    Raises:
        HTTPError: Open WebUIがHTTP errorを返した場合。
        URLError: Open WebUIへ接続できない場合。

    Side Effects:
        `delete`がTrueの場合、停止ファイルと関連データを削除する。
    """
    cutoff_epoch = int(time.time()) - min_age_seconds
    total = 0
    for knowledge_id in knowledge_ids:
        stuck_files = select_stuck_files(
            get_pending_files(open_webui_url, open_webui_api_key, knowledge_id),
            cutoff_epoch,
        )
        for file_item in stuck_files:
            file_id = file_item["id"]
            status = file_item["data"]["status"]
            LOGGER.warning(
                "停止ファイルを検出しました: knowledge_id=%s file_id=%s status=%s",
                knowledge_id,
                file_id,
                status,
            )
            if delete:
                delete_file(open_webui_url, open_webui_api_key, file_id)
                LOGGER.info("停止ファイルを削除しました: file_id=%s", file_id)
            total += 1
    return total


def build_parser() -> argparse.ArgumentParser:
    """command line option parserを作成する。

    Args:
        なし。

    Returns:
        cleanup script用ArgumentParser。
    """
    parser = argparse.ArgumentParser(
        description="Open WebUIで処理が停止したKnowledge fileを検出します。",
    )
    parser.add_argument(
        "--open-webui-url",
        default=os.environ.get("OPEN_WEBUI_URL", "http://localhost:32000"),
    )
    parser.add_argument(
        "--open-webui-api-key",
        default=os.environ.get("OPEN_WEBUI_API_KEY"),
    )
    parser.add_argument(
        "--oikb-url",
        default=os.environ.get("OIKB_URL", "http://localhost:32001"),
    )
    parser.add_argument("--oikb-api-key", default=os.environ.get("OIKB_API_KEY"))
    parser.add_argument("--knowledge-id", action="append", default=[])
    parser.add_argument(
        "--min-age-seconds",
        type=int,
        default=int(os.environ.get("OPEN_WEBUI_STUCK_FILE_AGE_SECONDS", "3600")),
    )
    parser.add_argument(
        "--delete",
        action="store_true",
        help="検出だけでなく削除を実行します。削除したfileは復元できません。",
    )
    return parser


def main(argv: Sequence[str]) -> int:
    """停止ファイルcleanupのcommand line処理を実行する。

    Args:
        argv: プログラム名を含むcommand line引数。

    Returns:
        正常終了時は0、設定または通信error時は1、不正な引数では2。

    Side Effects:
        実行時間と対象fileをlogへ記録し、`--delete`指定時はfileを削除する。
    """
    started_at = time.perf_counter()
    parser = build_parser()
    args = parser.parse_args(argv[1:])
    if not args.open_webui_api_key:
        parser.error("--open-webui-api-keyまたはOPEN_WEBUI_API_KEYが必要です")
    if not args.knowledge_id and not args.oikb_api_key:
        parser.error(
            "Knowledge IDの自動検出には--oikb-api-keyまたはOIKB_API_KEYが必要です"
        )
    if args.min_age_seconds <= 0:
        parser.error("--min-age-secondsは1以上で指定してください")

    try:
        knowledge_ids = args.knowledge_id or discover_knowledge_ids(
            args.oikb_url,
            args.oikb_api_key,
        )
        if not knowledge_ids:
            LOGGER.warning("対象Knowledge IDがありません")
            return 0
        count = cleanup_stuck_files(
            args.open_webui_url,
            args.open_webui_api_key,
            knowledge_ids,
            args.min_age_seconds,
            args.delete,
        )
        mode = "削除" if args.delete else "dry-run"
        LOGGER.info("cleanup完了: mode=%s files=%d", mode, count)
        return 0
    except (HTTPError, URLError, TypeError, ValueError, json.JSONDecodeError) as error:
        LOGGER.error("cleanupに失敗しました: %s", error)
        return 1
    finally:
        LOGGER.info("処理時間: %.3f秒", time.perf_counter() - started_at)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    raise SystemExit(main(sys.argv))
