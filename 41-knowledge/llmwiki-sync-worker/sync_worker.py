#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

from config_loader import load_config
from connectors.base import to_bool, to_int
from web import SyncWorkerWebServer
from worker import SyncWorker


def sleep_between_runs(interval_seconds: int) -> bool:
    """次回実行まで待機する。

    Args:
        interval_seconds: 待機秒数。0以下なら継続しない。

    Returns:
        待機した場合はTrue、終了すべき場合はFalse。
    """

    if interval_seconds <= 0:
        return False
    time.sleep(interval_seconds)
    return True


def maybe_start_web(config: dict[str, object], worker: SyncWorker) -> None:
    """設定に応じてWebUI serverを開始する。

    Args:
        config: 展開済み設定dict。
        worker: 操作対象worker。

    Returns:
        None。

    Side Effects:
        WebUIが有効な場合にHTTP server threadを開始する。
    """

    web_config = config.get("web", {})
    if not isinstance(web_config, dict) or not to_bool(web_config.get("enabled", False)):
        return
    host = str(web_config.get("host", "0.0.0.0"))
    port = to_int(web_config.get("port", 8090), 8090)
    SyncWorkerWebServer(host, port, worker).start_background()


def main() -> int:
    """sync-workerのentrypoint。

    Args:
        None。

    Returns:
        process exit code。
    """

    config_path = Path(os.getenv("SYNC_CONFIG_PATH", "/config/config.yaml"))
    config = load_config(config_path)
    worker = SyncWorker(config)
    maybe_start_web(config, worker)
    while True:
        worker.run_once()
        if not sleep_between_runs(worker.interval_seconds()):
            return 0


if __name__ == "__main__":
    sys.exit(main())
