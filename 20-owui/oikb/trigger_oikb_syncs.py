#!/usr/bin/env python3
"""OIKBに登録された全sourceの同期を定期的にtriggerする。"""

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


def discover_source_names(oikb_url: str) -> list[str]:
    """OIKB health responseから登録source名を取得する。

    Args:
        oikb_url: OIKBのbase URL。

    Returns:
        登録されたsource名の昇順list。

    Raises:
        TypeError: OIKB health responseの形式が不正な場合。
        HTTPError: OIKBがHTTP errorを返した場合。
        URLError: OIKBへ接続できない場合。
    """
    with urlopen(f"{oikb_url.rstrip('/')}/health", timeout=60) as response:
        payload = json.load(response)
    if not isinstance(payload, dict) or not isinstance(payload.get("sources"), dict):
        raise TypeError("OIKB health response must contain a sources object")

    source_names = {
        source["name"]
        for source in payload["sources"].values()
        if isinstance(source, dict)
        and isinstance(source.get("name"), str)
        and source["name"]
    }
    return sorted(source_names)


def trigger_sync(oikb_url: str, oikb_api_key: str, source_name: str) -> None:
    """指定したOIKB sourceの同期を非同期にtriggerする。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        source_name: OIKB設定上のsource名。

    Returns:
        なし。

    Raises:
        ValueError: OIKBがtrigger成功を返さない場合。
        HTTPError: OIKBがHTTP errorを返した場合。
        URLError: OIKBへ接続できない場合。

    Side Effects:
        OIKBの同期処理を開始する。
    """
    encoded_name = quote(source_name, safe="")
    payload = request_json(
        "POST",
        f"{oikb_url.rstrip('/')}/sync/{encoded_name}",
        oikb_api_key,
    )
    if not isinstance(payload, dict) or payload.get("triggered") is not True:
        raise ValueError(f"OIKB did not trigger source: {source_name}")


def trigger_all_syncs(oikb_url: str, oikb_api_key: str) -> int:
    """OIKBに登録された全sourceの同期をtriggerする。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。

    Returns:
        triggerしたsource数。

    Raises:
        TypeError: OIKB responseの形式が不正な場合。
        ValueError: OIKBがtrigger成功を返さない場合。
        HTTPError: OIKBがHTTP errorを返した場合。
        URLError: OIKBへ接続できない場合。

    Side Effects:
        OIKBに登録された各sourceの同期処理を開始する。
    """
    source_names = discover_source_names(oikb_url)
    for source_name in source_names:
        trigger_sync(oikb_url, oikb_api_key, source_name)
        LOGGER.info("OIKB同期をtriggerしました: source=%s", source_name)
    return len(source_names)


def run_scheduler(oikb_url: str, oikb_api_key: str, interval_seconds: int) -> None:
    """指定間隔でOIKBの全sourceを継続的にtriggerする。

    Args:
        oikb_url: OIKBのbase URL。
        oikb_api_key: OIKB API key。
        interval_seconds: 同期trigger間隔の秒数。

    Returns:
        なし。processを停止するまで継続する。

    Side Effects:
        各周期でOIKBの同期処理を開始し、周期の間sleepする。
    """
    while True:
        cycle_started_at = time.perf_counter()
        try:
            count = trigger_all_syncs(oikb_url, oikb_api_key)
            LOGGER.info("同期trigger完了: sources=%d", count)
        except (
            HTTPError,
            URLError,
            TypeError,
            ValueError,
            json.JSONDecodeError,
        ) as error:
            LOGGER.error("同期triggerに失敗しました: %s", error)
        LOGGER.info("周期処理時間: %.3f秒", time.perf_counter() - cycle_started_at)
        time.sleep(interval_seconds)


def build_parser() -> argparse.ArgumentParser:
    """command line option parserを作成する。

    Args:
        なし。

    Returns:
        OIKB trigger script用ArgumentParser。
    """
    parser = argparse.ArgumentParser(
        description="OIKBに登録された全sourceの同期を定期的にtriggerします。",
    )
    parser.add_argument(
        "--oikb-url",
        default=os.environ.get("OIKB_URL", "http://localhost:32001"),
    )
    parser.add_argument("--oikb-api-key", default=os.environ.get("OIKB_API_KEY"))
    parser.add_argument(
        "--interval-seconds",
        type=int,
        default=int(os.environ.get("OIKB_TRIGGER_INTERVAL_SECONDS", "3600")),
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="1回だけ同期をtriggerして終了します。",
    )
    return parser


def main(argv: Sequence[str]) -> int:
    """OIKB定期同期triggerのcommand line処理を実行する。

    Args:
        argv: プログラム名を含むcommand line引数。

    Returns:
        正常終了時は0、設定または通信error時は1、不正な引数では2。

    Side Effects:
        OIKBの同期をtriggerし、実行時間をlogへ記録する。
    """
    started_at = time.perf_counter()
    parser = build_parser()
    args = parser.parse_args(argv[1:])
    if not args.oikb_api_key:
        parser.error("--oikb-api-keyまたはOIKB_API_KEYが必要です")
    if args.interval_seconds <= 0:
        parser.error("--interval-secondsは1以上で指定してください")

    try:
        if args.once:
            count = trigger_all_syncs(args.oikb_url, args.oikb_api_key)
            LOGGER.info("同期trigger完了: sources=%d", count)
        else:
            run_scheduler(args.oikb_url, args.oikb_api_key, args.interval_seconds)
        return 0
    except KeyboardInterrupt:
        LOGGER.info("停止要求を受け付けました")
        return 0
    except (HTTPError, URLError, TypeError, ValueError, json.JSONDecodeError) as error:
        LOGGER.error("同期triggerに失敗しました: %s", error)
        return 1
    finally:
        LOGGER.info("処理時間: %.3f秒", time.perf_counter() - started_at)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    raise SystemExit(main(sys.argv))
