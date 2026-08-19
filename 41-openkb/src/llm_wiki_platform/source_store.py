"""raw、normalized、metadataを保持するCanonical Source Store。"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from llm_wiki_platform.models import ChangeKind, DocumentState, KnowledgeDocument
from llm_wiki_platform.state import StateStore

_SAFE_EXTENSION = re.compile(r"^\.[a-zA-Z0-9]{1,12}$")
_UNAVAILABLE_MARKER = "> **Source unavailable:** The original source is no longer available."


@dataclass(frozen=True, slots=True)
class StoredDocument:
    """Source Storeへの保存結果。"""

    document: KnowledgeDocument
    change: ChangeKind
    content_hash: str
    raw_path: Path
    normalized_path: Path
    metadata_path: Path


class SourceStore:
    """Canonical Documentとraw evidenceをfilesystemへ永続化する。"""

    def __init__(self, root: Path, state_store: StateStore) -> None:
        """SourceStoreを初期化する。

        Args:
            root: raw、normalized、metadata directoryのroot。
            state_store: document状態の保存先。

        Returns:
            なし。

        Side Effects:
            必要なdirectoryを作成する。
        """
        self._root = root
        self._state_store = state_store
        for directory in ("raw", "normalized", "metadata"):
            (root / directory).mkdir(parents=True, exist_ok=True)

    def store(
        self,
        document: KnowledgeDocument,
        raw: bytes,
        raw_filename: str,
    ) -> StoredDocument:
        """documentを保存しcontent hashから差分種別を判定する。

        Args:
            document: 正規化済みCanonical Document。
            raw: Source System由来のraw bytes。
            raw_filename: extension判定に使う元filename。

        Returns:
            pathと差分種別を含む保存結果。
        """
        normalized_content = document.render_markdown()
        hash_input = normalized_content.encode("utf-8")
        if document.content_format == "binary":
            hash_input += b"\0" + raw
        digest = hashlib.sha256(hash_input).hexdigest()
        previous = self._state_store.get_document(document.id)
        if previous is None:
            change = ChangeKind.NEW
        elif previous["content_hash"] == digest and previous["state"] == DocumentState.ACTIVE.value:
            change = ChangeKind.UNCHANGED
        else:
            change = ChangeKind.UPDATED

        key = hashlib.sha256(document.id.encode("utf-8")).hexdigest()[:24]
        extension = Path(raw_filename).suffix
        if not _SAFE_EXTENSION.fullmatch(extension):
            extension = ".bin"
        raw_path = self._root / "raw" / document.source / f"{key}{extension.lower()}"
        normalized_path = self._root / "normalized" / document.source / f"{key}.md"
        metadata_path = self._root / "metadata" / document.source / f"{key}.json"
        for path in (raw_path, normalized_path, metadata_path):
            path.parent.mkdir(parents=True, exist_ok=True)
        if change is not ChangeKind.UNCHANGED:
            _atomic_write_bytes(raw_path, raw)
            _atomic_write_text(normalized_path, normalized_content)
            metadata = document.model_dump(mode="json") | {"content_hash": digest}
            _atomic_write_text(
                metadata_path,
                json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            )
        now = datetime.now(UTC)
        self._state_store.upsert_document(
            source_id=document.id,
            source=document.source,
            content_hash=digest,
            normalized_path=normalized_path,
            raw_path=raw_path,
            state=DocumentState.ACTIVE.value,
            last_seen=now,
            updated_at=document.updated_at,
        )
        return StoredDocument(
            document=document,
            change=change,
            content_hash=digest,
            raw_path=raw_path,
            normalized_path=normalized_path,
            metadata_path=metadata_path,
        )

    def reconcile(self, source: str, seen_source_ids: set[str]) -> int:
        """完全snapshotに存在しないactive documentをunavailableへ変更する。

        Args:
            source: 完全snapshotを取得したsource名。
            seen_source_ids: 今回確認できたSource ID。

        Returns:
            unavailableへ変更した件数。
        """
        active_documents = {
            str(document["source_id"]): document
            for document in self._state_store.list_documents(source)
            if document["state"] == DocumentState.ACTIVE.value
        }
        missing_ids = set(active_documents) - seen_source_ids
        for source_id in missing_ids:
            document = active_documents[source_id]
            normalized_path = Path(str(document["normalized_path"]))
            raw_path = Path(str(document["raw_path"]))
            content = normalized_path.read_text(encoding="utf-8")
            if _UNAVAILABLE_MARKER not in content:
                content = content.rstrip() + f"\n\n{_UNAVAILABLE_MARKER}\n"
                _atomic_write_text(normalized_path, content)
            digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
            last_seen = datetime.fromisoformat(str(document["last_seen"]))
            updated_at_value = document.get("updated_at")
            updated_at = datetime.fromisoformat(str(updated_at_value)) if updated_at_value else None
            self._state_store.upsert_document(
                source_id=source_id,
                source=source,
                content_hash=digest,
                normalized_path=normalized_path,
                raw_path=raw_path,
                state=DocumentState.UNAVAILABLE.value,
                last_seen=last_seen,
                updated_at=updated_at,
            )
            self._state_store.stage_openkb_document(
                source_id=source_id,
                source=source,
                content_hash=digest,
                normalized_path=normalized_path,
                raw_path=normalized_path,
            )
        return len(missing_ids)


def _atomic_write_bytes(path: Path, content: bytes) -> None:
    """同一filesystem内のreplaceでbytesを安全に保存する。

    Args:
        path: 保存先。
        content: 保存内容。

    Returns:
        なし。
    """
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_bytes(content)
    temporary_path.replace(path)


def _atomic_write_text(path: Path, content: str) -> None:
    """同一filesystem内のreplaceでUTF-8 textを安全に保存する。

    Args:
        path: 保存先。
        content: 保存内容。

    Returns:
        なし。
    """
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_text(content, encoding="utf-8")
    temporary_path.replace(path)


def serialize_document_state(document: dict[str, Any]) -> dict[str, Any]:
    """API response向けにdocument状態をcopyする。

    Args:
        document: SQLiteから取得したdocument状態。

    Returns:
        JSON化可能なcopy。
    """
    return dict(document)
