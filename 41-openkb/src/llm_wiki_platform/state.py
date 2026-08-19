"""SQLiteを利用したrun、checkpoint、document状態の永続化。"""

from __future__ import annotations

import json
import sqlite3
import threading
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


class StateStore:
    """パイプライン状態をSQLiteへ保存する。"""

    def __init__(self, database_path: Path) -> None:
        """StateStoreを初期化する。

        Args:
            database_path: SQLite database path。

        Returns:
            なし。

        Side Effects:
            databaseと親directoryを作成する。
        """
        self._database_path = database_path
        self._lock = threading.Lock()
        self._database_path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        """外部keyを有効化したSQLite接続を生成する。

        Returns:
            row accessを有効化したSQLite接続。
        """
        connection = sqlite3.connect(self._database_path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    def _initialize(self) -> None:
        """必要なtableとindexを作成する。

        Returns:
            なし。

        Side Effects:
            database schemaを更新する。
        """
        with self._connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS job_runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_key TEXT NOT NULL,
                    trigger TEXT NOT NULL,
                    status TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    finished_at TEXT,
                    detail TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_job_runs_key_started
                    ON job_runs(job_key, started_at DESC);
                CREATE TABLE IF NOT EXISTS checkpoints (
                    source TEXT PRIMARY KEY,
                    value TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS documents (
                    source_id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    normalized_path TEXT NOT NULL,
                    raw_path TEXT,
                    state TEXT NOT NULL,
                    last_seen TEXT NOT NULL,
                    updated_at TEXT
                );
                CREATE TABLE IF NOT EXISTS publish_mappings (
                    openkb_id TEXT PRIMARY KEY,
                    bookstack_page_id INTEGER NOT NULL,
                    bookstack_book_id INTEGER NOT NULL,
                    last_published_hash TEXT NOT NULL,
                    published_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS openkb_staging (
                    source_id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    normalized_path TEXT NOT NULL,
                    raw_path TEXT NOT NULL,
                    staged_at TEXT NOT NULL
                );
                """
            )

    def start_run(self, job_key: str, trigger: str) -> int:
        """job runをrunning状態で記録する。

        Args:
            job_key: jobの一意な分類key。
            trigger: scheduleまたはmanualなどの起動理由。

        Returns:
            作成したrun ID。
        """
        started_at = datetime.now(UTC).isoformat()
        with self._lock, self._connect() as connection:
            cursor = connection.execute(
                "INSERT INTO job_runs(job_key, trigger, status, started_at) VALUES (?, ?, ?, ?)",
                (job_key, trigger, "running", started_at),
            )
            run_id = cursor.lastrowid
        if run_id is None:
            raise RuntimeError("run IDを取得できませんでした")
        return run_id

    def finish_run(self, run_id: int, status: str, detail: dict[str, Any]) -> None:
        """job runへ終了状態と結果を記録する。

        Args:
            run_id: 更新対象run ID。
            status: `succeeded`または`failed`。
            detail: JSON化可能な実行結果。

        Returns:
            なし。
        """
        finished_at = datetime.now(UTC).isoformat()
        with self._lock, self._connect() as connection:
            connection.execute(
                "UPDATE job_runs SET status = ?, finished_at = ?, detail = ? WHERE id = ?",
                (status, finished_at, json.dumps(detail, ensure_ascii=False), run_id),
            )

    def list_runs(self, limit: int = 100) -> list[dict[str, Any]]:
        """新しい順にjob runを取得する。

        Args:
            limit: 最大取得件数。

        Returns:
            run情報のlist。
        """
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM job_runs ORDER BY id DESC LIMIT ?", (limit,)
            ).fetchall()
        return [dict(row) for row in rows]

    def get_checkpoint(self, source: str) -> str | None:
        """sourceのcheckpointを取得する。

        Args:
            source: source名。

        Returns:
            保存値。未登録ならNone。
        """
        with self._connect() as connection:
            row = connection.execute(
                "SELECT value FROM checkpoints WHERE source = ?", (source,)
            ).fetchone()
        return None if row is None else str(row["value"])

    def set_checkpoint(self, source: str, value: str) -> None:
        """sourceのcheckpointを更新する。

        Args:
            source: source名。
            value: Connector固有のcheckpoint値。

        Returns:
            なし。
        """
        updated_at = datetime.now(UTC).isoformat()
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                INSERT INTO checkpoints(source, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(source) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at
                """,
                (source, value, updated_at),
            )

    def get_document(self, source_id: str) -> dict[str, Any] | None:
        """Source IDに対応するdocument状態を取得する。

        Args:
            source_id: 永続的なSource ID。

        Returns:
            document状態。未登録ならNone。
        """
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM documents WHERE source_id = ?", (source_id,)
            ).fetchone()
        return None if row is None else dict(row)

    def upsert_document(
        self,
        *,
        source_id: str,
        source: str,
        content_hash: str,
        normalized_path: Path,
        raw_path: Path | None,
        state: str,
        last_seen: datetime,
        updated_at: datetime | None,
    ) -> None:
        """documentの最新状態を追加または更新する。

        Args:
            source_id: 永続的なSource ID。
            source: source名。
            content_hash: canonical contentのSHA-256。
            normalized_path: 正規化済みdocument path。
            raw_path: raw content path。存在しなければNone。
            state: activeまたはunavailable。
            last_seen: sourceで最後に確認した時刻。
            updated_at: source側の最終更新時刻。

        Returns:
            なし。
        """
        values = (
            source_id,
            source,
            content_hash,
            str(normalized_path),
            None if raw_path is None else str(raw_path),
            state,
            last_seen.isoformat(),
            None if updated_at is None else updated_at.isoformat(),
        )
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                INSERT INTO documents(
                    source_id, source, content_hash, normalized_path, raw_path,
                    state, last_seen, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    source = excluded.source,
                    content_hash = excluded.content_hash,
                    normalized_path = excluded.normalized_path,
                    raw_path = excluded.raw_path,
                    state = excluded.state,
                    last_seen = excluded.last_seen,
                    updated_at = excluded.updated_at
                """,
                values,
            )

    def list_documents(self, source: str | None = None) -> list[dict[str, Any]]:
        """保存済みdocument状態を列挙する。

        Args:
            source: 絞り込むsource名。省略時は全source。

        Returns:
            Source ID順のdocument状態。
        """
        with self._connect() as connection:
            if source is None:
                rows = connection.execute("SELECT * FROM documents ORDER BY source_id").fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM documents WHERE source = ? ORDER BY source_id", (source,)
                ).fetchall()
        return [dict(row) for row in rows]

    def mark_documents_unavailable(self, source: str, source_ids: set[str]) -> int:
        """sourceで消失したdocumentをunavailableへ更新する。

        Args:
            source: 対象source名。
            source_ids: unavailableへ変更するSource ID。

        Returns:
            更新件数。
        """
        if not source_ids:
            return 0
        with self._lock, self._connect() as connection:
            changed = 0
            for source_id in source_ids:
                cursor = connection.execute(
                    """
                    UPDATE documents SET state = 'unavailable'
                    WHERE source = ? AND source_id = ? AND state != 'unavailable'
                    """,
                    (source, source_id),
                )
                changed += cursor.rowcount
        return changed

    def stage_openkb_document(
        self,
        *,
        source_id: str,
        source: str,
        content_hash: str,
        normalized_path: Path,
        raw_path: Path,
    ) -> None:
        """変更documentを次回OpenKB compile対象へ登録する。

        Args:
            source_id: 永続的なSource ID。
            source: source名。
            content_hash: staging対象versionのSHA-256。
            normalized_path: Canonical Markdown path。
            raw_path: 原file path。

        Returns:
            なし。
        """
        staged_at = datetime.now(UTC).isoformat()
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                INSERT INTO openkb_staging(
                    source_id, source, content_hash, normalized_path, raw_path, staged_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id) DO UPDATE SET
                    source = excluded.source,
                    content_hash = excluded.content_hash,
                    normalized_path = excluded.normalized_path,
                    raw_path = excluded.raw_path,
                    staged_at = excluded.staged_at
                """,
                (
                    source_id,
                    source,
                    content_hash,
                    str(normalized_path),
                    str(raw_path),
                    staged_at,
                ),
            )

    def list_openkb_staging(self) -> list[dict[str, Any]]:
        """次回compileでOpenKBへ反映するdocumentを列挙する。

        Returns:
            staged_at順のstaging item。
        """
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM openkb_staging ORDER BY staged_at, source_id"
            ).fetchall()
        return [dict(row) for row in rows]

    def complete_openkb_staging(self, source_id: str, content_hash: str) -> bool:
        """反映済みversionと一致するstaging itemだけを削除する。

        Args:
            source_id: 反映済みSource ID。
            content_hash: OpenKBへ送信したversionのSHA-256。

        Returns:
            staging itemを削除できた場合はTrue。
        """
        with self._lock, self._connect() as connection:
            cursor = connection.execute(
                "DELETE FROM openkb_staging WHERE source_id = ? AND content_hash = ?",
                (source_id, content_hash),
            )
        return cursor.rowcount == 1

    def get_publish_mapping(self, openkb_id: str) -> dict[str, Any] | None:
        """OpenKB page IDに対応するBookStack mappingを取得する。

        Args:
            openkb_id: Generated Wiki内のstable page ID。

        Returns:
            mapping情報。未登録ならNone。
        """
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM publish_mappings WHERE openkb_id = ?", (openkb_id,)
            ).fetchone()
        return None if row is None else dict(row)

    def list_publish_mappings(self) -> list[dict[str, Any]]:
        """すべてのBookStack publish mappingを列挙する。

        Returns:
            OpenKB page ID順のmapping一覧。
        """
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM publish_mappings ORDER BY openkb_id"
            ).fetchall()
        return [dict(row) for row in rows]

    def upsert_publish_mapping(
        self,
        *,
        openkb_id: str,
        bookstack_page_id: int,
        bookstack_book_id: int,
        content_hash: str,
    ) -> None:
        """OpenKB pageとBookStack pageの対応を保存する。

        Args:
            openkb_id: Generated Wiki内のstable page ID。
            bookstack_page_id: BookStack page ID。
            bookstack_book_id: 所属BookStack book ID。
            content_hash: 最後に公開したMarkdownのSHA-256。

        Returns:
            なし。
        """
        published_at = datetime.now(UTC).isoformat()
        with self._lock, self._connect() as connection:
            connection.execute(
                """
                INSERT INTO publish_mappings(
                    openkb_id, bookstack_page_id, bookstack_book_id,
                    last_published_hash, published_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(openkb_id) DO UPDATE SET
                    bookstack_page_id = excluded.bookstack_page_id,
                    bookstack_book_id = excluded.bookstack_book_id,
                    last_published_hash = excluded.last_published_hash,
                    published_at = excluded.published_at
                """,
                (
                    openkb_id,
                    bookstack_page_id,
                    bookstack_book_id,
                    content_hash,
                    published_at,
                ),
            )


def decode_run_detail(run: dict[str, Any]) -> dict[str, Any]:
    """SQLite上のJSON文字列をAPI向けobjectへ戻す。

    Args:
        run: `StateStore.list_runs`が返すrun情報。

    Returns:
        detailをdecodeしたcopy。
    """
    decoded = dict(run)
    detail = decoded.get("detail")
    if isinstance(detail, str):
        decoded["detail"] = json.loads(detail)
    return decoded
