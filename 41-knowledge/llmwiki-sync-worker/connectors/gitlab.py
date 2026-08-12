from __future__ import annotations

from connectors.http_json import HttpJsonConnector


class GitLabConnector(HttpJsonConnector):
    """GitLab REST APIをMarkdown pageへ変換するconnector。"""
