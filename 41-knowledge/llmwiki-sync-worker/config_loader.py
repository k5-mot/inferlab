from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

import yaml


ENV_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")


def load_config(path: Path) -> dict[str, Any]:
    """YAML設定を読み込み、環境変数展開後のdictを返す。

    Args:
        path: config.yamlのpath。

    Returns:
        設定dict。

    Raises:
        FileNotFoundError: 設定fileが存在しない場合。
        yaml.YAMLError: YAML parseに失敗した場合。
    """

    raw_config = yaml.safe_load(path.read_text(encoding="utf-8"))
    return expand_env(raw_config)


def expand_env(value: Any) -> Any:
    """設定値内の`${VAR}`または`${VAR:-default}`を再帰的に展開する。

    Args:
        value: 展開対象の任意値。

    Returns:
        環境変数展開後の値。
    """

    if isinstance(value, dict):
        return {key: expand_env(item) for key, item in value.items()}
    if isinstance(value, list):
        return [expand_env(item) for item in value]
    if isinstance(value, str):
        return ENV_RE.sub(lambda match: os.getenv(match.group(1), match.group(2) or ""), value)
    return value
