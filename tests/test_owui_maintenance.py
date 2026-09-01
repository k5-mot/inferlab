"""Open WebUI/OIKB保守scriptのunit test。"""

from __future__ import annotations

import importlib.util
import logging
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import call, patch

REPO_ROOT = Path(__file__).resolve().parents[1]


def load_script(module_name: str, relative_path: str) -> ModuleType:
    """file pathから保守scriptをtest用moduleとして読み込む。

    Args:
        module_name: 読み込むmodule名。
        relative_path: repository rootからのscript path。

    Returns:
        読み込んだPython module。

    Raises:
        RuntimeError: module specまたはloaderを作成できない場合。
    """
    script_path = REPO_ROOT / relative_path
    spec = importlib.util.spec_from_file_location(module_name, script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"moduleを読み込めません: {script_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


CLEANUP = load_script(
    "remove_openwebui_stuck_files",
    "20-owui/oikb/remove_openwebui_stuck_files.py",
)
TRIGGER = load_script(
    "trigger_oikb_syncs",
    "20-owui/oikb/trigger_oikb_syncs.py",
)


class CleanupScriptTest(unittest.TestCase):
    """停止ファイルcleanupの選択と削除を検証する。"""

    def test_discover_knowledge_ids_includes_source_without_history(self) -> None:
        """historyがないsourceもhealthのkb_idから検出する。"""
        health = {
            "sources": {
                "source-a": {"kb_id": "kb-a"},
                "source-b": {"kb_id": "kb-b"},
            }
        }
        history = {
            "entries": [
                {"source": "source-a", "kb_id": "kb-a"},
            ]
        }
        with patch.object(CLEANUP, "request_json", side_effect=[health, history]):
            result = CLEANUP.discover_knowledge_ids("http://oikb", "secret")

        self.assertEqual(result, ["kb-a", "kb-b"])

    def test_discover_knowledge_ids_deduplicates_history(self) -> None:
        """現行sourceのKnowledge IDだけを履歴から重複なく取得する。"""
        health = {"sources": {"source-a": {}, "source-b": {}}}
        history = {
            "entries": [
                {"source": "source-b", "kb_id": "kb-b"},
                {"source": "source-a", "kb_id": "kb-a"},
                {"source": "source-b", "kb_id": "kb-b"},
                {"source": "removed-source", "kb_id": "obsolete-kb"},
                {"source": "source-a", "kb_id": ""},
            ]
        }
        with patch.object(CLEANUP, "request_json", side_effect=[health, history]):
            result = CLEANUP.discover_knowledge_ids("http://oikb", "secret")

        self.assertEqual(result, ["kb-a", "kb-b"])

    def test_select_stuck_files_requires_old_pending_status(self) -> None:
        """境界時刻以前のpending/processingだけを削除候補にする。"""
        files = [
            {"id": "old-pending", "data": {"status": "pending"}, "updated_at": 100},
            {
                "id": "old-processing",
                "data": {"status": "processing"},
                "created_at": 200,
            },
            {"id": "new-pending", "data": {"status": "pending"}, "updated_at": 301},
            {"id": "failed", "data": {"status": "failed"}, "updated_at": 100},
            {"id": "missing-time", "data": {"status": "pending"}},
        ]

        result = CLEANUP.select_stuck_files(files, cutoff_epoch=300)

        self.assertEqual(
            [item["id"] for item in result], ["old-pending", "old-processing"]
        )

    def test_cleanup_dry_run_does_not_delete(self) -> None:
        """dry-runでは停止ファイルを検出しても削除APIを呼ばない。"""
        files = [{"id": "stuck", "data": {"status": "pending"}, "updated_at": 1}]
        with (
            patch.object(CLEANUP, "get_pending_files", return_value=files),
            patch.object(CLEANUP, "delete_file") as delete_file,
            patch.object(CLEANUP.time, "time", return_value=10_000),
        ):
            count = CLEANUP.cleanup_stuck_files(
                "http://open-webui",
                "secret",
                ["kb-a"],
                min_age_seconds=3600,
                delete=False,
            )

        self.assertEqual(count, 1)
        delete_file.assert_not_called()

    def test_cleanup_delete_calls_file_api(self) -> None:
        """削除指定時は選択された停止ファイルだけを削除する。"""
        files = [
            {"id": "stuck", "data": {"status": "processing"}, "updated_at": 1},
            {"id": "active", "data": {"status": "processing"}, "updated_at": 9_999},
        ]
        with (
            patch.object(CLEANUP, "get_pending_files", return_value=files),
            patch.object(CLEANUP, "delete_file") as delete_file,
            patch.object(CLEANUP.time, "time", return_value=10_000),
        ):
            count = CLEANUP.cleanup_stuck_files(
                "http://open-webui",
                "secret",
                ["kb-a"],
                min_age_seconds=3600,
                delete=True,
            )

        self.assertEqual(count, 1)
        delete_file.assert_called_once_with("http://open-webui", "secret", "stuck")

    def test_main_loads_env_file_before_parsing_defaults(self) -> None:
        """mainはrepository rootの.envをCLI既定値へ反映する。"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            env_file = Path(temporary_directory) / ".env"
            env_file.write_text(
                "OPEN_WEBUI_API_KEY=webui-secret\nOIKB_API_KEY=oikb-secret\n",
                encoding="utf-8",
            )
            with (
                patch.dict(os.environ, {}, clear=True),
                patch.object(CLEANUP, "DEFAULT_ENV_FILE", env_file),
                patch.object(
                    CLEANUP, "discover_knowledge_ids", return_value=[]
                ) as discover,
            ):
                result = CLEANUP.main(["remove_openwebui_stuck_files.py"])

        self.assertEqual(result, 0)
        discover.assert_called_once_with("http://localhost:32001", "oikb-secret")

    def test_env_file_does_not_override_process_environment(self) -> None:
        """dotenvの値よりprocessへ設定済みの環境変数を優先する。"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            env_file = Path(temporary_directory) / ".env"
            env_file.write_text(
                "OPEN_WEBUI_API_KEY=dotenv-secret\n",
                encoding="utf-8",
            )
            with patch.dict(
                os.environ,
                {"OPEN_WEBUI_API_KEY": "process-secret"},
                clear=True,
            ):
                loaded = CLEANUP.load_environment(env_file)
                value = os.environ["OPEN_WEBUI_API_KEY"]

        self.assertTrue(loaded)
        self.assertEqual(value, "process-secret")


class TriggerScriptTest(unittest.TestCase):
    """OIKBとOpen WebUIの逐次同期を検証する。"""

    def test_discover_sources_uses_requested_order(self) -> None:
        """指定順でsourceとKnowledge IDの対応を解決する。"""
        states = {
            "nextcloud:/oikb": {
                "name": "nextcloud-documents",
                "kb_id": "kb-nextcloud",
            },
            "s3://bucket": {"name": "rustfs-documents", "kb_id": "kb-rustfs"},
        }
        with patch.object(TRIGGER, "get_source_states", return_value=states):
            result = TRIGGER.discover_sources(
                "http://oikb",
                ["rustfs-documents", "nextcloud-documents"],
            )

        self.assertEqual(
            result,
            [
                TRIGGER.SourceConfig("s3://bucket", "rustfs-documents", "kb-rustfs"),
                TRIGGER.SourceConfig(
                    "nextcloud:/oikb",
                    "nextcloud-documents",
                    "kb-nextcloud",
                ),
            ],
        )

    def test_trigger_sync_posts_encoded_source_name(self) -> None:
        """source名をURL encodeしKnowledge IDが一致するtriggerを受理する。"""
        source = TRIGGER.SourceConfig("source-key", "source name", "kb-a")
        with patch.object(
            TRIGGER,
            "request_json",
            return_value={"triggered": True, "kb_id": "kb-a"},
        ) as request_json:
            TRIGGER.trigger_sync("http://oikb/", "secret", source)

        request_json.assert_called_once_with(
            "POST",
            "http://oikb/sync/source%20name",
            "secret",
        )

    def test_logging_uses_colored_english_level_names(self) -> None:
        """terminalでは英語のlog level名にANSI colorを付ける。"""
        try:
            for module in (CLEANUP, TRIGGER):
                with (
                    self.subTest(module=module.__name__),
                    patch.dict(os.environ, {}, clear=True),
                    patch.object(module.sys.stderr, "isatty", return_value=True),
                ):
                    module.configure_logging()
                    self.assertEqual(
                        logging.getLevelName(logging.INFO),
                        "\x1b[32mINFO\x1b[0m",
                    )
                    self.assertEqual(
                        logging.getLevelName(logging.ERROR),
                        "\x1b[31mERROR\x1b[0m",
                    )
        finally:
            for level, name in (
                (logging.DEBUG, "DEBUG"),
                (logging.INFO, "INFO"),
                (logging.WARNING, "WARNING"),
                (logging.ERROR, "ERROR"),
                (logging.CRITICAL, "CRITICAL"),
            ):
                logging.addLevelName(level, name)

    def test_sync_source_reports_pending_cleanup_action(self) -> None:
        """sync前のpending fileでは英語のcleanup手順を報告する。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(
                TRIGGER,
                "get_source_states",
                return_value={"source-key": {"status": "idle"}},
            ),
            patch.object(
                TRIGGER,
                "get_pending_file_ids",
                return_value={"pending-a", "pending-b"},
            ),
            self.assertRaisesRegex(
                ValueError,
                r"Open WebUI has 2 pending files before sync.*remove_openwebui_stuck_files\.py",
            ),
        ):
            TRIGGER.sync_source(
                "http://oikb",
                "oikb-secret",
                "http://open-webui",
                "webui-secret",
                source,
                3,
                600,
                900,
            )

    def test_wait_for_oikb_sync_ignores_previous_completion(self) -> None:
        """trigger前のsuccessを無視して今回の完了まで待つ。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        states = [
            {"source-key": {"status": "success", "last_sync": 90.0}},
            {"source-key": {"status": "running", "last_sync": 90.0}},
            {"source-key": {"status": "success", "last_sync": 101.0}},
        ]
        with (
            patch.object(TRIGGER, "get_source_states", side_effect=states),
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1, 2, 3]),
            patch.object(TRIGGER.time, "sleep"),
        ):
            result = TRIGGER.wait_for_oikb_sync(
                "http://oikb",
                source,
                previous_last_sync=90.0,
                triggered_at=100.0,
                poll_interval_seconds=1,
                timeout_seconds=10,
            )

        self.assertEqual(result["last_sync"], 101.0)

    def test_registration_waits_for_completed_link_and_empty_pending(self) -> None:
        """new fileの処理完了、link、pending解消が揃うまで待つ。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(
                TRIGGER,
                "get_file_status",
                side_effect=["processing", "completed"],
            ),
            patch.object(
                TRIGGER,
                "list_linked_file_ids",
                side_effect=[{"old"}, {"old", "new"}],
            ),
            patch.object(
                TRIGGER,
                "get_pending_file_ids",
                side_effect=[{"new"}, set()],
            ),
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1, 2]),
            patch.object(TRIGGER.time, "sleep"),
        ):
            TRIGGER.wait_for_open_webui_registration(
                "http://open-webui",
                "webui-secret",
                source,
                {"old"},
                {"files_added": 1, "files_modified": 0, "files_deleted": 0},
                poll_interval_seconds=1,
                timeout_seconds=10,
            )

    def test_registration_rejects_failed_file(self) -> None:
        """new fileの処理がfailedなら後続sourceへ進まず失敗する。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(TRIGGER, "list_linked_file_ids", return_value=set()),
            patch.object(TRIGGER, "get_pending_file_ids", return_value={"new"}),
            patch.object(TRIGGER, "get_file_status", return_value="failed"),
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1]),
            self.assertRaisesRegex(ValueError, "Open WebUI file processing failed"),
        ):
            TRIGGER.wait_for_open_webui_registration(
                "http://open-webui",
                "webui-secret",
                source,
                set(),
                {"files_added": 1, "files_modified": 0, "files_deleted": 0},
                poll_interval_seconds=1,
                timeout_seconds=10,
            )

    def test_trigger_all_syncs_runs_sources_sequentially(self) -> None:
        """sourceごとの完了待ち処理を指定順に呼び出す。"""
        sources = [
            TRIGGER.SourceConfig("key-a", "a", "kb-a"),
            TRIGGER.SourceConfig("key-b", "b", "kb-b"),
        ]
        with (
            patch.object(TRIGGER, "discover_sources", return_value=sources),
            patch.object(TRIGGER, "sync_source") as sync_source,
        ):
            count = TRIGGER.trigger_all_syncs(
                "http://oikb",
                "oikb-secret",
                "http://open-webui",
                "webui-secret",
                ["a", "b"],
                3,
                600,
                900,
            )

        self.assertEqual(count, 2)
        self.assertEqual(
            sync_source.call_args_list,
            [
                call(
                    "http://oikb",
                    "oikb-secret",
                    "http://open-webui",
                    "webui-secret",
                    sources[0],
                    3,
                    600,
                    900,
                ),
                call(
                    "http://oikb",
                    "oikb-secret",
                    "http://open-webui",
                    "webui-secret",
                    sources[1],
                    3,
                    600,
                    900,
                ),
            ],
        )

    def test_scheduler_waits_configured_interval(self) -> None:
        """全sourceの逐次処理後に指定された秒数だけ待機する。"""
        with (
            patch.object(TRIGGER, "trigger_all_syncs", return_value=2),
            patch.object(TRIGGER.time, "sleep", side_effect=KeyboardInterrupt) as sleep,
            self.assertRaises(KeyboardInterrupt),
        ):
            TRIGGER.run_scheduler(
                "http://oikb",
                "oikb-secret",
                "http://open-webui",
                "webui-secret",
                ["a", "b"],
                3600,
                3,
                600,
                900,
            )

        sleep.assert_called_once_with(3600)

    def test_main_loads_env_file_before_parsing_defaults(self) -> None:
        """mainはrepository rootの.envを同期triggerへ反映する。"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            env_file = Path(temporary_directory) / ".env"
            env_file.write_text(
                "OIKB_API_KEY=oikb-secret\n"
                "OPEN_WEBUI_API_KEY=webui-secret\n"
                "OIKB_SOURCE_ORDER=rustfs-documents,nextcloud-documents\n",
                encoding="utf-8",
            )
            with (
                patch.dict(os.environ, {}, clear=True),
                patch.object(TRIGGER, "DEFAULT_ENV_FILE", env_file),
                patch.object(TRIGGER, "trigger_all_syncs", return_value=2) as trigger,
            ):
                result = TRIGGER.main(["trigger_oikb_syncs.py", "--once"])

        self.assertEqual(result, 0)
        trigger.assert_called_once_with(
            "http://localhost:32001",
            "oikb-secret",
            "http://localhost:32000",
            "webui-secret",
            ["rustfs-documents", "nextcloud-documents"],
            3,
            21600,
            21600,
        )


if __name__ == "__main__":
    unittest.main()
