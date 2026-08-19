"""外部Source System向けConnector実装。"""

from llm_wiki_platform.connectors.base import ConnectorBatch, SourceConnector
from llm_wiki_platform.connectors.bookstack import BookStackConnector
from llm_wiki_platform.connectors.gitlab import GitLabConnector
from llm_wiki_platform.connectors.kaneo import KaneoConnector
from llm_wiki_platform.connectors.nextcloud import NextcloudConnector
from llm_wiki_platform.connectors.zulip import ZulipConnector

__all__ = [
    "BookStackConnector",
    "ConnectorBatch",
    "GitLabConnector",
    "KaneoConnector",
    "NextcloudConnector",
    "SourceConnector",
    "ZulipConnector",
]
