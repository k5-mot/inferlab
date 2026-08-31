"""GitLab Issue、Merge Request、Wiki向けConnector。"""

from __future__ import annotations

from datetime import UTC
from typing import Any
from urllib.parse import quote

from llm_wiki_platform.config import SourceConfig
from llm_wiki_platform.connectors.base import (
    ConnectorBatch,
    RetryingHttpClient,
    SourceConnector,
    decode_json_object,
    json_bytes,
    parse_datetime,
    require_mapping,
)
from llm_wiki_platform.models import Authority, KnowledgeDocument, SourceObject


class GitLabConnector(SourceConnector):
    """GitLab projectからIssue、Merge Request、Wikiを取得する。"""

    name = "gitlab"

    def __init__(self, config: SourceConfig, http: RetryingHttpClient) -> None:
        """GitLabConnectorを初期化する。

        Args:
            config: GitLab source設定。
            http: retryとrate limit設定済みHTTP client。

        Returns:
            なし。
        """
        self._config = config
        self._http = http
        self._projects = tuple(config.include.get("projects", ()))
        configured_types = config.include.get("types", ["issues", "merge_requests", "wikis"])
        self._types = frozenset(configured_types)

    async def discover(self, checkpoint: str | None) -> ConnectorBatch:
        """設定されたprojectの取得対象を全件列挙する。

        Args:
            checkpoint: 前回取得位置。削除検出のため現実装ではfilterに使用しない。

        Returns:
            完全snapshotのSource Object一覧。
        """
        del checkpoint
        objects: list[SourceObject] = []
        for project in self._projects:
            encoded_project = quote(project, safe="")
            if "issues" in self._types:
                issues = await self._paginated(
                    f"/api/v4/projects/{encoded_project}/issues",
                    {"scope": "all", "state": "all", "order_by": "updated_at"},
                )
                objects.extend(self._issue_objects(project, issues))
            if "merge_requests" in self._types:
                merge_requests = await self._paginated(
                    f"/api/v4/projects/{encoded_project}/merge_requests",
                    {"scope": "all", "state": "all", "order_by": "updated_at"},
                )
                objects.extend(self._merge_request_objects(project, merge_requests))
            if "wikis" in self._types:
                wikis = await self._paginated(f"/api/v4/projects/{encoded_project}/wikis", {})
                objects.extend(self._wiki_objects(project, wikis))
        return ConnectorBatch(objects=tuple(objects), complete_snapshot=True)

    async def _paginated(self, path: str, params: dict[str, str]) -> list[dict[str, Any]]:
        """GitLab keysetではないpage paginationを最後まで取得する。

        Args:
            path: GitLab API path。
            params: page以外のquery parameter。

        Returns:
            各pageを連結したobject list。
        """
        items: list[dict[str, Any]] = []
        page = 1
        while page:
            response = await self._http.request(
                "GET", path, params=params | {"per_page": "100", "page": str(page)}
            )
            items.extend(_object_list(response.json(), path))
            next_page = response.headers.get("x-next-page", "")
            page = int(next_page) if next_page else 0
        return items

    def _issue_objects(self, project: str, issues: list[dict[str, Any]]) -> list[SourceObject]:
        """GitLab Issue responseをSource Objectへ変換する。

        Args:
            project: project path。
            issues: Issue API response。

        Returns:
            IssueのSource Object一覧。
        """
        return [self._object(project, "issue", issue) for issue in issues]

    def _merge_request_objects(
        self, project: str, merge_requests: list[dict[str, Any]]
    ) -> list[SourceObject]:
        """GitLab Merge Request responseをSource Objectへ変換する。

        Args:
            project: project path。
            merge_requests: Merge Request API response。

        Returns:
            Merge RequestのSource Object一覧。
        """
        return [
            self._object(project, "merge-request", merge_request)
            for merge_request in merge_requests
        ]

    def _object(self, project: str, object_type: str, item: dict[str, Any]) -> SourceObject:
        """IssueまたはMerge RequestのSource Objectを生成する。

        Args:
            project: project path。
            object_type: `issue`または`merge-request`。
            item: GitLab API item。

        Returns:
            変換後のSource Object。
        """
        iid = str(item["iid"])
        return SourceObject(
            id=f"gitlab:{project}:{object_type}:{iid}",
            source=self.name,
            source_type=object_type,
            source_instance=str(self._config.base_url.host),
            source_id=iid,
            title=str(item.get("title") or f"{object_type} {iid}"),
            url=_optional_string(item.get("web_url")),
            updated_at=parse_datetime(item.get("updated_at")),
            metadata={"project": project, "item": item},
        )

    def _wiki_objects(self, project: str, wikis: list[dict[str, Any]]) -> list[SourceObject]:
        """GitLab Wiki responseをSource Objectへ変換する。

        Args:
            project: project path。
            wikis: Project Wiki API response。

        Returns:
            Wiki pageのSource Object一覧。
        """
        objects: list[SourceObject] = []
        for wiki in wikis:
            slug = str(wiki["slug"])
            objects.append(
                SourceObject(
                    id=f"gitlab:{project}:wiki:{slug}",
                    source=self.name,
                    source_type="wiki",
                    source_instance=str(self._config.base_url.host),
                    source_id=slug,
                    title=str(wiki.get("title") or slug),
                    url=None,
                    updated_at=None,
                    metadata={"project": project, "item": wiki},
                )
            )
        return objects

    async def fetch(self, source: SourceObject) -> bytes:
        """GitLab object本体とdiscussionを取得する。

        Args:
            source: Issue、Merge Request、WikiのSource Object。

        Returns:
            object本体とnotesを含むJSON bytes。
        """
        project = quote(str(source.metadata["project"]), safe="")
        if source.source_type == "wiki":
            slug = quote(source.source_id, safe="")
            response = await self._http.request("GET", f"/api/v4/projects/{project}/wikis/{slug}")
            return json_bytes({"object": require_mapping(response.json(), "wiki"), "notes": []})
        resource = "issues" if source.source_type == "issue" else "merge_requests"
        base_path = f"/api/v4/projects/{project}/{resource}/{source.source_id}"
        detail_response = await self._http.request("GET", base_path)
        notes = await self._paginated(f"{base_path}/notes", {"sort": "asc"})
        return json_bytes(
            {"object": require_mapping(detail_response.json(), "object"), "notes": notes}
        )

    def normalize(self, source: SourceObject, raw: bytes) -> KnowledgeDocument:
        """GitLab objectとdiscussionをMarkdownへ正規化する。

        Args:
            source: 正規化対象。
            raw: fetchで取得したJSON bytes。

        Returns:
            operational authorityのKnowledgeDocument。
        """
        payload = decode_json_object(raw)
        item = require_mapping(payload.get("object"), "object")
        notes = _object_list(payload.get("notes", []), "notes")
        body = str(item.get("content") or item.get("description") or "")
        lines = [
            f"Project: {source.metadata['project']}",
            f"Type: {source.source_type}",
            f"State: {item.get('state', 'unknown')}",
            "",
            body,
        ]
        if notes:
            lines.extend(["", "## Discussion", ""])
            for note in notes:
                author = require_mapping(note.get("author", {}), "note.author")
                lines.extend(
                    [f"### {author.get('name', 'Unknown')}", "", str(note.get("body", "")), ""]
                )
        labels = item.get("labels", [])
        label_values = tuple(str(label) for label in labels) if isinstance(labels, list) else ()
        author = require_mapping(item.get("author", {}), "author")
        author_name = _optional_string(author.get("username"))
        return KnowledgeDocument(
            id=source.id,
            source=self.name,
            source_type=source.source_type,
            source_instance=source.source_instance,
            source_id=source.source_id,
            title=source.title,
            content="\n".join(lines),
            url=source.url,
            created_at=parse_datetime(item.get("created_at")),
            updated_at=parse_datetime(item.get("updated_at")) or source.updated_at,
            authors=() if author_name is None else (author_name,),
            labels=label_values,
            scope={"type": "project", "id": str(source.metadata["project"])},
            authority=Authority.OPERATIONAL,
            metadata={"gitlab_id": item.get("id"), "iid": item.get("iid")},
        )

    def checkpoint(self, objects: tuple[SourceObject, ...], previous: str | None) -> str | None:
        """最新updated_atをGitLab checkpointとして返す。

        Args:
            objects: 取得に成功したSource Object。
            previous: 前回checkpoint。

        Returns:
            最新updated_at。timestampがなければprevious。
        """
        timestamps = [item.updated_at for item in objects if item.updated_at is not None]
        return max(timestamps).astimezone(UTC).isoformat() if timestamps else previous


def _object_list(value: object, context: str) -> list[dict[str, Any]]:
    """外部API値をobject listとして検証する。

    Args:
        value: 検証対象。
        context: errorへ含める項目名。

    Returns:
        dictへcopyしたobject list。

    Raises:
        ValueError: listまたはobjectではない要素を含む場合。
    """
    if not isinstance(value, list):
        raise ValueError(f"{context}はlistである必要があります")
    return [dict(require_mapping(item, context)) for item in value]


def _optional_string(value: object) -> str | None:
    """外部API値をoptional stringへ変換する。

    Args:
        value: 変換対象。

    Returns:
        空ではない文字列。値がなければNone。
    """
    return value if isinstance(value, str) and value else None
