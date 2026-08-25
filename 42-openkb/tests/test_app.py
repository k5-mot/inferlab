"""FastAPI管理APIとconfig無効状態の応答を検証する。"""

from __future__ import annotations

from pathlib import Path

import yaml
from fastapi.testclient import TestClient

from llm_wiki_platform.app import create_app


def _disabled_config(tmp_path: Path) -> Path:
    """保存先だけをtest directoryへ変更した無効状態configを作成する。

    Args:
        tmp_path: test固有directory。

    Returns:
        作成したconfig path。
    """
    source_path = Path(__file__).parents[1] / "config.yaml"
    loaded = yaml.safe_load(source_path.read_text(encoding="utf-8"))
    assert isinstance(loaded, dict)
    loaded["storage"] = {
        "source_store_path": str(tmp_path / "source"),
        "state_database_path": str(tmp_path / "state.db"),
    }
    for source in loaded["sources"].values():
        source["enabled"] = False
    config_path = tmp_path / "config.yaml"
    config_path.write_text(yaml.safe_dump(loaded, sort_keys=False), encoding="utf-8")
    return config_path


def test_management_api_reports_disabled_pipeline(tmp_path: Path) -> None:
    """初期configでAPIが起動し無効jobを409で拒否することを検証する。"""
    application = create_app(_disabled_config(tmp_path), {})

    with TestClient(application) as client:
        health = client.get("/health")
        dashboard = client.get("/dashboard")
        connectors = client.get("/connectors")
        sources = client.get("/sources")
        compile_response = client.post("/compile")
        publish_response = client.post("/publish")
        reload_response = client.post("/config/reload")

    assert health.json() == {"status": "ok", "jobs": {}}
    assert dashboard.status_code == 200
    assert "OpenKB Sync Control" in dashboard.text
    assert connectors.json() == {"enabled": []}
    assert len(sources.json()) == 6
    assert compile_response.status_code == 409
    assert publish_response.status_code == 409
    assert reload_response.status_code == 404
