"""OpenKB REST APIへのstaging反映とknowledge compile。"""

from __future__ import annotations

import mimetypes
from collections.abc import Mapping
from pathlib import Path
from typing import Any

import httpx

from llm_wiki_platform.config import AppConfig
from llm_wiki_platform.connectors.base import RetryingHttpClient, require_mapping
from llm_wiki_platform.state import StateStore

_OPENKB_BINARY_EXTENSIONS = frozenset({".pdf", ".docx", ".pptx", ".xlsx", ".xls"})


class OpenKBClient:
    """OpenKB knowledge baseの初期化、add、recompileを管理する。"""

    def __init__(
        self,
        config: AppConfig,
        state_store: StateStore,
        http: RetryingHttpClient,
        environ: Mapping[str, str],
    ) -> None:
        """OpenKBClientを初期化する。

        Args:
            config: OpenKBとLLM接続を含むapplication設定。
            state_store: staging queueの保存先。
            http: Bearer認証設定済みHTTP client。
            environ: LLM API keyを解決する環境変数。

        Returns:
            なし。
        """
        self._config = config.openkb
        self._state_store = state_store
        self._http = http
        self._environ = environ

    async def compile(self) -> dict[str, Any]:
        """staging documentをaddしknowledge base全体をrecompileする。

        Returns:
            upload件数とOpenKB recompile response。

        Raises:
            RuntimeError: OpenKB addが失敗を返した場合。
            KeyError: LLM API key環境変数が存在しない場合。
            httpx.HTTPError: OpenKB API requestが失敗した場合。
        """
        await self._ensure_knowledge_base()
        staged = self._state_store.list_openkb_staging()
        uploaded = 0
        skipped = 0
        for item in staged:
            for path in self._upload_paths(item):
                content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
                response = await self._http.request(
                    "POST",
                    "/api/v1/add",
                    data={"kb": self._config.knowledge_base, "stream": "false"},
                    files={"files": (path.name, path.read_bytes(), content_type)},
                )
                payload = require_mapping(response.json(), "OpenKB add response")
                failed_count = int(payload.get("failed_count", 0))
                if failed_count:
                    raise RuntimeError(f"OpenKB addが{failed_count}件失敗しました: {payload}")
                uploaded += int(payload.get("added_count", 0))
                skipped += int(payload.get("skipped_count", 0))
            self._state_store.complete_openkb_staging(
                str(item["source_id"]), str(item["content_hash"])
            )
        response = await self._http.request(
            "POST",
            "/api/v1/recompile",
            json={
                "kb": self._config.knowledge_base,
                "all_docs": True,
                "dry_run": False,
                "refresh_schema": False,
                "stream": False,
            },
        )
        recompile = dict(require_mapping(response.json(), "OpenKB recompile response"))
        return {
            "staged": len(staged),
            "uploaded": uploaded,
            "skipped": skipped,
            "recompile": recompile,
        }

    async def _ensure_knowledge_base(self) -> None:
        """knowledge baseが未作成ならOpenKB APIで初期化する。

        Returns:
            なし。

        Raises:
            KeyError: LLM API key環境変数が存在しない場合。
            httpx.HTTPError: statusまたはinit requestが失敗した場合。
        """
        try:
            await self._http.request(
                "POST", "/api/v1/status", json={"kb": self._config.knowledge_base}
            )
            return
        except httpx.HTTPStatusError as error:
            if error.response.status_code != 400:
                raise
        api_key = self._environ[self._config.llm.api_key_env]
        await self._http.request(
            "POST",
            "/api/v1/init",
            json={
                "kb": self._config.knowledge_base,
                "model": self._config.llm.model,
                "api_key": api_key,
                "openai_api_base": str(self._config.llm.openai_api_base),
            },
        )

    def _upload_paths(self, item: dict[str, Any]) -> tuple[Path, ...]:
        """source特性に応じてOpenKBへ送るfile群を選択する。

        Args:
            item: staging item。

        Returns:
            OpenKB addへ送信するfile path。Nextcloud binaryは原fileとmetadataを含む。
        """
        raw_path = Path(str(item["raw_path"]))
        normalized_path = Path(str(item["normalized_path"]))
        if item["source"] == "nextcloud" and raw_path.suffix.lower() in _OPENKB_BINARY_EXTENSIONS:
            return (raw_path, normalized_path)
        return (normalized_path,)
