#!/usr/bin/env python3
"""QwenPawのDiscordとLiteLLM設定を起動前に反映する。"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import tempfile
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any

LOGGER = logging.getLogger(__name__)
MODEL_IDS = (
    "google/gemma4:31b",
    "openai/gpt-oss:20b",
    "nvidia/nemotron-3-nano:30b",
)


def _required_env(name: str) -> str:
    """必須環境変数を取得する。

    Args:
        name: 取得する環境変数名。

    Returns:
        前後の空白を除いた環境変数値。

    Raises:
        ValueError: 環境変数が未設定または空の場合。
    """
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"Required environment variable is empty: {name}")
    return value


def _load_json(path: Path) -> dict[str, Any]:
    """既存のJSON objectを読み込む。

    Args:
        path: 読み込むJSON fileのpath。

    Returns:
        JSON object。fileが存在しない場合は空のdict。

    Raises:
        TypeError: JSON rootがobjectでない場合。
        OSError: fileを読み込めない場合。
        json.JSONDecodeError: JSONが不正な場合。
    """
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as source:
        value = json.load(source)
    if not isinstance(value, dict):
        raise TypeError(f"JSON root must be an object: {path}")
    return value


def _write_json(path: Path, value: dict[str, Any], mode: int = 0o600) -> None:
    """JSON objectを同一filesystem内でatomicに置換する。

    Args:
        path: 書き込み先のpath。
        value: 保存するJSON object。
        mode: 保存fileへ設定するpermission。

    Returns:
        None。

    Raises:
        OSError: directory作成、書き込み、または置換に失敗した場合。

    Side Effects:
        指定pathのfileを置換する。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as temporary:
        json.dump(value, temporary, ensure_ascii=False, indent=2)
        temporary.write("\n")
        temporary_path = Path(temporary.name)
    temporary_path.chmod(mode)
    temporary_path.replace(path)


def _configure_discord(agent: dict[str, Any], bot_token: str) -> None:
    """既存agent設定へConsoleとDiscord channelを反映する。

    Args:
        agent: 更新対象のagent設定。関数内で更新される。
        bot_token: Discord bot token。

    Returns:
        None。

    Side Effects:
        引数のagent dictを更新する。
    """
    channels = agent.setdefault("channels", {})
    if not isinstance(channels, dict):
        raise TypeError("agent.json channels must be an object")

    console = channels.setdefault("console", {})
    if not isinstance(console, dict):
        raise TypeError("agent.json channels.console must be an object")
    console["enabled"] = True

    discord = channels.setdefault("discord", {})
    if not isinstance(discord, dict):
        raise TypeError("agent.json channels.discord must be an object")
    discord.update(
        {
            "enabled": True,
            "bot_token": bot_token,
            "require_mention": True,
            "accept_bot_messages": False,
            "streaming_enabled": True,
        },
    )
    agent["language"] = "en"
    agent["system_prompt_files"] = ["AGENTS.md", "SOUL.md", "PROFILE.md"]


def _litellm_provider(api_key: str) -> dict[str, Any]:
    """LiteLLMのOpenAI互換provider設定を生成する。

    Args:
        api_key: LiteLLM master key。

    Returns:
        QwenPaw v2.1.0向けcustom provider設定。
    """
    models = [
        {
            "id": model_id,
            "name": f"{model_id} via LiteLLM",
            "supports_multimodal": False,
            "supports_image": False,
            "supports_video": False,
            "max_tokens": 8192,
            "max_input_length": 131072,
            "max_input_length_configured": True,
        }
        for model_id in MODEL_IDS
    ]
    return {
        "id": "litellm",
        "name": "LiteLLM",
        "base_url": "http://litellm:4000/v1",
        "api_key": api_key,
        "chat_model": "OpenAIChatModel",
        "models": [],
        "extra_models": models,
        "is_custom": True,
        "require_api_key": True,
        "support_model_discovery": True,
        "support_connection_check": False,
        "custom_headers": {
            "langfuse_trace_name": "QwenPaw",
            "langfuse_generation_name": "QwenPaw",
            "langfuse_tags": '["qwenpaw"]',
        },
    }


def configure(working_dir: Path, secret_dir: Path) -> None:
    """QwenPaw runtimeへDiscordとLiteLLM設定を反映する。

    Args:
        working_dir: QwenPaw working directory。
        secret_dir: QwenPaw secret directory。

    Returns:
        None。

    Raises:
        ValueError: 必須環境変数が不正な場合。
        TypeError: 既存JSON構造が不正な場合。
        OSError: 設定fileの読み書きに失敗した場合。

    Side Effects:
        agent、provider、active modelのJSON fileを更新する。
    """
    bot_token = _required_env("QWENPAW_DISCORD_BOT_TOKEN")
    api_key = _required_env("LITELLM_MASTER_KEY")

    agent_path = working_dir / "workspaces" / "default" / "agent.json"
    agent = _load_json(agent_path)
    if not agent:
        raise ValueError(f"QwenPaw initialization did not create: {agent_path}")
    _configure_discord(agent, bot_token)
    _write_json(agent_path, agent)

    providers_dir = secret_dir / "providers"
    _write_json(
        providers_dir / "custom" / "litellm.json",
        _litellm_provider(api_key),
    )
    _write_json(
        providers_dir / "active_model.json",
        {"provider_id": "litellm", "model": MODEL_IDS[0]},
    )


def main(argv: Sequence[str]) -> int:
    """QwenPaw設定commandを実行する。

    Args:
        argv: program名を含むcommand line引数。

    Returns:
        成功時は0、設定失敗時は1。
    """
    started_at = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv[1:])
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    try:
        configure(
            Path(os.environ.get("QWENPAW_WORKING_DIR", "/app/working")),
            Path(os.environ.get("QWENPAW_SECRET_DIR", "/app/working.secret")),
        )
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        LOGGER.error("QwenPaw configuration failed: %s", error)
        return 1
    finally:
        LOGGER.info(
            "Elapsed time: %.3f seconds",
            time.perf_counter() - started_at,
        )

    LOGGER.info(
        "QwenPaw configuration completed: models=%d discord=enabled",
        len(MODEL_IDS),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
