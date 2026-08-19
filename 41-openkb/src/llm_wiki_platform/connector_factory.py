"""config.yamlとcredential環境変数からConnectorを構築する。"""

from __future__ import annotations

from collections.abc import Mapping

import httpx

from llm_wiki_platform.config import AppConfig, resolve_credential
from llm_wiki_platform.connectors import (
    BookStackConnector,
    GitLabConnector,
    KaneoConnector,
    NextcloudConnector,
    SourceConnector,
    ZulipConnector,
)
from llm_wiki_platform.connectors.base import RetryingHttpClient


class ConnectorRegistry:
    """構築済みConnectorとHTTP clientのlifecycleを管理する。"""

    def __init__(
        self,
        connectors: dict[str, SourceConnector],
        clients: list[httpx.AsyncClient],
    ) -> None:
        """ConnectorRegistryを初期化する。

        Args:
            connectors: source名とConnectorの対応。
            clients: 終了時にcloseするHTTP client。

        Returns:
            なし。
        """
        self.connectors = connectors
        self._clients = clients

    async def aclose(self) -> None:
        """Registryが所有するHTTP clientをすべてcloseする。

        Returns:
            なし。
        """
        for client in self._clients:
            await client.aclose()


def build_connector_registry(
    config: AppConfig,
    environ: Mapping[str, str],
) -> ConnectorRegistry:
    """有効sourceだけを設定済みConnectorへ変換する。

    Args:
        config: 検証済みapplication設定。
        environ: credential値を解決する環境変数。

    Returns:
        ConnectorとHTTP clientを所有するRegistry。
    """
    connectors: dict[str, SourceConnector] = {}
    clients: list[httpx.AsyncClient] = []
    for source_name, source_config in config.sources.items():
        if not source_config.enabled:
            continue
        effective = config.effective_ingest(source_name)
        credential = resolve_credential(source_config.credential, environ)
        headers: dict[str, str] = {}
        auth: httpx.Auth | None = None
        if source_name == "gitlab":
            headers["PRIVATE-TOKEN"] = credential["token"]
        elif source_name == "zulip":
            auth = httpx.BasicAuth(credential["email"], credential["api_key"])
        elif source_name == "nextcloud":
            auth = httpx.BasicAuth(credential["username"], credential["password"])
        elif source_name == "kaneo":
            headers["Authorization"] = f"Bearer {credential['token']}"
        client = httpx.AsyncClient(
            base_url=str(source_config.base_url),
            headers=headers,
            auth=auth,
            timeout=30,
        )
        clients.append(client)
        retrying = RetryingHttpClient(client, effective.retry, effective.rate_limit)
        if source_name == "gitlab":
            connectors[source_name] = GitLabConnector(source_config, retrying)
        elif source_name == "zulip":
            connectors[source_name] = ZulipConnector(source_config, retrying)
        elif source_name == "nextcloud":
            connectors[source_name] = NextcloudConnector(
                source_config, retrying, credential["username"]
            )
        elif source_name == "kaneo":
            connectors[source_name] = KaneoConnector(source_config, retrying)

    if config.bookstack.ingest.enabled:
        effective = config.effective_ingest("bookstack")
        credential = resolve_credential(config.bookstack.reader_credential, environ)
        client = httpx.AsyncClient(
            base_url=str(config.bookstack.base_url),
            headers={
                "Authorization": f"Token {credential['token_id']}:{credential['token_secret']}"
            },
            timeout=30,
        )
        clients.append(client)
        retrying = RetryingHttpClient(client, effective.retry, effective.rate_limit)
        connectors["bookstack"] = BookStackConnector(config.bookstack, retrying)
    return ConnectorRegistry(connectors, clients)
