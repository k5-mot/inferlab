from __future__ import annotations

from connectors.http_json import HttpJsonConnector


class BookStackConnector(HttpJsonConnector):
    """BookStack REST APIをMarkdown pageへ変換するconnector。"""
