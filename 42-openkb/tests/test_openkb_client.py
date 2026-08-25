"""OpenKB staging、初期化、compile API連携を検証する。"""

from __future__ import annotations

import json
from pathlib import Path

import httpx
import yaml

from llm_wiki_platform.config import AppConfig
from llm_wiki_platform.connectors.base import RetryingHttpClient
from llm_wiki_platform.openkb_client import OpenKBClient
from llm_wiki_platform.state import StateStore


def _compile_config(tmp_path: Path) -> AppConfig:
    """compileを有効化したtest用AppConfigを作成する。

    Args:
        tmp_path: test固有directory。

    Returns:
        schema検証済みAppConfig。
    """
    source_path = Path(__file__).parents[1] / "config.yaml"
    loaded = yaml.safe_load(source_path.read_text(encoding="utf-8"))
    assert isinstance(loaded, dict)
    loaded["storage"] = {
        "source_store_path": str(tmp_path / "source"),
        "state_database_path": str(tmp_path / "state.db"),
    }
    loaded["openkb"]["base_url"] = "http://openkb.test"
    loaded["pipeline"]["compile"]["enabled"] = True
    return AppConfig.model_validate(loaded)


async def test_compile_initializes_kb_uploads_staging_and_recompiles(tmp_path: Path) -> None:
    """成功したaddだけstagingから除去され全体recompileされることを検証する。"""
    config = _compile_config(tmp_path)
    state_store = StateStore(tmp_path / "state.db")
    normalized = tmp_path / "source.md"
    raw = tmp_path / "source.json"
    normalized.write_text("# Source\n", encoding="utf-8")
    raw.write_text("{}", encoding="utf-8")
    state_store.stage_openkb_document(
        source_id="gitlab:test:issue:1",
        source="gitlab",
        content_hash="hash-1",
        normalized_path=normalized,
        raw_path=raw,
    )
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        """OpenKB endpointごとのtest responseを返す。

        Args:
            request: MockTransportが受け取ったrequest。

        Returns:
            endpointに対応するHTTP response。
        """
        calls.append(request.url.path)
        if request.url.path == "/api/v1/status":
            return httpx.Response(400, json={"detail": "unknown kb"})
        if request.url.path == "/api/v1/init":
            return httpx.Response(200, json={"created": True})
        if request.url.path == "/api/v1/add":
            return httpx.Response(
                200, json={"added_count": 1, "skipped_count": 0, "failed_count": 0}
            )
        if request.url.path == "/api/v1/recompile":
            return httpx.Response(200, json={"status": "done", "recompiled": 1})
        return httpx.Response(404)

    async with httpx.AsyncClient(
        base_url="http://openkb.test", transport=httpx.MockTransport(handler)
    ) as client:
        retrying = RetryingHttpClient(
            client, config.defaults.ingest.retry, config.defaults.ingest.rate_limit
        )
        openkb = OpenKBClient(config, state_store, retrying, {"LITELLM_MASTER_KEY": "secret"})
        result = await openkb.compile()

    assert result["uploaded"] == 1
    assert state_store.list_openkb_staging() == []
    assert calls == [
        "/api/v1/status",
        "/api/v1/init",
        "/api/v1/add",
        "/api/v1/recompile",
    ]


async def test_nextcloud_binary_uploads_original_and_metadata(tmp_path: Path) -> None:
    """Nextcloud binaryが原fileとCanonical Markdownの両方をOpenKBへ渡すことを検証する。"""
    config = _compile_config(tmp_path)
    state_store = StateStore(tmp_path / "state.db")
    normalized = tmp_path / "document.md"
    raw = tmp_path / "document.pdf"
    normalized.write_text("# Document\n", encoding="utf-8")
    raw.write_bytes(b"%PDF-test")
    state_store.stage_openkb_document(
        source_id="nextcloud:docs:file:1",
        source="nextcloud",
        content_hash="hash-1",
        normalized_path=normalized,
        raw_path=raw,
    )
    uploaded_filenames: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        """upload filenameを記録してOpenKB成功responseを返す。

        Args:
            request: MockTransportが受け取ったrequest。

        Returns:
            endpointに対応するHTTP response。
        """
        if request.url.path == "/api/v1/status":
            return httpx.Response(200, json={"total_indexed": 0})
        if request.url.path == "/api/v1/kb/config":
            assert request.method == "PATCH"
            assert json.loads(request.content)["config"]["model"] == ("openai/openai/gpt-oss:20b")
            return httpx.Response(200, json={"model": "openai/openai/gpt-oss:20b"})
        if request.url.path == "/api/v1/add":
            body = request.read().decode("latin-1")
            for filename in ("document.pdf", "document.md"):
                if f'filename="{filename}"' in body:
                    uploaded_filenames.append(filename)
            return httpx.Response(
                200, json={"added_count": 1, "skipped_count": 0, "failed_count": 0}
            )
        if request.url.path == "/api/v1/recompile":
            return httpx.Response(200, json={"status": "done", "recompiled": 2})
        return httpx.Response(404)

    async with httpx.AsyncClient(
        base_url="http://openkb.test", transport=httpx.MockTransport(handler)
    ) as client:
        retrying = RetryingHttpClient(
            client, config.defaults.ingest.retry, config.defaults.ingest.rate_limit
        )
        openkb = OpenKBClient(config, state_store, retrying, {"LITELLM_MASTER_KEY": "secret"})
        result = await openkb.compile()

    assert result["uploaded"] == 2
    assert uploaded_filenames == ["document.pdf", "document.md"]
