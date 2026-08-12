from __future__ import annotations

from typing import Any

from connectors.base import (
    SourceConnector,
    SyncBatch,
    WikiPage,
    auth_headers,
    build_markdown,
    build_url,
    digest_json,
    extract_items,
    pick_first,
    redact_value,
    slugify,
    to_bool,
    to_int,
)


class HttpJsonConnector(SourceConnector):
    """JSON REST endpointをMarkdown pageへ変換するconnector。"""

    def sync(self, state: dict[str, Any]) -> SyncBatch:
        """設定されたJSON endpointを取得して同期batchを作る。

        Args:
            state: endpoint item別hashを含むcheckpoint。

        Returns:
            JSON REST由来のMarkdown pageと更新後checkpoint。

        Raises:
            MissingCredentialError: 認証情報が不足している場合。
            urllib.error.URLError: REST endpoint接続に失敗した場合。
        """

        base_url = str(self.source_config["base_url"]).rstrip("/")
        verify_tls = to_bool(self.source_config.get("verify_tls", True))
        headers = auth_headers(self.source_config.get("auth", {}))
        next_state = self.clone_state(state)
        next_state.setdefault("items", {})
        pages: list[WikiPage] = []
        skipped = 0
        for endpoint in self.source_config.get("endpoints", []):
            endpoint_pages, endpoint_skipped = self._sync_endpoint(base_url, headers, verify_tls, endpoint, next_state)
            pages.extend(endpoint_pages)
            skipped += endpoint_skipped
        return SyncBatch(pages=pages, state=next_state, ingest_paths=[self.source_slug], skipped=skipped)

    def check_status(self) -> dict[str, Any]:
        """JSON REST sourceの接続状態を確認する。

        Args:
            None。

        Returns:
            source状態を表すdict。

        Raises:
            MissingCredentialError: 認証情報が不足している場合。
            urllib.error.URLError: REST endpoint接続に失敗した場合。
        """

        endpoint = self.source_config.get("endpoints", [{}])[0]
        url = build_url(str(self.source_config["base_url"]), str(endpoint.get("path", "/")), endpoint.get("query", {}))
        data = self.http_client.get_json(url, headers=auth_headers(self.source_config.get("auth", {})), verify_tls=to_bool(self.source_config.get("verify_tls", True)))
        items = extract_items(data, endpoint.get("items_path", ""))
        return {"source": self.name, "status": "ok", "items_seen": len(items), "endpoint": endpoint.get("name")}

    def _sync_endpoint(
        self,
        base_url: str,
        headers: dict[str, str],
        verify_tls: bool,
        endpoint: dict[str, Any],
        next_state: dict[str, Any],
    ) -> tuple[list[WikiPage], int]:
        """JSON REST endpoint 1件を同期pageへ変換する。

        Args:
            base_url: source base URL。
            headers: 認証済みHTTP header。
            verify_tls: HTTPS証明書検証を有効化するか。
            endpoint: endpoint設定。
            next_state: 更新中checkpoint。

        Returns:
            page一覧とskip件数。
        """

        endpoint_name = str(endpoint["name"])
        endpoint_slug = slugify(endpoint_name)
        url = build_url(base_url, str(endpoint["path"]), endpoint.get("query", {}))
        data = self.http_client.get_json(url, headers=headers, verify_tls=verify_tls)
        items = extract_items(data, endpoint.get("items_path", ""))
        max_items = to_int(endpoint.get("max_items", len(items)), len(items))
        selected_items = items[:max_items]
        pages: list[WikiPage] = []
        skipped = 0
        index_rows: list[dict[str, Any]] = []
        endpoint_changed = False
        for item in selected_items:
            item_pages, item_skipped, item_index = self._sync_item(endpoint, endpoint_slug, item, next_state)
            pages.extend(item_pages)
            skipped += item_skipped
            index_rows.append(item_index)
            endpoint_changed = endpoint_changed or bool(item_pages)
        if endpoint_changed:
            pages.append(self._build_index_page(endpoint_name, endpoint_slug, index_rows))
        return pages, skipped

    def _sync_item(
        self,
        endpoint: dict[str, Any],
        endpoint_slug: str,
        item: Any,
        next_state: dict[str, Any],
    ) -> tuple[list[WikiPage], int, dict[str, Any]]:
        """JSON item 1件を同期pageへ変換する。

        Args:
            endpoint: endpoint設定。
            endpoint_slug: endpoint名のslug。
            item: JSON item。
            next_state: 更新中checkpoint。

        Returns:
            page一覧、skip件数、index用row。
        """

        safe_item = redact_value(item)
        item_id = pick_first(safe_item, endpoint.get("id_fields", ["id"])) or digest_json(safe_item)[:12]
        title = pick_first(safe_item, endpoint.get("title_fields", ["name", "title", "id"])) or str(item_id)
        state_key = f"{endpoint_slug}:{item_id}"
        item_digest = digest_json(safe_item)
        item_path = f"{self.source_slug}/{endpoint_slug}/{slugify(str(item_id))}"
        index_row = {"id": item_id, "title": title, "path": item_path}
        if next_state["items"].get(state_key) == item_digest:
            return [], 1, index_row
        content = build_markdown(
            source=self.name,
            source_type=str(self.source_config.get("type", "http_json")),
            title=str(title),
            item_id=str(item_id),
            status="generated",
            summary=f"{self.name} `{endpoint['name']}` endpointから取得したitem。",
            payload={"endpoint": endpoint["name"], "item": safe_item},
        )
        next_state["items"][state_key] = item_digest
        return [WikiPage(path=item_path, content=content, digest=item_digest)], 0, index_row

    def _build_index_page(self, endpoint_name: str, endpoint_slug: str, index_rows: list[dict[str, Any]]) -> WikiPage:
        """endpoint index pageを作る。

        Args:
            endpoint_name: endpoint名。
            endpoint_slug: endpoint名のslug。
            index_rows: indexに含めるitem概要。

        Returns:
            endpoint index page。
        """

        return WikiPage(
            path=f"{self.source_slug}/{endpoint_slug}/index",
            content=build_markdown(
                source=self.name,
                source_type=str(self.source_config.get("type", "http_json")),
                title=f"{self.name} {endpoint_name}",
                item_id=endpoint_name,
                status="generated",
                summary=f"{self.name} `{endpoint_name}` endpointの同期index。",
                payload={"endpoint": endpoint_name, "items": index_rows},
            ),
            digest=digest_json(index_rows),
        )
