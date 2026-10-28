"""OIKBのfile処理をKnowledge登録確認まで逐次化する。"""

from __future__ import annotations

import importlib.util
import logging
import sys
import time
from collections.abc import Sequence
from pathlib import Path

LOGGER = logging.getLogger(__name__)


def load_client_path() -> Path:
    """install済みOIKB client moduleのpathを解決する。

    Args:
        なし。

    Returns:
        OIKB client moduleのpath。

    Raises:
        RuntimeError: moduleのpathを解決できない場合。
    """
    try:
        spec = importlib.util.find_spec("oikb.client")
    except ModuleNotFoundError as error:
        raise RuntimeError("oikb.client module was not found") from error
    if spec is None or spec.origin is None:
        raise RuntimeError("oikb.client module path was not found")
    return Path(spec.origin)


def patch_source(source: str) -> str:
    """file単位の登録確認と失敗時の1回retryをclientへ追加する。

    Args:
        source: patch前のOIKB client source code。

    Returns:
        file登録確認、失敗file cleanup、1回retryを追加したsource code。

    Raises:
        RuntimeError: 想定したpatch対象が存在しない場合。
    """
    old_imports = """import json
"""
    new_imports = """import json
import logging
import time
"""
    old_docstring = '        """POST /files/ — upload a single file to the KB."""\n'
    new_docstring = '''        """1 fileを登録確認まで処理し、失敗時は1回retryする。

        Args:
            file_content: uploadするfile内容。
            filename: Open WebUIへ登録するfile名。
            kb_id: 登録先Knowledge Base ID。
            file_hash: 差分判定に使うfile hash。
            directory_id: 登録先directory ID。rootの場合はNone。

        Returns:
            Open WebUIのupload response。

        Raises:
            RuntimeError: response形式が不正、またはretry後もfile処理が失敗した場合。
            TimeoutError: Knowledge Baseへの登録を制限時間内に確認できない場合。
            httpx.HTTPStatusError: Open WebUI APIがerror responseを返した場合。

        Side Effects:
            Open WebUIへfileをuploadし、Markdown変換、vector作成、Knowledge登録を行う。
            retry前に初回uploadで作成したfileを削除する。
        """
'''
    old_upload_request = '''        resp = self._http.post(
            "/files/",
            files={"file": (filename, file_content, _content_type(filename))},
            data={"metadata": json.dumps(metadata)},
        )
        resp.raise_for_status()
        return resp.json()
'''
    new_upload_request = '''        logger = logging.getLogger(__name__)
        for attempt in range(2):
            file_id = None
            try:
                logger.info(
                    "OIKB2 processing file: knowledge_id=%s file=%s attempt=%d/2",
                    kb_id,
                    filename,
                    attempt + 1,
                )
                resp = self._http.post(
                    "/files/",
                    params={"process_in_background": "false"},
                    files={"file": (filename, file_content, _content_type(filename))},
                    data={"metadata": json.dumps(metadata)},
                )
                resp.raise_for_status()
                uploaded_file = resp.json()
                file_id = uploaded_file.get("id")
                if not isinstance(file_id, str) or not file_id:
                    raise RuntimeError("Open WebUI upload response has no file ID")

                wait_seconds = getattr(self._http.timeout, "read", None) or 120.0
                deadline = time.monotonic() + wait_seconds
                while True:
                    status_resp = self._http.get(f"/files/{file_id}/process/status")
                    status_resp.raise_for_status()
                    status_payload = status_resp.json()
                    if not isinstance(status_payload, dict):
                        raise RuntimeError("Open WebUI file status response is invalid")
                    status = status_payload.get("status")
                    if status == "failed":
                        detail = status_payload.get("error")
                        if not isinstance(detail, str) or not detail:
                            try:
                                file_resp = self._http.get(f"/files/{file_id}")
                                file_resp.raise_for_status()
                                file_payload = file_resp.json()
                                file_data = (
                                    file_payload.get("data")
                                    if isinstance(file_payload, dict)
                                    else None
                                )
                                detail = (
                                    file_data.get("error")
                                    if isinstance(file_data, dict)
                                    else None
                                )
                            except Exception:
                                detail = None
                        suffix = (
                            f": {detail}"
                            if isinstance(detail, str) and detail
                            else ""
                        )
                        raise RuntimeError(
                            f"Open WebUI file processing failed: {filename}{suffix}"
                        )

                    linked = False
                    page = 1
                    seen = 0
                    while True:
                        knowledge_resp = self._http.get(
                            f"/knowledge/{kb_id}/files",
                            params={"page": page, "limit": 1000},
                        )
                        knowledge_resp.raise_for_status()
                        knowledge_payload = knowledge_resp.json()
                        if not isinstance(knowledge_payload, dict):
                            raise RuntimeError(
                                "Open WebUI Knowledge file response is invalid"
                            )
                        items = knowledge_payload.get("items")
                        if not isinstance(items, list):
                            raise RuntimeError(
                                "Open WebUI Knowledge file list is invalid"
                            )
                        if any(
                            isinstance(item, dict) and item.get("id") == file_id
                            for item in items
                        ):
                            linked = True
                            break
                        seen += len(items)
                        total = knowledge_payload.get("total")
                        if not items or not isinstance(total, int) or seen >= total:
                            break
                        page += 1

                    if status == "completed" and linked:
                        logger.info(
                            "OIKB2 registered file: "
                            "knowledge_id=%s file=%s file_id=%s",
                            kb_id,
                            filename,
                            file_id,
                        )
                        return uploaded_file
                    if time.monotonic() >= deadline:
                        raise TimeoutError(
                            "Open WebUI Knowledge registration timed out: "
                            f"{filename}"
                        )
                    time.sleep(1)
            except Exception as error:
                status_code = getattr(
                    getattr(error, "response", None),
                    "status_code",
                    None,
                )
                if file_id:
                    try:
                        delete_resp = self._http.delete(f"/files/{file_id}")
                        delete_resp.raise_for_status()
                    except Exception as cleanup_error:
                        raise RuntimeError(
                            f"Open WebUI file cleanup failed: {filename}: {cleanup_error}"
                        ) from cleanup_error
                if (
                    isinstance(status_code, int)
                    and status_code < 500
                    and status_code not in (408, 429)
                ):
                    raise
                if attempt >= 1:
                    raise RuntimeError(
                        f"Open WebUI file retry failed: {filename}: {error}"
                    ) from error
                logger.warning(
                    "OIKB2 retrying file: knowledge_id=%s file=%s error=%s",
                    kb_id,
                    filename,
                    error,
                )
                time.sleep(2)
'''
    if old_imports not in source:
        raise RuntimeError("oikb.client import patch target was not found")
    if old_docstring not in source:
        raise RuntimeError("oikb.client upload docstring patch target was not found")
    if old_upload_request not in source:
        raise RuntimeError("oikb.client upload patch target was not found")
    return (
        source.replace(old_imports, new_imports, 1)
        .replace(old_docstring, new_docstring, 1)
        .replace(old_upload_request, new_upload_request, 1)
    )


def main(argv: Sequence[str]) -> int:
    """install済みOIKB clientへ逐次登録patchを適用する。

    Args:
        argv: プログラム名を含むcommand line引数。

    Returns:
        patch成功時は0、module解決またはfile更新の失敗時は1。

    Side Effects:
        install済みOIKB client moduleを書き換え、実行時間をlogへ記録する。
    """
    del argv
    started_at = time.perf_counter()
    logging.basicConfig(level=logging.INFO)
    try:
        path = load_client_path()
        source = patch_source(path.read_text(encoding="utf-8"))
        path.write_text(source, encoding="utf-8")
        return 0
    except (OSError, RuntimeError) as error:
        LOGGER.error("OIKB client patch failed: %s", error)
        return 1
    finally:
        LOGGER.info("Elapsed time: %.3f seconds", time.perf_counter() - started_at)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
