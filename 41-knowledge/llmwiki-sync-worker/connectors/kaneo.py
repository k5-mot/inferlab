from __future__ import annotations

from connectors.http_json import HttpJsonConnector


class KaneoConnector(HttpJsonConnector):
    """Kaneo REST APIをMarkdown pageへ変換するconnector。"""
