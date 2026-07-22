"""ゲートウェイ起動時に BOOT.md のチェックリストを実行する。"""

import logging
import threading

from hermes_constants import get_hermes_home

logger = logging.getLogger("hooks.boot-md")

BOOT_FILE = get_hermes_home() / "BOOT.md"


def _build_prompt(content: str) -> str:
    """BOOT.md の内容を一回限りの起動チェック用プロンプトに変換する。

    引数:
        content: BOOT.md から読み込んだ Markdown 形式の指示。

    戻り値:
        起動チェック用エージェントに渡すプロンプト文字列。
    """
    return (
        "You are running a startup boot checklist. Follow the instructions "
        "below exactly.\n\n"
        "---\n"
        f"{content}\n"
        "---\n\n"
        "Execute each instruction. Put any user-facing summary in your "
        "final response — the hook delivers it to the configured channel "
        "(e.g. Discord or Slack); you do not send messages yourself.\n"
        "If nothing needs attention and there is nothing to report, reply "
        "with ONLY: [SILENT]"
    )


def _run_boot_agent(content: str) -> None:
    """一回限りのエージェントを起動して BOOT.md のチェックリストを実行する。

    引数:
        content: BOOT.md から読み込んだ Markdown 形式の指示。

    戻り値:
        None。結果は hook のログに出力される。

    副作用:
        Hermes のエージェントを別スレッドで起動し、指示に応じて外部コマンドを実行する。
    """
    try:
        from gateway.run import _resolve_gateway_model, _resolve_runtime_agent_kwargs
        from run_agent import AIAgent

        agent = AIAgent(
            model=_resolve_gateway_model(),
            **_resolve_runtime_agent_kwargs(),
            platform="gateway",
            quiet_mode=True,
            skip_context_files=True,
            skip_memory=True,
            max_iterations=20,
        )
        result = agent.run_conversation(_build_prompt(content))
        response = (result.get("final_response", "") or "").strip()
        if response.upper() not in {"[SILENT]", "SILENT", "NO_REPLY", "NO REPLY"}:
            logger.info("boot-md completed: %s", response[:200])
        else:
            logger.info("boot-md completed (nothing to report)")
    except Exception as e:
        logger.error("boot-md agent failed: %s", e)


async def handle(event_type: str, context: dict) -> None:
    """gateway:startup イベントを受け取り、BOOT.md があれば非同期に実行する。

    引数:
        event_type: Hermes gateway hook から渡されるイベント名。
        context: Hermes gateway hook から渡されるイベントコンテキスト。

    戻り値:
        None。BOOT.md が存在しない場合や空の場合は何もしない。

    副作用:
        BOOT.md の内容を処理する daemon thread を起動する。
    """
    if not BOOT_FILE.exists():
        return
    content = BOOT_FILE.read_text(encoding="utf-8").strip()
    if not content:
        return

    logger.info("Running BOOT.md (%d chars)", len(content))

    # 起動処理を BOOT.md の完了待ちで止めないため、バックグラウンドで実行する。
    thread = threading.Thread(
        target=_run_boot_agent,
        args=(content,),
        name="boot-md",
        daemon=True,
    )
    thread.start()
