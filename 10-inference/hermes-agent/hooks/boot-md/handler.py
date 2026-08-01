"""ゲートウェイ起動時に初期化スクリプトを実行する。"""

import logging
import os
import subprocess
import threading
from pathlib import Path

from hermes_constants import get_hermes_home

logger = logging.getLogger("hooks.boot-md")

BOOTSTRAP_SCRIPT = Path(__file__).with_name("bootstrap.sh")
BOOTSTRAP_TIMEOUT_SECONDS = 900


def _trim_output(output: str | bytes | None) -> str:
    """ログに残す外部コマンド出力を読みやすい長さに整える。

    引数:
        output: subprocess から得た標準出力または標準エラー出力。

    戻り値:
        前後の空白を除去し、長すぎる場合は末尾側を残した文字列。
    """
    if output is None:
        return ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
    trimmed = output.strip()
    if len(trimmed) <= 4000:
        return trimmed
    return trimmed[-4000:]


def _run_bootstrap() -> None:
    """初期化スクリプトを一度だけ実行する。

    引数:
        なし。

    戻り値:
        None。成功時と失敗時の詳細は hook のログに出力される。

    副作用:
        起動後に使うスキル定義の導入を実行する。
    """
    if not BOOTSTRAP_SCRIPT.exists():
        logger.warning("boot-md bootstrap script is missing: %s", BOOTSTRAP_SCRIPT)
        return

    env = os.environ.copy()
    hermes_home = str(get_hermes_home())
    env["HERMES_HOME"] = hermes_home
    env["HOME"] = hermes_home
    env.setdefault("npm_config_prefix", f"{hermes_home}/.local")
    env.setdefault("UV_LINK_MODE", "copy")

    try:
        result = subprocess.run(
            ["bash", str(BOOTSTRAP_SCRIPT)],
            cwd=hermes_home,
            env=env,
            capture_output=True,
            text=True,
            timeout=BOOTSTRAP_TIMEOUT_SECONDS,
            check=False,
        )
        stdout = _trim_output(result.stdout)
        stderr = _trim_output(result.stderr)
        if result.returncode == 0:
            if stdout:
                logger.info("boot-md bootstrap completed: %s", stdout)
            else:
                logger.info("boot-md bootstrap completed")
        else:
            logger.error(
                "boot-md bootstrap failed with exit code %s\nstdout:\n%s\nstderr:\n%s",
                result.returncode,
                stdout,
                stderr,
            )
    except subprocess.TimeoutExpired as e:
        logger.error(
            "boot-md bootstrap timed out after %s seconds\nstdout:\n%s\nstderr:\n%s",
            BOOTSTRAP_TIMEOUT_SECONDS,
            _trim_output(e.stdout or ""),
            _trim_output(e.stderr or ""),
        )
    except Exception as e:
        logger.exception("boot-md bootstrap failed unexpectedly: %s", e)


async def handle(event_type: str, context: dict) -> None:
    """gateway:startup イベントを受け取り、初期化スクリプトを非同期に実行する。

    引数:
        event_type: Hermes gateway hook から渡されるイベント名。
        context: Hermes gateway hook から渡されるイベントコンテキスト。

    戻り値:
        None。初期化スクリプトが存在しない場合はログに警告を出して終了する。

    副作用:
        初期化スクリプトを処理する daemon thread を起動する。
    """
    logger.info("Running boot-md bootstrap for %s", event_type)

    # 起動処理を bootstrap の完了待ちで止めないため、バックグラウンドで実行する。
    thread = threading.Thread(
        target=_run_bootstrap,
        name="boot-md",
        daemon=True,
    )
    thread.start()
