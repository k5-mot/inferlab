from __future__ import annotations

import urllib.parse
import xml.etree.ElementTree as ET
from typing import Any

from connectors.base import SourceConnector, SyncBatch, WikiPage, basic_auth_headers, build_markdown, digest_json, require_env, slugify, to_bool, to_int


class NextcloudConnector(SourceConnector):
    """Nextcloud WebDAV metadataをMarkdown pageへ変換するconnector。"""

    def sync(self, state: dict[str, Any]) -> SyncBatch:
        """Nextcloud WebDAV PROPFIND結果から同期batchを作る。

        Args:
            state: file path別hashを含むcheckpoint。

        Returns:
            Nextcloud由来のMarkdown pageと更新後checkpoint。

        Raises:
            MissingCredentialError: 認証情報が不足している場合。
            urllib.error.URLError: WebDAV接続に失敗した場合。
            xml.etree.ElementTree.ParseError: WebDAV response XMLがparseできない場合。
        """

        root_path = self._root_path()
        entries = self._entries(root_path)[: to_int(self.source_config.get("max_items", 50), 50)]
        next_state = self.clone_state(state)
        next_state.setdefault("items", {})
        pages: list[WikiPage] = []
        skipped = 0
        index_rows: list[dict[str, Any]] = []
        changed = False
        for entry in entries:
            item_id = entry["href"]
            title = entry.get("displayname") or item_id
            item_digest = digest_json(entry)
            index_rows.append({"id": item_id, "title": title, "type": entry.get("type")})
            if next_state["items"].get(item_id) == item_digest:
                skipped += 1
                continue
            pages.append(
                WikiPage(
                    path=f"{self.source_slug}/files/{slugify(item_id)}",
                    content=build_markdown(
                        source=self.name,
                        source_type="nextcloud_webdav",
                        title=str(title),
                        item_id=item_id,
                        status="generated",
                        summary=f"Nextcloud WebDAV `{root_path}` 配下のmetadata。",
                        payload={"entry": entry},
                    ),
                    digest=item_digest,
                )
            )
            next_state["items"][item_id] = item_digest
            changed = True
        if changed:
            pages.append(self._build_index_page(root_path, index_rows))
        return SyncBatch(pages=pages, state=next_state, ingest_paths=[self.source_slug], skipped=skipped)

    def check_status(self) -> dict[str, Any]:
        """Nextcloud WebDAVの接続状態を確認する。

        Args:
            None。

        Returns:
            Nextcloud状態を表すdict。

        Raises:
            MissingCredentialError: 認証情報が不足している場合。
            urllib.error.URLError: WebDAV接続に失敗した場合。
        """

        root_path = self._root_path()
        entries = self._entries(root_path, depth="0")
        return {"source": self.name, "status": "ok", "root_path": root_path, "items_seen": len(entries)}

    def _entries(self, root_path: str, *, depth: str | None = None) -> list[dict[str, Any]]:
        """WebDAV entry一覧を取得する。

        Args:
            root_path: WebDAV root path。
            depth: WebDAV Depth header。未指定なら設定値を使う。

        Returns:
            WebDAV metadata一覧。

        Raises:
            xml.etree.ElementTree.ParseError: WebDAV response XMLがparseできない場合。
        """

        username = require_env(str(self.source_config.get("username_env", "NEXTCLOUD_LLMWIKI_USER")))
        password = require_env(str(self.source_config.get("password_env", "NEXTCLOUD_LLMWIKI_PASSWORD")))
        base_url = str(self.source_config["base_url"]).rstrip("/")
        dav_path = f"/remote.php/dav/files/{urllib.parse.quote(username, safe='')}{urllib.parse.quote(root_path, safe='/')}"
        xml_body = self.http_client.propfind(
            f"{base_url}{dav_path}",
            headers=basic_auth_headers(username, password),
            depth=depth or str(self.source_config.get("depth", "1")),
            verify_tls=to_bool(self.source_config.get("verify_tls", True)),
        )
        return parse_webdav_entries(xml_body, root_path)

    def _root_path(self) -> str:
        """Nextcloud WebDAV root pathを返す。

        Args:
            None。

        Returns:
            先頭と末尾に`/`を持つpath。
        """

        root_path = str(self.source_config.get("root_path", "/")).strip()
        if root_path in {"", "/"}:
            return "/"
        return "/" + root_path.strip("/") + "/"

    def _build_index_page(self, root_path: str, index_rows: list[dict[str, Any]]) -> WikiPage:
        """Nextcloud file index pageを作る。

        Args:
            root_path: 同期root path。
            index_rows: indexに含めるfile概要。

        Returns:
            file index page。
        """

        return WikiPage(
            path=f"{self.source_slug}/files/index",
            content=build_markdown(
                source=self.name,
                source_type="nextcloud_webdav",
                title=f"{self.name} files",
                item_id=root_path,
                status="generated",
                summary="Nextcloud WebDAV metadataの同期index。",
                payload={"root_path": root_path, "items": index_rows},
            ),
            digest=digest_json(index_rows),
        )


def parse_webdav_entries(xml_body: bytes, root_path: str) -> list[dict[str, Any]]:
    """WebDAV multistatus XMLからfile metadata一覧を取り出す。

    Args:
        xml_body: PROPFIND response body。
        root_path: requestしたroot path。

    Returns:
        fileまたはdirectoryのmetadata一覧。

    Raises:
        xml.etree.ElementTree.ParseError: XML parseに失敗した場合。
    """

    root = ET.fromstring(xml_body)
    entries: list[dict[str, Any]] = []
    for response in root:
        if local_name(response.tag) != "response":
            continue
        entry = parse_webdav_response(response)
        if entry and entry.get("href") != root_path:
            entries.append(entry)
    return entries


def parse_webdav_response(response: ET.Element) -> dict[str, Any] | None:
    """WebDAV response要素をmetadata dictへ変換する。

    Args:
        response: WebDAV response XML要素。

    Returns:
        metadata dict。hrefがない場合はNone。
    """

    href = ""
    props: dict[str, Any] = {}
    for child in response.iter():
        name = local_name(child.tag)
        if name == "href" and child.text:
            href = urllib.parse.unquote(child.text)
        elif name in {"displayname", "getlastmodified", "getcontentlength", "getcontenttype"} and child.text:
            props[name] = child.text
        elif name == "collection":
            props["type"] = "directory"
    if not href:
        return None
    props.setdefault("type", "file")
    props["href"] = href
    return props


def local_name(tag: str) -> str:
    """XML tagからnamespaceを除いたlocal nameを返す。

    Args:
        tag: XML tag名。

    Returns:
        namespace除去後の名前。
    """

    return tag.rsplit("}", 1)[-1]
