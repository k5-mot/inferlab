"""Nextcloud WebDAV向けConnector。"""

from __future__ import annotations

from collections import deque
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from pathlib import PurePosixPath
from urllib.parse import unquote, urljoin, urlsplit
from xml.etree import ElementTree

from llm_wiki_platform.config import SourceConfig
from llm_wiki_platform.connectors.base import (
    ConnectorBatch,
    RetryingHttpClient,
    SourceConnector,
)
from llm_wiki_platform.models import Authority, KnowledgeDocument, SourceObject

_DAV_NAMESPACE = "DAV:"
_OWNCLOUD_NAMESPACE = "http://owncloud.org/ns"
_TEXT_EXTENSIONS = frozenset({".md", ".markdown", ".txt", ".csv", ".html", ".htm"})
_PROPFIND_BODY = """<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:getlastmodified />
    <d:getcontenttype />
    <d:getetag />
    <d:resourcetype />
    <oc:fileid />
  </d:prop>
</d:propfind>
"""


class NextcloudConnector(SourceConnector):
    """allowlist directory配下の対応fileをWebDAVで取得する。"""

    name = "nextcloud"

    def __init__(
        self,
        config: SourceConfig,
        http: RetryingHttpClient,
        username: str,
    ) -> None:
        """NextcloudConnectorを初期化する。

        Args:
            config: Nextcloud source設定。
            http: Basic認証設定済みHTTP client。
            username: WebDAV files rootに使用するuser ID。

        Returns:
            なし。
        """
        self._config = config
        self._http = http
        self._username = username
        self._include_paths = tuple(config.include.get("paths", ()))
        self._exclude_paths = tuple(config.exclude.get("paths", ()))
        self._dav_prefix = f"/remote.php/dav/files/{username}"

    async def discover(self, checkpoint: str | None) -> ConnectorBatch:
        """allowlist配下をbreadth-firstで走査しfileを列挙する。

        Args:
            checkpoint: 前回取得位置。完全snapshotのためfilterには使用しない。

        Returns:
            対象fileの完全snapshot。
        """
        del checkpoint
        queue = deque(self._normalize_remote_path(path) for path in self._include_paths)
        visited: set[str] = set()
        objects: list[SourceObject] = []
        while queue:
            remote_directory = queue.popleft()
            if remote_directory in visited or self._is_excluded(remote_directory):
                continue
            visited.add(remote_directory)
            request_path = f"{self._dav_prefix}{remote_directory}"
            response = await self._http.request(
                "PROPFIND",
                request_path,
                headers={"Depth": "1", "Content-Type": "application/xml"},
                content=_PROPFIND_BODY,
            )
            for entry in _parse_multistatus(response.content):
                remote_path = self._remote_path(str(entry["href"]))
                if remote_path == remote_directory or self._is_excluded(remote_path):
                    continue
                if bool(entry["is_collection"]):
                    queue.append(remote_path)
                    continue
                if PurePosixPath(remote_path).suffix.lower() not in {
                    ".pdf",
                    ".docx",
                    ".pptx",
                    ".xlsx",
                    ".xls",
                    ".md",
                    ".markdown",
                    ".txt",
                    ".html",
                    ".htm",
                    ".csv",
                }:
                    continue
                objects.append(self._source_object(remote_path, entry))
        return ConnectorBatch(objects=tuple(objects), complete_snapshot=True)

    def _source_object(self, remote_path: str, entry: dict[str, object]) -> SourceObject:
        """WebDAV propertyをSource Objectへ変換する。

        Args:
            remote_path: user files rootからのpath。
            entry: parse済みWebDAV property。

        Returns:
            fileのSource Object。
        """
        file_id = str(entry.get("file_id") or remote_path)
        scope_id = (
            PurePosixPath(remote_path).parts[1]
            if len(PurePosixPath(remote_path).parts) > 1
            else "root"
        )
        modified = entry.get("last_modified")
        updated_at = parsedate_to_datetime(modified) if isinstance(modified, str) else None
        href = str(entry["href"])
        return SourceObject(
            id=f"nextcloud:{scope_id}:file:{file_id}",
            source=self.name,
            source_type="file",
            source_instance=str(self._config.base_url.host),
            source_id=file_id,
            title=PurePosixPath(remote_path).name,
            url=urljoin(str(self._config.base_url), href),
            updated_at=updated_at,
            metadata={
                "href": href,
                "remote_path": remote_path,
                "etag": entry.get("etag"),
                "content_type": entry.get("content_type"),
                "extension": PurePosixPath(remote_path).suffix.lower(),
            },
        )

    def _normalize_remote_path(self, path: str) -> str:
        """設定pathを先頭slash付きPOSIX pathへ正規化する。

        Args:
            path: config.yaml上のincludeまたはexclude path。

        Returns:
            trailing slashを除いた絶対形式path。
        """
        normalized = "/" + path.strip("/")
        return normalized if normalized != "/" else ""

    def _remote_path(self, href: str) -> str:
        """WebDAV hrefをuser files root相対pathへ変換する。

        Args:
            href: multistatus responseのhref。

        Returns:
            先頭slash付きremote path。

        Raises:
            ValueError: hrefが設定userのfiles root外を指す場合。
        """
        decoded_path = unquote(urlsplit(href).path).rstrip("/")
        if not decoded_path.startswith(self._dav_prefix):
            raise ValueError(f"WebDAV hrefがfiles root外を指しています: {href}")
        relative = decoded_path.removeprefix(self._dav_prefix)
        return relative or ""

    def _is_excluded(self, remote_path: str) -> bool:
        """remote pathがexclude prefix配下か判定する。

        Args:
            remote_path: user files root相対path。

        Returns:
            exclude対象ならTrue。
        """
        for excluded in self._exclude_paths:
            prefix = self._normalize_remote_path(excluded)
            if remote_path == prefix or remote_path.startswith(prefix + "/"):
                return True
        return False

    async def fetch(self, source: SourceObject) -> bytes:
        """WebDAV GETでfile contentを取得する。

        Args:
            source: file Source Object。

        Returns:
            原file bytes。
        """
        response = await self._http.request("GET", str(source.metadata["href"]))
        return response.content

    def normalize(self, source: SourceObject, raw: bytes) -> KnowledgeDocument:
        """text fileは本文を保持し、binary fileはmetadata documentを生成する。

        Args:
            source: file Source Object。
            raw: 原file bytes。

        Returns:
            reference authorityのKnowledgeDocument。
        """
        extension = str(source.metadata["extension"])
        if extension in _TEXT_EXTENSIONS:
            content = raw.decode("utf-8", errors="replace")
            content_format = "markdown" if extension in {".md", ".markdown"} else "text"
        else:
            content = (
                f"Original binary document: {source.title}\n\n"
                "The original file is preserved in the Source Store and supplied to OpenKB "
                "at compile time."
            )
            content_format = "binary"
        remote_path = str(source.metadata["remote_path"])
        parts = PurePosixPath(remote_path).parts
        scope_id = parts[1] if len(parts) > 1 else "root"
        return KnowledgeDocument(
            id=source.id,
            source=self.name,
            source_type=source.source_type,
            source_instance=source.source_instance,
            source_id=source.source_id,
            title=source.title,
            content=content,
            content_format=content_format,
            url=source.url,
            updated_at=source.updated_at,
            scope={"type": "folder", "id": scope_id},
            authority=Authority.REFERENCE,
            metadata={
                "remote_path": remote_path,
                "etag": source.metadata.get("etag"),
                "content_type": source.metadata.get("content_type"),
            },
        )

    def checkpoint(self, objects: tuple[SourceObject, ...], previous: str | None) -> str | None:
        """完全snapshot取得時刻をcheckpointとして返す。

        Args:
            objects: 処理に成功したfile一覧。
            previous: 前回checkpoint。

        Returns:
            fileがあれば現在UTC時刻、なければprevious。
        """
        return datetime.now(UTC).isoformat() if objects else previous

    def raw_filename(self, source: SourceObject) -> str:
        """Nextcloud原fileのextensionを維持したfilenameを返す。

        Args:
            source: file Source Object。

        Returns:
            Source Store用filename。
        """
        return source.title


def _parse_multistatus(content: bytes) -> list[dict[str, object]]:
    """WebDAV multistatus XMLをproperty objectへ変換する。

    Args:
        content: PROPFIND response body。

    Returns:
        response要素ごとのproperty一覧。

    Raises:
        ElementTree.ParseError: XMLが不正な場合。
    """
    root = ElementTree.fromstring(content)
    entries: list[dict[str, object]] = []
    for response in root.findall(f"{{{_DAV_NAMESPACE}}}response"):
        href = response.findtext(f"{{{_DAV_NAMESPACE}}}href")
        prop = response.find(f"{{{_DAV_NAMESPACE}}}propstat/{{{_DAV_NAMESPACE}}}prop")
        if href is None or prop is None:
            continue
        resource_type = prop.find(f"{{{_DAV_NAMESPACE}}}resourcetype")
        is_collection = (
            resource_type is not None
            and resource_type.find(f"{{{_DAV_NAMESPACE}}}collection") is not None
        )
        entries.append(
            {
                "href": href,
                "is_collection": is_collection,
                "last_modified": prop.findtext(f"{{{_DAV_NAMESPACE}}}getlastmodified"),
                "content_type": prop.findtext(f"{{{_DAV_NAMESPACE}}}getcontenttype"),
                "etag": prop.findtext(f"{{{_DAV_NAMESPACE}}}getetag"),
                "file_id": prop.findtext(f"{{{_OWNCLOUD_NAMESPACE}}}fileid"),
            }
        )
    return entries
