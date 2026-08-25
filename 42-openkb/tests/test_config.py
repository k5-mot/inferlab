"""config.yamlの読込とoverride解決を検証する。"""

from __future__ import annotations

from pathlib import Path

import pytest

from llm_wiki_platform.config import ConfigLoadError, load_config


def _write_config(path: Path, source_block: str, *, compile_enabled: bool = False) -> Path:
    """test用の最小config.yamlを作成する。

    Args:
        path: 書込先。
        source_block: sources配下へ挿入するYAML。
        compile_enabled: compileを有効にするか。

    Returns:
        作成したconfig path。
    """
    path.write_text(
        f"""
version: 1
scheduler:
  timezone: Asia/Tokyo
storage:
  source_store_path: /tmp/source
  state_database_path: /tmp/state.db
defaults:
  ingest:
    retry:
      max_attempts: 3
      backoff: exponential
      initial_delay: 30s
      max_delay: 10m
    rate_limit:
      requests_per_minute: 60
sources:
{source_block}
openkb:
  base_url: http://openkb:7566
  knowledge_base: internal-wiki
  generated_wiki_path: /openkb/internal-wiki/wiki
  credential:
    token_env: OPENKB_TOKEN
  llm:
    model: openai/test-model
    api_key_env: LITELLM_MASTER_KEY
    openai_api_base: http://litellm:4000/v1
wikijs:
  base_url: http://wikijs:3000
  human_wiki:
    path: human
    locale: en
  llm_wiki:
    path: llm
    locale: en
  ingest:
    enabled: false
    schedule: "*/15 * * * *"
  reader_credential:
    token_env: WIKIJS_READER_TOKEN
  publisher_credential:
    token_env: WIKIJS_PUBLISHER_TOKEN
pipeline:
  compile:
    enabled: {str(compile_enabled).lower()}
    schedule: "*/30 * * * *"
  publish:
    enabled: false
    targets: []
    mode: after_successful_compile
    require_validation: false
    deletion_policy: mark_unavailable
""".strip()
        + "\n",
        encoding="utf-8",
    )
    return path


def test_common_defaults_are_merged_with_source_override(tmp_path: Path) -> None:
    """source別overrideが未指定の共通値を保持することを検証する。"""
    config_path = _write_config(
        tmp_path / "config.yaml",
        """  nextcloud:
    enabled: false
    base_url: http://nextcloud
    credential:
      username_env: NEXTCLOUD_USERNAME
      password_env: NEXTCLOUD_PASSWORD
    ingest:
      schedule: "*/30 * * * *"
      retry:
        max_attempts: 5
""",
    )

    config = load_config(config_path, {})
    effective = config.effective_ingest("nextcloud")

    assert effective.retry.max_attempts == 5
    assert effective.retry.backoff == "exponential"
    assert effective.retry.initial_delay.total_seconds() == 30
    assert effective.rate_limit.requests_per_minute == 60


def test_enabled_source_requires_referenced_environment_variables(tmp_path: Path) -> None:
    """有効sourceのcredential参照不足で起動失敗することを検証する。"""
    config_path = _write_config(
        tmp_path / "config.yaml",
        """  gitlab:
    enabled: true
    base_url: http://gitlab
    credential:
      token_env: GITLAB_TOKEN
    ingest:
      schedule: "*/5 * * * *"
""",
    )

    with pytest.raises(ConfigLoadError, match="GITLAB_TOKEN"):
        load_config(config_path, {"OPENKB_TOKEN": "openkb-token"})


def test_unknown_source_fails_fast(tmp_path: Path) -> None:
    """未対応sourceを暗黙に無効化せず拒否することを検証する。"""
    config_path = _write_config(
        tmp_path / "config.yaml",
        """  confluence:
    enabled: false
    base_url: http://confluence
    credential: {}
    ingest:
      schedule: "*/5 * * * *"
""",
    )

    with pytest.raises(ConfigLoadError, match="未対応source"):
        load_config(config_path, {})


def test_wikijs_uses_common_ingest_defaults_and_normalizes_paths(tmp_path: Path) -> None:
    """Wiki.js sourceにも共通既定値を適用しpath prefixを正規化することを検証する。"""
    config_path = _write_config(tmp_path / "config.yaml", "  {}")
    content = config_path.read_text(encoding="utf-8").replace("path: human", "path: /human/")
    config_path.write_text(content, encoding="utf-8")

    config = load_config(config_path, {})
    effective = config.effective_ingest("wikijs")

    assert config.wikijs.human_wiki.path == "human"
    assert effective.retry.max_attempts == 3
    assert effective.rate_limit.requests_per_minute == 60


def test_wikijs_human_and_llm_paths_must_not_overlap(tmp_path: Path) -> None:
    """Wiki.jsのHuman WikiとLLM Wikiが包含関係なら起動失敗することを検証する。"""
    config_path = _write_config(tmp_path / "config.yaml", "  {}")
    content = config_path.read_text(encoding="utf-8").replace("path: llm", "path: human/generated")
    config_path.write_text(content, encoding="utf-8")

    with pytest.raises(ConfigLoadError, match="path prefix"):
        load_config(config_path, {})


def test_invalid_cron_expression_fails_fast(tmp_path: Path) -> None:
    """不正なcron式を起動時に拒否することを検証する。"""
    config_path = _write_config(
        tmp_path / "config.yaml",
        """  gitlab:
    enabled: false
    base_url: http://gitlab
    credential:
      token_env: GITLAB_TOKEN
    ingest:
      schedule: invalid
""",
    )

    with pytest.raises(ConfigLoadError, match="cron"):
        load_config(config_path, {})


def test_repository_config_contains_valid_viewer_settings() -> None:
    """repositoryの共通configに有効なMintlify Viewer設定があることを検証する。"""
    config_path = Path(__file__).parents[1] / "config.yaml"

    config = load_config(config_path, {})

    assert config.viewer is not None
    assert config.viewer.mintlify.public_port == 8080
    assert config.viewer.mintlify.colors.primary == "#0f766e"
