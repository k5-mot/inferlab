from pathlib import Path

import oikb.cli as cli_module


def _load_cli_path() -> Path:
    """patch対象のcli.pyをimport結果から解決する。

    Args:
        なし。

    Returns:
        Path: install済みのoikb.cli module file pathです。

    Raises:
        RuntimeError: module file pathを解決できない場合に送出します。
    """
    if cli_module.__file__ is None:
        raise RuntimeError("oikb.cli module path was not found")
    return Path(cli_module.__file__)


def _patch_source(source: str) -> str:
    """Open WebUI client作成時にtimeout環境変数を反映する。

    Args:
        source: patch前のoikb.cli source codeです。

    Returns:
        str: timeout設定を追加したsource codeです。

    Raises:
        RuntimeError: 想定したpatch対象が存在しない場合に送出します。
    """
    old = """def _make_client(url: str | None, token: str | None):
    \"\"\"Create an OikbClient from resolved config.\"\"\"
    from oikb.client import OikbClient

    return OikbClient(
        base_url=resolve_url(url),
        token=resolve_token(token),
    )
"""
    new = """def _make_client(url: str | None, token: str | None):
    \"\"\"Open WebUI clientを設定値から作成する。

    Args:
        url: Open WebUIのbase URLです。
        token: Open WebUI API keyです。

    Returns:
        OikbClient: timeout設定を反映したOpen WebUI clientです。
    \"\"\"
    from oikb.client import OikbClient

    timeout = float(os.environ.get("OIKB_OPENWEBUI_TIMEOUT", "120"))
    return OikbClient(
        base_url=resolve_url(url),
        token=resolve_token(token),
        timeout=timeout,
    )
"""

    if old not in source:
        raise RuntimeError("oikb.client timeout patch target was not found")

    return source.replace(old, new)


path = _load_cli_path()
source = path.read_text()
path.write_text(_patch_source(source))
