from __future__ import annotations

from connectors.http_json import HttpJsonConnector


class ZulipConnector(HttpJsonConnector):
    """Zulip REST APIをMarkdown pageへ変換するconnector。"""
