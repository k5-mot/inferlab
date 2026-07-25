"""OIKB の OpenWebUI API timeout を環境変数で上書きする。

OIKB 0.3.6 は OpenWebUI へ接続する HTTP client の timeout が 120 秒固定で、
大きい PDF を同期すると OpenWebUI 側の応答待ち中に timeout することがある。
この module は Python 起動時に読み込まれる sitecustomize として使い、
OIKB 本体を直接変更せずに timeout を延長できるようにする。
"""

from __future__ import annotations

import os
from typing import Any

from oikb.client import OikbClient

_ORIGINAL_INIT = OikbClient.__init__


def _parse_timeout(value: str | None) -> float | None:
    """timeout 環境変数を秒数へ変換する。

    Args:
        value: timeout 秒数を表す文字列。未指定の場合は None。

    Returns:
        変換できた timeout 秒数。未指定または空文字の場合は None。

    Raises:
        ValueError: 数値へ変換できない値、または 0 以下の値が指定された場合。
    """
    if value is None or value.strip() == "":
        return None

    timeout = float(value)
    if timeout <= 0:
        raise ValueError("OIKB_OPENWEBUI_TIMEOUT must be greater than 0")
    return timeout


def _patched_init(
    self: OikbClient,
    base_url: str,
    token: str,
    timeout: float = 120.0,
    *args: Any,
    **kwargs: Any,
) -> None:
    """OIKB client の timeout を環境変数で差し替えて初期化する。

    Args:
        self: 初期化対象の OikbClient instance。
        base_url: OpenWebUI の base URL。
        token: OpenWebUI API token。
        timeout: OIKB 本体が渡す既定 timeout 秒数。
        *args: 将来の OIKB 変更に備えた追加 positional arguments。
        **kwargs: 将来の OIKB 変更に備えた追加 keyword arguments。

    Returns:
        None。

    Raises:
        ValueError: OIKB_OPENWEBUI_TIMEOUT が不正な値の場合。

    Side Effects:
        OIKB_OPENWEBUI_TIMEOUT が指定されている場合、OpenWebUI API 呼び出しの
        timeout をその値へ変更する。
    """
    configured_timeout = _parse_timeout(os.environ.get("OIKB_OPENWEBUI_TIMEOUT"))
    if configured_timeout is not None:
        timeout = configured_timeout

    _ORIGINAL_INIT(self, base_url, token, timeout=timeout, *args, **kwargs)


if not getattr(OikbClient, "_inferlab_timeout_patch_applied", False):
    OikbClient.__init__ = _patched_init
    OikbClient._inferlab_timeout_patch_applied = True
