"""Zulip channel/topicをthread documentへ集約するConnector。"""

from __future__ import annotations

import hashlib
from collections import defaultdict
from datetime import UTC, datetime
from typing import Any

from llm_wiki_platform.config import SourceConfig
from llm_wiki_platform.connectors.base import (
    ConnectorBatch,
    RetryingHttpClient,
    SourceConnector,
    decode_json_object,
    json_bytes,
    require_mapping,
)
from llm_wiki_platform.models import Authority, KnowledgeDocument, SourceObject


class ZulipConnector(SourceConnector):
    """Zulip messageをchannel/topic単位でKnowledgeDocument化する。"""

    name = "zulip"

    def __init__(self, config: SourceConfig, http: RetryingHttpClient) -> None:
        """ZulipConnectorを初期化する。

        Args:
            config: Zulip source設定。
            http: Basic認証設定済みHTTP client。

        Returns:
            なし。
        """
        self._config = config
        self._http = http
        self._channels = tuple(config.include.get("channels", ()))

    async def discover(self, checkpoint: str | None) -> ConnectorBatch:
        """checkpointより新しいmessageをtopic単位へ集約する。

        Args:
            checkpoint: 前回処理した最大message ID。

        Returns:
            差分thread一覧。履歴全件ではないため不完全snapshot。
        """
        minimum_id = int(checkpoint) if checkpoint else 0
        stream_response = await self._http.request("GET", "/api/v1/streams")
        stream_payload = require_mapping(stream_response.json(), "streams response")
        streams = _mapping_list(stream_payload.get("streams", []), "streams")
        stream_ids = {str(stream.get("name")): int(stream["stream_id"]) for stream in streams}
        objects: list[SourceObject] = []
        for channel in self._channels:
            if channel not in stream_ids:
                raise ValueError(f"設定されたZulip channelが見つかりません: {channel}")
            narrow = [["stream", channel]]
            response = await self._http.request(
                "GET",
                "/api/v1/messages",
                params={
                    "anchor": "newest",
                    "num_before": "1000",
                    "num_after": "0",
                    "apply_markdown": "false",
                    "narrow": json_bytes(narrow).decode("utf-8"),
                },
            )
            payload = require_mapping(response.json(), "messages response")
            messages = _mapping_list(payload.get("messages", []), "messages")
            changed_topics = {
                str(message.get("subject") or message.get("topic") or "(no topic)")
                for message in messages
                if int(message["id"]) > minimum_id
            }
            changed_messages = [
                message
                for message in messages
                if str(message.get("subject") or message.get("topic") or "(no topic)")
                in changed_topics
            ]
            objects.extend(self._group_threads(channel, changed_messages))
        return ConnectorBatch(objects=tuple(objects), complete_snapshot=False)

    def _group_threads(self, channel: str, messages: list[dict[str, Any]]) -> list[SourceObject]:
        """messageをtopic単位へgroup化する。

        Args:
            channel: Zulip channel名。
            messages: channel内の差分message。

        Returns:
            topicごとのSource Object。
        """
        grouped: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
        for message in messages:
            grouped[str(message.get("subject") or message.get("topic") or "(no topic)")].append(
                message
            )
        objects: list[SourceObject] = []
        for topic, topic_messages in grouped.items():
            topic_messages.sort(key=lambda message: int(message["id"]))
            last_timestamp = max(int(message["timestamp"]) for message in topic_messages)
            topic_key = hashlib.sha256(f"{channel}\0{topic}".encode()).hexdigest()[:20]
            objects.append(
                SourceObject(
                    id=f"zulip:{channel}:topic:{topic_key}",
                    source=self.name,
                    source_type="thread",
                    source_instance=str(self._config.base_url.host),
                    source_id=topic_key,
                    title=topic,
                    url=None,
                    updated_at=datetime.fromtimestamp(last_timestamp, tz=UTC),
                    metadata={"channel": channel, "topic": topic, "messages": topic_messages},
                )
            )
        return objects

    async def fetch(self, source: SourceObject) -> bytes:
        """discover時に取得したthread messageをraw JSONへ変換する。

        Args:
            source: thread Source Object。

        Returns:
            channel、topic、messagesを含むJSON bytes。
        """
        return json_bytes(
            {
                "channel": source.metadata["channel"],
                "topic": source.metadata["topic"],
                "messages": source.metadata["messages"],
            }
        )

    def normalize(self, source: SourceObject, raw: bytes) -> KnowledgeDocument:
        """Zulip threadを時系列Markdownへ正規化する。

        Args:
            source: thread Source Object。
            raw: fetchで生成したJSON bytes。

        Returns:
            discussion authorityのKnowledgeDocument。
        """
        payload = decode_json_object(raw)
        messages = _mapping_list(payload.get("messages", []), "messages")
        lines = [
            f"Channel: {payload['channel']}",
            f"Topic: {payload['topic']}",
            "",
        ]
        authors: set[str] = set()
        source_message_ids: list[str] = []
        for message in messages:
            timestamp = datetime.fromtimestamp(int(message["timestamp"]), tz=UTC)
            sender = str(
                message.get("sender_full_name") or message.get("sender_email") or "Unknown"
            )
            authors.add(sender)
            source_message_ids.append(str(message["id"]))
            lines.extend(
                [
                    f"## {timestamp.isoformat()}",
                    "",
                    f"{sender}:",
                    "",
                    str(message.get("content", "")),
                    "",
                ]
            )
        return KnowledgeDocument(
            id=source.id,
            source=self.name,
            source_type=source.source_type,
            source_instance=source.source_instance,
            source_id=source.source_id,
            title=source.title,
            content="\n".join(lines),
            updated_at=source.updated_at,
            authors=tuple(sorted(authors)),
            scope={"type": "channel", "id": str(payload["channel"])},
            authority=Authority.DISCUSSION,
            metadata={"message_ids": source_message_ids},
        )

    def checkpoint(self, objects: tuple[SourceObject, ...], previous: str | None) -> str | None:
        """batch内の最大message IDをcheckpointにする。

        Args:
            objects: 処理に成功したthread一覧。
            previous: 前回最大message ID。

        Returns:
            新しい最大message ID。messageがなければprevious。
        """
        message_ids = [
            int(message["id"])
            for source in objects
            for message in _mapping_list(source.metadata.get("messages", []), "messages")
        ]
        return str(max(message_ids)) if message_ids else previous


def _mapping_list(value: object, context: str) -> list[dict[str, Any]]:
    """外部API値をdict listとして検証する。

    Args:
        value: 検証対象。
        context: errorへ含める項目名。

    Returns:
        dictへcopyしたlist。

    Raises:
        ValueError: listではない場合。
    """
    if not isinstance(value, list):
        raise ValueError(f"{context}はlistである必要があります")
    return [dict(require_mapping(item, context)) for item in value]
