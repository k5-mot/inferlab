from pathlib import Path


path = Path("/usr/local/lib/python3.12/site-packages/oikb/cli.py")
source = path.read_text()
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

path.write_text(source.replace(old, new))
