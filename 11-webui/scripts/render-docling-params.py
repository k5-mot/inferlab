#!/usr/bin/env python3
"""Open WebUI 向けの DOCLING_PARAMS JSON を生成する。"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def load_params(config_path: Path) -> dict[str, Any]:
    """Docling パラメータファイルを読み込む。

    Args:
        config_path: JSON 形式の Docling パラメータファイル。

    Returns:
        読み込んだ Docling パラメータ。

    Raises:
        OSError: ファイルの読み込みに失敗した場合。
        json.JSONDecodeError: JSON として解釈できない場合。
    """
    with config_path.open(encoding="utf-8") as params_file:
        return json.load(params_file)


def normalize_params(params: dict[str, Any]) -> dict[str, Any]:
    """Open WebUI の multipart 送信に合う形へ Docling パラメータを正規化する。

    Args:
        params: Docling に渡すパラメータ。

    Returns:
        トップレベルの dict 値だけを JSON 文字列へ変換したパラメータ。
    """
    return {
        key: json.dumps(value, ensure_ascii=False) if isinstance(value, dict) else value
        for key, value in params.items()
    }


def render_params(params: dict[str, Any]) -> str:
    """DOCLING_PARAMS 環境変数へ設定する JSON 文字列を組み立てる。

    Args:
        params: 正規化済みの Docling パラメータ。

    Returns:
        空白を含まない JSON 文字列。
    """
    return json.dumps(params, ensure_ascii=False, separators=(",", ":"))


def main(argv: list[str]) -> int:
    """コマンドライン引数から設定ファイルを読み、DOCLING_PARAMS を標準出力へ出す。

    Args:
        argv: プログラム名と Docling パラメータファイルのパス。

    Returns:
        正常終了時は 0、不正な引数の場合は 2。

    Side Effects:
        生成した JSON 文字列またはエラーメッセージを標準ストリームへ出力する。
    """
    if len(argv) != 2:
        print("usage: render-docling-params.py CONFIG_PATH", file=sys.stderr)
        return 2

    params = load_params(Path(argv[1]))
    print(render_params(normalize_params(params)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
