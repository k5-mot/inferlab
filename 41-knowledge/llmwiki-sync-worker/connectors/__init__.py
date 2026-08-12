from __future__ import annotations

from typing import Any

from connectors.base import SourceConnector, SyncError
from connectors.bookstack import BookStackConnector
from connectors.couchdb import CouchDbConnector
from connectors.gitlab import GitLabConnector
from connectors.kaneo import KaneoConnector
from connectors.nextcloud import NextcloudConnector
from connectors.zulip import ZulipConnector
from http_client import HttpClient


CONNECTOR_CLASSES: dict[str, type[SourceConnector]] = {
    "couchdb": CouchDbConnector,
    "nextcloud": NextcloudConnector,
    "nextcloud_webdav": NextcloudConnector,
    "bookstack": BookStackConnector,
    "zulip": ZulipConnector,
    "kaneo": KaneoConnector,
    "gitlab": GitLabConnector,
}


def create_connector(source_config: dict[str, Any], http_client: HttpClient) -> SourceConnector:
    """source typeに対応するconnectorを作る。

    Args:
        source_config: config.yaml内のsource定義。
        http_client: HTTP request実行に使うclient。

    Returns:
        SourceConnector実装。

    Raises:
        SyncError: 未対応source typeが指定された場合。
    """

    source_type = str(source_config.get("type", ""))
    connector_class = CONNECTOR_CLASSES.get(source_type)
    if connector_class is None:
        raise SyncError(f"unsupported source type: {source_type}")
    return connector_class(source_config, http_client)
