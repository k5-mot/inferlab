"""Kaneo project/task向けConnector。"""

from __future__ import annotations

from datetime import UTC
from typing import Any

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


class KaneoConnector(SourceConnector):
    """Kaneo taskとcommentをproject単位で取得する。"""

    name = "kaneo"

    def __init__(self, config: SourceConfig, http: RetryingHttpClient) -> None:
        """KaneoConnectorを初期化する。

        Args:
            config: Kaneo source設定。
            http: Bearer認証設定済みHTTP client。

        Returns:
            なし。
        """
        self._config = config
        self._http = http
        self._project_ids = tuple(config.include.get("projects", ()))
        self._workspace_ids = tuple(config.include.get("workspaces", ()))

    async def discover(self, checkpoint: str | None) -> ConnectorBatch:
        """対象projectのtaskを全件列挙する。

        Args:
            checkpoint: 前回取得時刻。削除検出のためfilterには使用しない。

        Returns:
            完全snapshotのtask一覧。
        """
        del checkpoint
        projects = await self._projects()
        objects: list[SourceObject] = []
        for project in projects:
            project_id = str(project["id"])
            response = await self._http.request("GET", f"/api/task/tasks/{project_id}")
            tasks = _extract_tasks(response.json())
            for task in tasks:
                task_id = str(task["id"])
                objects.append(
                    SourceObject(
                        id=f"kaneo:{project_id}:task:{task_id}",
                        source=self.name,
                        source_type="task",
                        source_instance=str(self._config.base_url.host),
                        source_id=task_id,
                        title=str(task.get("title") or f"Task {task_id}"),
                        url=None,
                        updated_at=parse_datetime(task.get("updatedAt")),
                        metadata={"project": project, "task": task},
                    )
                )
        return ConnectorBatch(objects=tuple(objects), complete_snapshot=True)

    async def _projects(self) -> list[dict[str, Any]]:
        """include設定からKaneo project一覧を解決する。

        Returns:
            project API互換objectの一覧。
        """
        projects: dict[str, dict[str, Any]] = {
            project_id: {"id": project_id, "name": project_id} for project_id in self._project_ids
        }
        for workspace_id in self._workspace_ids:
            response = await self._http.request(
                "GET", "/api/project", params={"workspaceId": workspace_id}
            )
            value = response.json()
            if not isinstance(value, list):
                raise ValueError("Kaneo project responseはlistである必要があります")
            for item in value:
                project = dict(require_mapping(item, "project"))
                projects[str(project["id"])] = project
        return list(projects.values())

    async def fetch(self, source: SourceObject) -> bytes:
        """task詳細とcommentを取得する。

        Args:
            source: task Source Object。

        Returns:
            task、project、commentsを含むJSON bytes。
        """
        detail_response = await self._http.request("GET", f"/api/task/{source.source_id}")
        comments_response = await self._http.request("GET", f"/api/comment/{source.source_id}")
        return json_bytes(
            {
                "project": source.metadata["project"],
                "task": require_mapping(detail_response.json(), "task"),
                "comments": comments_response.json(),
            }
        )

    def normalize(self, source: SourceObject, raw: bytes) -> KnowledgeDocument:
        """Kaneo taskをproject context付きMarkdownへ正規化する。

        Args:
            source: task Source Object。
            raw: fetchで取得したJSON bytes。

        Returns:
            operational authorityのKnowledgeDocument。
        """
        payload = decode_json_object(raw)
        project = require_mapping(payload.get("project"), "project")
        task = require_mapping(payload.get("task"), "task")
        comments_value = payload.get("comments", [])
        comments = (
            [dict(require_mapping(item, "comment")) for item in comments_value]
            if isinstance(comments_value, list)
            else []
        )
        lines = [
            f"Project: {project.get('name', project.get('id', 'Unknown'))}",
            f"Status: {task.get('status', task.get('columnId', 'Unknown'))}",
            f"Priority: {task.get('priority', 'Unknown')}",
            f"Due date: {task.get('dueDate', 'None')}",
            "",
            str(task.get("description") or ""),
        ]
        if comments:
            lines.extend(["", "## Discussion", ""])
            for comment in comments:
                author = comment.get("userName") or comment.get("authorName") or "Unknown"
                lines.extend([f"### {author}", "", str(comment.get("content", "")), ""])
        labels_value = task.get("labels", [])
        labels = (
            tuple(str(require_mapping(label, "label").get("name", "")) for label in labels_value)
            if isinstance(labels_value, list)
            else ()
        )
        assignee = task.get("assignee")
        assignee_name = str(require_mapping(assignee, "assignee").get("name")) if assignee else None
        return KnowledgeDocument(
            id=source.id,
            source=self.name,
            source_type=source.source_type,
            source_instance=source.source_instance,
            source_id=source.source_id,
            title=source.title,
            content="\n".join(lines),
            url=source.url,
            created_at=parse_datetime(task.get("createdAt")),
            updated_at=parse_datetime(task.get("updatedAt")) or source.updated_at,
            authors=() if assignee_name is None else (assignee_name,),
            labels=tuple(label for label in labels if label),
            scope={"type": "project", "id": str(project["id"])},
            authority=Authority.OPERATIONAL,
            metadata={"project_name": project.get("name")},
        )

    def checkpoint(self, objects: tuple[SourceObject, ...], previous: str | None) -> str | None:
        """最新task更新時刻をcheckpointとして返す。

        Args:
            objects: 処理に成功したtask一覧。
            previous: 前回checkpoint。

        Returns:
            最新updated_at。timestampがなければprevious。
        """
        timestamps = [item.updated_at for item in objects if item.updated_at is not None]
        return max(timestamps).astimezone(UTC).isoformat() if timestamps else previous


def _extract_tasks(value: object) -> list[dict[str, Any]]:
    """Kaneoのcolumn別responseからtask objectを再帰的に抽出する。

    Args:
        value: List Tasks API response。

    Returns:
        `id`と`title`を持つtask object一覧。
    """
    tasks: list[dict[str, Any]] = []
    if isinstance(value, list):
        for item in value:
            tasks.extend(_extract_tasks(item))
    elif isinstance(value, dict):
        if (
            "id" in value
            and "title" in value
            and ("description" in value or "priority" in value or "columnId" in value)
        ):
            tasks.append(dict(value))
        else:
            for nested in value.values():
                tasks.extend(_extract_tasks(nested))
    return tasks
