from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def read_state(path: Path) -> dict[str, Any]:
    """checkpoint fileを読み込む。

    Args:
        path: checkpoint JSON fileのpath。

    Returns:
        checkpoint dict。存在しない場合は空dict。
    """

    if not path.exists():
        return {"sources": {}}
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"sources": {}}
    if "sources" not in state:
        return {"sources": {}, "legacy_couchdb": state}
    return state


def read_json(path: Path, default: Any) -> Any:
    """JSON fileを読み込む。

    Args:
        path: 読み込み先path。
        default: fileがない、またはJSONが壊れている場合の戻り値。

    Returns:
        JSON decode後の値、またはdefault。
    """

    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return default


def write_json(path: Path, value: dict[str, Any]) -> None:
    """JSON fileへatomicに近い形で値を書き込む。

    Args:
        path: 書き込み先path。
        value: JSON化するdict。

    Returns:
        None。

    Side Effects:
        file system上のJSON fileを更新する。
    """

    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_suffix(path.suffix + ".tmp")
    temp_path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temp_path.replace(path)
