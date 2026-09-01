"""Open WebUI/OIKB保守scriptのunit test。"""

from __future__ import annotations

import importlib.util
import io
import json
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


def json_response(payload: object) -> io.BytesIO:
    """urlopenのmock用JSON byte streamを作成する。

    Args:
        payload: JSONへ変換する値。

    Returns:
        context managerとして利用できるbyte stream。
    """
    return io.BytesIO(json.dumps(payload).encode())


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
    """OIKB同期triggerの対象検出とrequestを検証する。"""

    def test_discover_source_names_uses_health_response(self) -> None:
        """OIKB healthからsource設定名を重複なく取得する。"""
        health = {
            "sources": {
                "nextcloud:/oikb": {"name": "nextcloud-documents"},
                "s3://bucket": {"name": "rustfs-documents"},
            }
        }
        with patch.object(TRIGGER, "urlopen", return_value=json_response(health)):
            result = TRIGGER.discover_source_names("http://oikb")

        self.assertEqual(result, ["nextcloud-documents", "rustfs-documents"])

    def test_trigger_sync_posts_encoded_source_name(self) -> None:
        """source名をURL encodeして認証付きPOSTを送る。"""
        with patch.object(
            TRIGGER, "request_json", return_value={"triggered": True}
        ) as request_json:
            TRIGGER.trigger_sync("http://oikb/", "secret", "source name")

        request_json.assert_called_once_with(
            "POST",
            "http://oikb/sync/source%20name",
            "secret",
        )

    def test_trigger_all_syncs_triggers_every_registered_source(self) -> None:
        """healthへ登録された全sourceを1回ずつtriggerする。"""
        with (
            patch.object(TRIGGER, "discover_source_names", return_value=["a", "b"]),
            patch.object(TRIGGER, "trigger_sync") as trigger_sync,
        ):
            count = TRIGGER.trigger_all_syncs("http://oikb", "secret")

        self.assertEqual(count, 2)
        self.assertEqual(
            trigger_sync.call_args_list,
            [call("http://oikb", "secret", "a"), call("http://oikb", "secret", "b")],
        )

    def test_scheduler_waits_configured_interval(self) -> None:
        """各trigger周期の後に指定された秒数だけ待機する。"""
        with (
            patch.object(TRIGGER, "trigger_all_syncs", return_value=2),
            patch.object(TRIGGER.time, "sleep", side_effect=KeyboardInterrupt) as sleep,
            self.assertRaises(KeyboardInterrupt),
        ):
            TRIGGER.run_scheduler("http://oikb", "secret", 3600)

        sleep.assert_called_once_with(3600)

    def test_main_loads_env_file_before_parsing_defaults(self) -> None:
        """mainはrepository rootの.envを同期triggerへ反映する。"""
        with tempfile.TemporaryDirectory() as temporary_directory:
            env_file = Path(temporary_directory) / ".env"
            env_file.write_text("OIKB_API_KEY=oikb-secret\n", encoding="utf-8")
            with (
                patch.dict(os.environ, {}, clear=True),
                patch.object(TRIGGER, "DEFAULT_ENV_FILE", env_file),
                patch.object(TRIGGER, "trigger_all_syncs", return_value=2) as trigger,
            ):
                result = TRIGGER.main(["trigger_oikb_syncs.py", "--once"])

        self.assertEqual(result, 0)
        trigger.assert_called_once_with("http://localhost:32001", "oikb-secret")


if __name__ == "__main__":
    unittest.main()
