"""LLM Wiki Platform管理APIのcommand line entry point。"""

from __future__ import annotations

import argparse
import logging
import sys
import time
from collections.abc import Sequence
from pathlib import Path

import uvicorn

from llm_wiki_platform.app import create_app

LOGGER = logging.getLogger(__name__)


def build_parser() -> argparse.ArgumentParser:
    """command line引数parserを構築する。

    Returns:
        config path、listen host、portを受け取るparser。
    """
    parser = argparse.ArgumentParser(description="LLM Wiki Platform API")
    parser.add_argument("--config", type=Path, default=Path("config.yaml"))
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    return parser


def main(argv: Sequence[str]) -> int:
    """設定をfail-fastで読み、uvicorn serverを起動する。

    Args:
        argv: program名を含むcommand line引数。

    Returns:
        正常終了時は0。

    Side Effects:
        listen socketを開き、終了までAPI serverを実行する。
    """
    started = time.perf_counter()
    arguments = build_parser().parse_args(argv[1:])
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        application = create_app(arguments.config)
        uvicorn.run(application, host=arguments.host, port=arguments.port)
        return 0
    finally:
        LOGGER.info("process実行時間: %.3f秒", time.perf_counter() - started)


def run() -> None:
    """console scriptからmainを呼び出して終了codeを反映する。

    Returns:
        なし。常にSystemExitを送出する。

    Raises:
        SystemExit: mainの終了codeをprocessへ返すため常に発生する。
    """
    raise SystemExit(main(sys.argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
