"""Open WebUI/OIKB保守scriptのunit test。"""

from __future__ import annotations

import importlib.util
import logging
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, call, patch

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


SYNC = load_script("oikb_sync", "scripts/oikb/oikb_sync.py")
CLEANUP = SYNC
TRIGGER = SYNC


class CleanupScriptTest(unittest.TestCase):
    """停止ファイルcleanupの選択と削除を検証する。"""

    def test_list_open_webui_files_uses_search_api(self) -> None:
        """Open WebUIの全file検索APIをcontentなしで呼び出す。"""
        response = [{"id": "file-a"}, {"id": "file-b"}]
        with patch.object(
            CLEANUP,
            "request_json",
            return_value=response,
        ) as request_json:
            result = CLEANUP.list_open_webui_files("http://open-webui", "secret")

        self.assertEqual(result, response)
        request_json.assert_called_once_with(
            "GET",
            "http://open-webui/api/v1/files/search?"
            "filename=%2A&content=false&skip=0&limit=1000",
            "secret",
        )

    def test_select_delete_candidates_uses_pending_and_failed_only(self) -> None:
        """対象KBのpending/failedだけを削除候補にする。"""
        files = [
            {
                "id": "pending",
                "data": {"status": "pending"},
                "meta": {"data": {"knowledge_id": "kb-a"}},
            },
            {
                "id": "failed",
                "data": {"status": "failed"},
                "meta": {"knowledge_id": "kb-a"},
            },
            {
                "id": "processing",
                "data": {"status": "processing"},
                "meta": {"data": {"knowledge_id": "kb-a"}},
            },
            {
                "id": "completed",
                "data": {"status": "completed"},
                "meta": {"data": {"knowledge_id": "kb-a"}},
            },
            {
                "id": "other-kb",
                "data": {"status": "failed"},
                "meta": {"data": {"knowledge_id": "kb-b"}},
            },
        ]

        result = CLEANUP.select_delete_candidates(files, ["kb-a"])

        self.assertEqual([item["id"] for item in result], ["pending", "failed"])

    def test_empty_knowledge_ids_selects_files_from_all_kbs(self) -> None:
        """Knowledge ID未指定時に全KBの停止fileを選択する。

        Args:
            なし。

        Returns:
            なし。
        """
        files = [
            {
                "id": "kb-a-pending",
                "data": {"status": "pending"},
                "meta": {"data": {"knowledge_id": "kb-a"}},
            },
            {
                "id": "kb-b-failed",
                "data": {"status": "failed"},
                "meta": {"data": {"knowledge_id": "kb-b"}},
            },
            {
                "id": "kb-c-completed",
                "data": {"status": "completed"},
                "meta": {"data": {"knowledge_id": "kb-c"}},
            },
        ]

        result = CLEANUP.select_delete_candidates(files, [])

        self.assertEqual(
            [item["id"] for item in result],
            ["kb-a-pending", "kb-b-failed"],
        )

    def test_cleanup_dry_run_does_not_delete(self) -> None:
        """dry-runでは停止ファイルを検出しても削除APIを呼ばない。"""
        files = [
            {
                "id": "stuck",
                "filename": "stuck.pdf",
                "data": {"status": "pending"},
                "meta": {"data": {"knowledge_id": "kb-a"}},
            }
        ]
        with (
            patch.object(CLEANUP, "list_open_webui_files", return_value=files),
            patch.object(CLEANUP, "delete_file") as delete_file,
            self.assertLogs(CLEANUP.LOGGER, level="WARNING") as logs,
        ):
            count = CLEANUP.cleanup_stuck_files(
                "http://open-webui",
                "secret",
                ["kb-a"],
                dry_run=True,
            )

        self.assertEqual(count, 1)
        self.assertIn("file=stuck.pdf", logs.output[0])
        delete_file.assert_not_called()

    def test_cleanup_delete_calls_file_api(self) -> None:
        """削除指定時は選択された停止ファイルだけを削除する。"""
        files = [
            {
                "id": "stuck",
                "data": {"status": "failed"},
                "meta": {"data": {"knowledge_id": "kb-a"}},
            },
            {
                "id": "active",
                "data": {"status": "processing"},
                "meta": {"data": {"knowledge_id": "kb-a"}},
            },
        ]
        with (
            patch.object(CLEANUP, "list_open_webui_files", return_value=files),
            patch.object(CLEANUP, "delete_file") as delete_file,
        ):
            count = CLEANUP.cleanup_stuck_files(
                "http://open-webui",
                "secret",
                ["kb-a"],
                dry_run=False,
            )

        self.assertEqual(count, 1)
        delete_file.assert_called_once_with("http://open-webui", "secret", "stuck")

    def test_main_loads_env_file_before_parsing_defaults(self) -> None:
        """mainはrepository rootの.envをCLI既定値へ反映する。"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            env_file = Path(temporary_directory) / ".env"
            env_file.write_text(
                "OPEN_WEBUI_API_URL=http://webui.example\n"
                "OPEN_WEBUI_API_KEY=webui-secret\n"
                "OIKB_API_URL=http://oikb.example\n"
                "OIKB_API_KEY=oikb-secret\n",
                encoding="utf-8",
            )
            with (
                patch.dict(os.environ, {}, clear=True),
                patch.object(CLEANUP, "DEFAULT_ENV_FILE", env_file),
                patch.object(CLEANUP, "cleanup_stuck_files", return_value=0) as cleanup,
            ):
                result = CLEANUP.main(["oikb_sync.py", "delete", "--dry-run"])

        self.assertEqual(result, 0)
        cleanup.assert_called_once_with(
            "http://webui.example",
            "webui-secret",
            [],
            True,
        )

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

    def test_discover_sources_uses_all_sources_when_order_is_empty(self) -> None:
        """source順未指定時にOIKBの全sourceを設定順で解決する。

        Args:
            なし。

        Returns:
            なし。
        """
        states = {
            "nextcloud:/oikb": {
                "name": "nextcloud-documents",
                "kb_id": "kb-nextcloud",
            },
            "s3://bucket": {
                "name": "rustfs-documents",
                "kb_id": "kb-rustfs",
            },
        }
        with patch.object(TRIGGER, "get_source_states", return_value=states):
            result = TRIGGER.discover_sources("http://oikb", [])

        self.assertEqual(
            result,
            [
                TRIGGER.SourceConfig(
                    "nextcloud:/oikb",
                    "nextcloud-documents",
                    "kb-nextcloud",
                ),
                TRIGGER.SourceConfig(
                    "s3://bucket",
                    "rustfs-documents",
                    "kb-rustfs",
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

    def test_preview_sync_logs_unsynced_files(self) -> None:
        """trigger dry-runは追加または更新が必要なfileをlogへ記録する。"""
        source = TRIGGER.SourceConfig("source-key", "source name", "kb-a")
        response = {
            "dry_run": True,
            "kb_id": "kb-a",
            "result": {
                "added": 1,
                "modified": 1,
                "unmodified": 2,
                "files": [
                    {"action": "added", "path": "new.pdf"},
                    {"action": "modified", "path": "docs/updated.pdf"},
                ],
            },
        }
        with (
            patch.object(TRIGGER, "request_json", return_value=response),
            self.assertLogs(TRIGGER.LOGGER, level="INFO") as logs,
        ):
            count = TRIGGER.preview_sync("http://oikb", "secret", source)

        self.assertEqual(count, 2)
        self.assertTrue(any("file=new.pdf" in line for line in logs.output))
        self.assertTrue(any("file=docs/updated.pdf" in line for line in logs.output))

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

    def test_existing_pending_timeout_reports_cleanup_action(self) -> None:
        """sync前のpending timeoutでは英語のcleanup手順を報告する。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 10]),
            self.assertRaisesRegex(
                TimeoutError,
                r"Existing Open WebUI files timed out.*oikb_sync\.py delete",
            ),
        ):
            TRIGGER.wait_for_existing_pending_files(
                "http://open-webui",
                "webui-secret",
                source,
                poll_interval_seconds=1,
                timeout_seconds=10,
            )

    def test_existing_pending_files_are_waited_until_cleared(self) -> None:
        """同期開始前のpending fileが正常に完了するまで待つ。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(
                TRIGGER,
                "get_pending_files_by_id",
                side_effect=[{"pending-a": "pending.pdf"}, {}],
            ),
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1, 2]),
            patch.object(TRIGGER.time, "sleep") as sleep,
        ):
            TRIGGER.wait_for_existing_pending_files(
                "http://open-webui",
                "webui-secret",
                source,
                poll_interval_seconds=1,
                timeout_seconds=10,
            )

        sleep.assert_called_once_with(1)

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
            patch.object(
                TRIGGER,
                "get_pending_files_by_id",
                return_value={},
            ) as get_pending_files_by_id,
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1, 2, 3]),
            patch.object(TRIGGER.time, "sleep"),
        ):
            result = TRIGGER.wait_for_oikb_sync(
                "http://oikb",
                "http://open-webui",
                "webui-secret",
                source,
                previous_last_sync=90.0,
                triggered_at=100.0,
                poll_interval_seconds=1,
                timeout_seconds=10,
            )

        self.assertEqual(result["last_sync"], 101.0)
        get_pending_files_by_id.assert_called_once()

    def test_wait_for_oikb_sync_logs_pending_filename(self) -> None:
        """OIKB同期待機中に現在処理中のfile名をlogへ出力する。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        states = [
            {"source-key": {"status": "running", "last_sync": None}},
            {"source-key": {"status": "success", "last_sync": 101.0}},
        ]
        with (
            patch.object(TRIGGER, "get_source_states", side_effect=states),
            patch.object(
                TRIGGER,
                "get_pending_files_by_id",
                return_value={"file-a": "manual.pdf"},
            ),
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1, 2]),
            patch.object(TRIGGER.time, "sleep"),
            self.assertLogs(TRIGGER.LOGGER, level="INFO") as logs,
        ):
            TRIGGER.wait_for_oikb_sync(
                "http://oikb",
                "http://open-webui",
                "webui-secret",
                source,
                previous_last_sync=None,
                triggered_at=100.0,
                poll_interval_seconds=3,
                timeout_seconds=10,
            )

        self.assertIn(
            "Processing Open WebUI file: source=source-a file=manual.pdf",
            logs.output[0],
        )

    def test_registration_waits_for_completed_link_and_empty_pending(self) -> None:
        """new fileの処理完了、link、pending解消が揃うまで待つ。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(
                TRIGGER,
                "list_knowledge_files",
                return_value=[
                    {"id": "old", "data": {"status": "completed"}},
                    {"id": "new", "data": {"status": "completed"}},
                ],
            ) as list_knowledge_files,
            patch.object(
                TRIGGER,
                "get_pending_files_by_id",
                side_effect=[{"new": "new.pdf"}, {}],
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

        list_knowledge_files.assert_called_once_with(
            "http://open-webui",
            "webui-secret",
            "kb-a",
        )

    def test_registration_waits_until_every_kb_file_is_completed(self) -> None:
        """KB内にprocessing fileがあればcompletedになるまで待つ。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(TRIGGER, "get_pending_files_by_id", return_value={}),
            patch.object(
                TRIGGER,
                "list_knowledge_files",
                side_effect=[
                    [{"id": "old", "data": {"status": "processing"}}],
                    [{"id": "old", "data": {"status": "completed"}}],
                ],
            ),
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1, 2]),
            patch.object(TRIGGER.time, "sleep") as sleep,
        ):
            TRIGGER.wait_for_open_webui_registration(
                "http://open-webui",
                "webui-secret",
                source,
                {"old"},
                {"files_added": 0, "files_modified": 0, "files_deleted": 0},
                poll_interval_seconds=1,
                timeout_seconds=10,
            )

        sleep.assert_called_once_with(1)

    def test_registration_uses_file_search_when_status_is_omitted(self) -> None:
        """Knowledge一覧で省略されたstatusをfile検索結果から補完する。

        Args:
            なし。

        Returns:
            なし。
        """
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(TRIGGER, "get_pending_files_by_id", return_value={}),
            patch.object(
                TRIGGER,
                "list_knowledge_files",
                return_value=[{"id": "old", "filename": "old.pdf", "data": None}],
            ),
            patch.object(
                TRIGGER,
                "list_open_webui_files",
                return_value=[
                    {
                        "id": "old",
                        "filename": "old.pdf",
                        "data": {"status": "completed"},
                    }
                ],
            ) as list_open_webui_files,
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1, 10]),
            patch.object(TRIGGER.time, "sleep"),
        ):
            TRIGGER.wait_for_open_webui_registration(
                "http://open-webui",
                "webui-secret",
                source,
                {"old"},
                {"files_added": 0, "files_modified": 0, "files_deleted": 0},
                poll_interval_seconds=1,
                timeout_seconds=10,
            )

        list_open_webui_files.assert_called_once_with(
            "http://open-webui",
            "webui-secret",
        )

    def test_registration_rejects_missing_link_after_pending_clears(self) -> None:
        """pending解消後にlink不足があれば即座に失敗する。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(
                TRIGGER,
                "list_knowledge_files",
                return_value=[{"id": "old", "data": {"status": "completed"}}],
            ),
            patch.object(TRIGGER, "get_pending_files_by_id", return_value={}),
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1]),
            self.assertRaisesRegex(ValueError, "file count mismatch"),
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

    def test_registration_rejects_concurrent_upload(self) -> None:
        """期待数を超えるpending fileがあれば同時uploadとして失敗する。"""
        source = TRIGGER.SourceConfig("source-key", "source-a", "kb-a")
        with (
            patch.object(
                TRIGGER,
                "get_pending_files_by_id",
                return_value={"new": "new.pdf", "other": "other.pdf"},
            ),
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1]),
            self.assertRaisesRegex(ValueError, "Detected another upload"),
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

    def test_fast_noop_sync_advances_to_next_source(self) -> None:
        """高速な差分なし同期が完了したら次のsourceへ進む。

        Args:
            なし。

        Returns:
            なし。
        """
        sources = [
            TRIGGER.SourceConfig("key-a", "a", "kb-a"),
            TRIGGER.SourceConfig("key-b", "b", "kb-b"),
        ]
        source_states = [
            {"key-a": {"status": "success", "last_sync": 90.0}},
            {"key-a": {"status": "success", "last_sync": 100.0}},
            {"key-b": {"status": "success", "last_sync": 190.0}},
            {"key-b": {"status": "success", "last_sync": 200.0}},
        ]
        history = {
            "files_added": 0,
            "files_modified": 0,
            "files_deleted": 0,
        }
        with (
            patch.object(TRIGGER, "discover_sources", return_value=sources),
            patch.object(TRIGGER, "get_source_states", side_effect=source_states),
            patch.object(TRIGGER, "wait_for_existing_pending_files"),
            patch.object(
                TRIGGER,
                "list_linked_file_ids",
                side_effect=[{"file-a"}, {"file-b"}],
            ),
            patch.object(TRIGGER, "trigger_sync") as trigger_sync,
            patch.object(TRIGGER, "wait_for_sync_history", return_value=history),
            patch.object(TRIGGER, "get_pending_files_by_id", return_value={}),
            patch.object(
                TRIGGER,
                "list_knowledge_files",
                side_effect=[
                    [{"id": "file-a", "data": {"status": "completed"}}],
                    [{"id": "file-b", "data": {"status": "completed"}}],
                ],
            ),
            patch.object(TRIGGER.time, "time", side_effect=[100.5, 200.5]),
            patch.object(TRIGGER.time, "monotonic", side_effect=range(20)),
            patch.object(TRIGGER.time, "sleep"),
        ):
            count = TRIGGER.trigger_all_syncs(
                "http://oikb",
                "oikb-secret",
                "http://open-webui",
                "webui-secret",
                ["a", "b"],
                1,
                10,
                10,
            )

        self.assertEqual(count, 2)
        self.assertEqual(
            [args.args[2] for args in trigger_sync.call_args_list],
            sources,
        )

    def test_sync_source_resumes_running_source(self) -> None:
        """中断後の再実行では進行中sourceの待機を継続する。

        Args:
            なし。

        Returns:
            なし。
        """
        source = TRIGGER.SourceConfig("key-a", "a", "kb-a")
        state = {
            "status": "running",
            "started_at": 100.0,
            "last_sync": 90.0,
        }
        history = {
            "files_added": 1,
            "files_modified": 0,
            "files_deleted": 0,
        }
        with (
            patch.object(TRIGGER, "get_source_states", return_value={"key-a": state}),
            patch.object(TRIGGER, "wait_for_existing_pending_files") as wait_existing,
            patch.object(TRIGGER, "list_linked_file_ids") as list_linked,
            patch.object(TRIGGER, "trigger_sync") as trigger_sync,
            patch.object(
                TRIGGER,
                "wait_for_oikb_sync",
                return_value={"status": "success", "last_sync": 101.0},
            ) as wait_for_oikb_sync,
            patch.object(TRIGGER, "wait_for_sync_history", return_value=history),
            patch.object(TRIGGER, "get_pending_files_by_id", return_value={}),
            patch.object(
                TRIGGER,
                "list_knowledge_files",
                return_value=[
                    {"id": "old", "data": {"status": "completed"}},
                    {"id": "new", "data": {"status": "completed"}},
                ],
            ),
            patch.object(TRIGGER.time, "monotonic", side_effect=[0, 1]),
        ):
            TRIGGER.sync_source(
                "http://oikb",
                "oikb-secret",
                "http://open-webui",
                "webui-secret",
                source,
                1,
                10,
                10,
            )

        wait_existing.assert_not_called()
        list_linked.assert_not_called()
        trigger_sync.assert_not_called()
        wait_for_oikb_sync.assert_called_once_with(
            "http://oikb",
            "http://open-webui",
            "webui-secret",
            source,
            90.0,
            100.0,
            1,
            10,
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
                "OIKB_API_URL=http://oikb.example\n"
                "OIKB_API_KEY=oikb-secret\n"
                "OPEN_WEBUI_API_URL=http://webui.example\n"
                "OPEN_WEBUI_API_KEY=webui-secret\n"
                "OIKB_SOURCE_ORDER=rustfs-documents,nextcloud-documents\n",
                encoding="utf-8",
            )
            with (
                patch.dict(os.environ, {}, clear=True),
                patch.object(TRIGGER, "DEFAULT_ENV_FILE", env_file),
                patch.object(TRIGGER, "trigger_all_syncs", return_value=2) as trigger,
            ):
                result = TRIGGER.main(["oikb_sync.py", "trigger"])

        self.assertEqual(result, 0)
        trigger.assert_called_once_with(
            "http://oikb.example",
            "oikb-secret",
            "http://webui.example",
            "webui-secret",
            ["rustfs-documents", "nextcloud-documents"],
            3,
            21600,
            21600,
        )

    def test_main_without_source_order_triggers_all_sources(self) -> None:
        """OIKB_SOURCE_ORDER未設定時に全source検出を指示する。

        Args:
            なし。

        Returns:
            なし。
        """
        with tempfile.TemporaryDirectory() as temporary_directory:
            env_file = Path(temporary_directory) / ".env"
            env_file.write_text(
                "OIKB_API_KEY=oikb-secret\n"
                "OPEN_WEBUI_API_KEY=webui-secret\n",
                encoding="utf-8",
            )
            with (
                patch.dict(os.environ, {}, clear=True),
                patch.object(TRIGGER, "DEFAULT_ENV_FILE", env_file),
                patch.object(TRIGGER, "trigger_all_syncs", return_value=2) as trigger,
            ):
                result = TRIGGER.main(["oikb_sync.py", "trigger"])

        self.assertEqual(result, 0)
        trigger.assert_called_once_with(
            "http://localhost:32001",
            "oikb-secret",
            "http://localhost:32000",
            "webui-secret",
            [],
            3,
            21600,
            21600,
        )


class OikbImagePatchTest(unittest.TestCase):
    """OIKB imageへ適用するOpen WebUI連携patchを検証する。"""

    def test_compose_runs_external_scheduler(self) -> None:
        """Composeがexternal schedulerをwatch modeで常駐実行することを検証する。

        Args:
            なし。

        Returns:
            なし。
        """
        compose = (REPO_ROOT / "20-owui/docker-compose.yml").read_text(
            encoding="utf-8"
        )
        _, marker, remaining = compose.partition("  oikb-scheduler:\n")

        self.assertTrue(marker)
        scheduler = remaining.partition("\n  oikb:\n")[0]
        for expected in (
            "restart: unless-stopped",
            "- /app/scripts/oikb/oikb_sync.py",
            "- trigger",
            "- --watch",
            "OIKB_API_URL: http://oikb:8080",
            "OPEN_WEBUI_API_URL: http://open-webui:8080",
            "OIKB_TRIGGER_INTERVAL_SECONDS:",
            "../scripts/oikb/oikb_sync.py:/app/scripts/oikb/oikb_sync.py:ro",
            "condition: service_healthy",
        ):
            self.assertIn(expected, scheduler)

    def test_upload_waits_for_open_webui_processing(self) -> None:
        """file uploadが解析とKnowledge登録の完了まで待つようpatchする。"""
        patch_module = load_script(
            "patch_openwebui_synchronous_upload",
            "20-owui/oikb/patch-openwebui-synchronous-upload.py",
        )
        source = """        resp = self._http.post(
            "/files/",
            files={"file": (filename, file_content)},
            data={"metadata": json.dumps(metadata)},
        )
"""

        patched = patch_module.patch_source(source)

        self.assertIn(
            'params={"process_in_background": "false"}',
            patched,
        )
        containerfile = (REPO_ROOT / "20-owui/oikb/Containerfile").read_text(
            encoding="utf-8"
        )
        self.assertIn("patch-openwebui-synchronous-upload.py", containerfile)

    def test_oikb2_waits_for_each_file_registration(self) -> None:
        """OIKB2がfile処理、retry、Knowledge linkを順に実行する。

        Args:
            なし。

        Returns:
            なし。
        """
        patch_module = load_script(
            "patch_openwebui_sequential_registration",
            "20-owui/oikb2/patch-openwebui-sequential-registration.py",
        )
        source = '''import json
from typing import Any

class Client:
    def upload_file(
        self,
        file_content: bytes,
        filename: str,
        kb_id: str,
        file_hash: str,
        directory_id: str | None = None,
    ) -> dict[str, Any]:
        """POST /files/ — upload a single file to the KB."""

        metadata: dict[str, Any] = {
            "knowledge_id": kb_id,
            "file_hash": file_hash,
        }
        if directory_id:
            metadata["directory_id"] = directory_id

        resp = self._http.post(
            "/files/",
            files={"file": (filename, file_content)},
            data={"metadata": json.dumps(metadata)},
        )
        resp.raise_for_status()
        return resp.json()
'''

        patched = patch_module.patch_source(source)

        self.assertIn("import logging", patched)
        self.assertIn('params={"process_in_background": "false"}', patched)
        self.assertIn("/process/status", patched)
        self.assertIn('f"/knowledge/{kb_id}/files"', patched)
        self.assertIn("for attempt in range(2):", patched)
        self.assertIn('self._http.delete(f"/files/{file_id}")', patched)
        self.assertIn("OIKB2 retrying file", patched)
        self.assertIn("Open WebUI file retry failed", patched)
        self.assertLess(
            patched.index("OIKB2 processing file"),
            patched.index("self._http.post("),
        )
        self.assertLess(
            patched.index('status == "completed" and linked'),
            patched.index("OIKB2 registered file"),
        )
        self.assertLess(
            patched.index("OIKB2 registered file"),
            patched.index("return uploaded_file"),
        )
        containerfile = (REPO_ROOT / "20-owui/oikb2/Containerfile").read_text(
            encoding="utf-8"
        )
        self.assertIn("patch-openwebui-sequential-registration.py", containerfile)
        compose = (REPO_ROOT / "20-owui/docker-compose.yml").read_text(encoding="utf-8")
        self.assertIn("context: ./oikb2", compose)
        self.assertIn("./oikb2/oikb.yaml:/app/.oikb.yaml:ro", compose)

        namespace = {"__name__": "patched_oikb_client"}
        exec(patched, namespace)
        client = namespace["Client"]()
        client._http = Mock()
        client._http.timeout.read = 10

        first_upload = Mock()
        first_upload.json.return_value = {"id": "failed-file"}
        second_upload = Mock()
        second_upload.json.return_value = {"id": "completed-file"}
        failed_status = Mock()
        failed_status.json.return_value = {
            "status": "failed",
            "error": "embedding failed",
        }
        completed_status = Mock()
        completed_status.json.return_value = {"status": "completed"}
        knowledge_files = Mock()
        knowledge_files.json.return_value = {
            "items": [{"id": "completed-file"}],
            "total": 1,
        }
        client._http.post.side_effect = [first_upload, second_upload]
        client._http.get.side_effect = [
            failed_status,
            completed_status,
            knowledge_files,
        ]

        with patch.object(namespace["time"], "sleep") as sleep:
            result = client.upload_file(
                b"content",
                "manual.pdf",
                "kb-a",
                "hash-a",
            )

        self.assertEqual(result, {"id": "completed-file"})
        self.assertEqual(client._http.post.call_count, 2)
        client._http.delete.assert_called_once_with("/files/failed-file")
        sleep.assert_called_once_with(2)

    def test_oikb2_dashboard_tracks_current_file_safely(self) -> None:
        """OIKB2 dashboardが処理中のbasenameだけを安全に表示する。

        Args:
            なし。

        Returns:
            なし。
        """
        patch_source = (
            REPO_ROOT / "20-owui/oikb2/patch-daemon-external-scheduler.py"
        ).read_text(encoding="utf-8")

        self.assertIn('rsplit("/", 1)[-1]', patch_source)
        self.assertIn('["current_file"] = current_file', patch_source)
        self.assertIn('.pop("current_file", None)', patch_source)
        self.assertIn("escapeHtml(s.current_file)", patch_source)
        self.assertLess(
            patch_source.index('["current_file"] = current_file'),
            patch_source.index("finally:"),
        )

    def test_oikb2_upload_state_wrapper_preserves_kb_id_keyword(self) -> None:
        """upload wrapperがupstreamのkb_id keyword契約を維持する。

        Args:
            なし。

        Returns:
            なし。
        """
        patch_source = (
            REPO_ROOT / "20-owui/oikb2/patch-daemon-external-scheduler.py"
        ).read_text(encoding="utf-8")

        self.assertIn("            kb_id: str,", patch_source)
        self.assertNotIn("upload_kb_id", patch_source)


class OpenWebUiDoclingPatchTest(unittest.TestCase):
    """Open WebUIのDocling向けPDF分割patchを検証する。"""

    def test_large_pdf_is_sent_in_page_batches(self) -> None:
        """1001ページのPDFを100ページ単位で逐次送信する。

        Args:
            なし。

        Returns:
            なし。
        """
        patch_module = load_script(
            "patch_docling_pdf_batches",
            "20-owui/open-webui/patch-docling-pdf-batches.py",
        )
        source = """class DoclingLoader:
    def load(self):
        requests.post(
            f'{self.url}/v1/convert/file',
            data={'md_page_break_placeholder': '\\f'},
        )


class Loader:
    pass
"""
        patched = patch_module.patch_source(source)

        requests = Mock()

        def write_pdf(stream: object) -> None:
            """分割PDFを表すbytesを書き込む。

            Args:
                stream: 書き込み先stream。

            Returns:
                なし。
            """
            stream.write(b"%PDF-batched")

        def post_docling(url: str, **kwargs: object) -> Mock:
            """分割file名からDocling responseを生成する。

            Args:
                url: Docling endpoint URL。
                **kwargs: multipart request引数。

            Returns:
                分割ページ数に対応したDocling response。
            """
            self.assertEqual(url, "http://docling/v1/convert/file")
            file_name, stream, content_type = kwargs["files"]["files"]
            self.assertTrue(stream.read())
            self.assertEqual(content_type, "application/pdf")
            page_range = file_name.rsplit("__pages_", 1)[1].removesuffix(".pdf")
            start_text, end_text = page_range.split("-")
            response = Mock(ok=True, reason="OK", text="")
            response.json.return_value = {
                "document": {
                    "md_content": "\f".join(
                        f"page-{page}"
                        for page in range(int(start_text), int(end_text) + 1)
                    )
                }
            }
            return response

        requests.post.side_effect = post_docling
        namespace = {
            "__name__": "patched_open_webui_loader",
            "AIOHTTP_CLIENT_SESSION_SSL": False,
            "Document": SimpleNamespace,
            "log": Mock(),
            "os": os,
            "requests": requests,
        }
        writer = Mock()
        writer.write.side_effect = write_pdf
        fake_pypdf = ModuleType("pypdf")
        fake_pypdf.PdfReader = Mock(
            return_value=SimpleNamespace(pages=list(range(1001)))
        )
        fake_pypdf.PdfWriter = Mock(return_value=writer)

        with (
            patch.dict(sys.modules, {"pypdf": fake_pypdf}),
            patch.dict(os.environ, {"DOCLING_PDF_BATCH_PAGES": "100"}),
            tempfile.NamedTemporaryFile(suffix=".pdf") as pdf_file,
        ):
            pdf_file.write(b"%PDF-original")
            pdf_file.flush()
            exec(patched, namespace)
            loader = namespace["DoclingLoader"](
                "http://docling",
                file_path=pdf_file.name,
                mime_type="application/pdf",
            )
            documents = loader.load()

        self.assertEqual(requests.post.call_count, 11)
        self.assertEqual(fake_pypdf.PdfWriter.call_count, 11)
        self.assertEqual(
            [item.args[0] for item in writer.add_page.call_args_list],
            list(range(1001)),
        )
        self.assertEqual(len(documents), 1001)
        self.assertEqual(
            [document.metadata["page"] for document in documents],
            list(range(1001)),
        )
        self.assertIn("'page_range' not in self.params", patched)
        self.assertEqual(patch_module.patch_source(patched), patched)
        entrypoint = (
            REPO_ROOT / "20-owui/open-webui/entrypoint_patch.sh"
        ).read_text(encoding="utf-8")
        compose = (REPO_ROOT / "20-owui/docker-compose.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("patch-docling-pdf-batches.py", entrypoint)
        self.assertIn(
            "DOCLING_PDF_BATCH_PAGES: ${DOCLING_PDF_BATCH_PAGES:-100}",
            compose,
        )
        self.assertIn(
            "./open-webui/patch-docling-pdf-batches.py:"
            "/run/scripts/patch-docling-pdf-batches.py:ro",
            compose,
        )


class CliHelpTest(unittest.TestCase):
    """統合CLIのhelpとsubcommandを検証する。"""

    def test_help_lists_trigger_delete_and_dry_run(self) -> None:
        """rootと各subcommandのhelpに必要な操作を表示する。"""
        parser = SYNC.build_parser()
        subparsers = parser._subparsers._group_actions[0].choices

        self.assertIn("trigger", parser.format_help())
        self.assertIn("delete", parser.format_help())
        self.assertIn("--dry-run", subparsers["trigger"].format_help())
        self.assertIn("--dry-run", subparsers["delete"].format_help())


if __name__ == "__main__":
    unittest.main()
