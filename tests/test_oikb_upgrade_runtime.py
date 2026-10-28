"""OIKB 0.6.0へ適用した逐次登録patchの実image上の回帰test。"""

from __future__ import annotations

import asyncio
import os
import unittest
from unittest.mock import Mock, patch

try:
    from oikb import cli, daemon
    from oikb.client import OikbClient
    from oikb.connectors import ManifestEntry
    from oikb.sync import run_sync
except ModuleNotFoundError as error:
    raise unittest.SkipTest("OIKB image内で実行する") from error


class OikbUpgradeRuntimeTest(unittest.TestCase):
    """更新済みOIKB imageの同期契約を確認する。"""

    def test_timeout_reaches_http_client(self) -> None:
        """環境変数の値が実際のhttpx read timeoutへ伝わる。

        Args:
            なし。

        Returns:
            なし。
        """
        with patch.dict(os.environ, {"OIKB_OPENWEBUI_TIMEOUT": "21600"}):
            client = cli._make_client("http://open-webui:8080", "test-token")
        try:
            self.assertEqual(client._http.timeout.read, 21600.0)
        finally:
            client.close()

    def test_invalid_timeout_cannot_disable_deadline(self) -> None:
        """無限値や非正値のtimeoutを拒否する。

        Args:
            なし。

        Returns:
            なし。
        """
        for value in ("inf", "nan", "0", "-1"):
            with (
                self.subTest(value=value),
                patch.dict(os.environ, {"OIKB_OPENWEBUI_TIMEOUT": value}),
                self.assertRaises(ValueError),
            ):
                cli._make_client("http://open-webui:8080", "test-token")

    def test_registration_waits_and_retries_once(self) -> None:
        """失敗fileを削除して一度だけ再試行し、KB登録後に成功する。

        Args:
            なし。

        Returns:
            なし。
        """
        client = OikbClient("http://open-webui:8080", "test-token")
        client.close()
        events = []
        http = Mock()
        http.timeout.read = 10

        def post(path, **kwargs):
            """MIMEと同期指定を記録してfile IDを返す。

            Args:
                path: API path。
                **kwargs: multipart request。

            Returns:
                upload応答。
            """
            events.append("upload")
            self.assertEqual(path, "/files/")
            self.assertEqual(kwargs["params"], {"process_in_background": "false"})
            self.assertEqual(kwargs["files"]["file"][2], "application/pdf")
            response = Mock()
            response.json.return_value = {
                "id": "bad" if events.count("upload") == 1 else "good"
            }
            return response

        def get(path, **kwargs):
            """初回失敗と再試行後の登録確認を模擬する。

            Args:
                path: API path。
                **kwargs: pagination引数。

            Returns:
                statusまたはKB file一覧。
            """
            response = Mock()
            if path.endswith("/process/status"):
                events.append("status")
                response.json.return_value = {
                    "status": "failed" if "bad" in path else "completed",
                    "error": "embedding failed" if "bad" in path else None,
                }
            else:
                events.append("kb")
                response.json.return_value = {"items": [{"id": "good"}], "total": 1}
            return response

        http.post.side_effect = post
        http.get.side_effect = get
        http.delete.side_effect = lambda path: events.append("delete") or Mock()
        client._http = http
        with patch("oikb.client.time.sleep"):
            result = client.upload_file(b"pdf", "sample.pdf", "kb-a", "hash")

        self.assertEqual(result["id"], "good")
        self.assertEqual(
            events, ["upload", "status", "delete", "upload", "status", "kb"]
        )

    def test_timeout_is_bounded_and_cleans_both_attempts(self) -> None:
        """登録待ちのtimeout後は2回で停止し両fileを削除する。

        Args:
            なし。

        Returns:
            なし。
        """
        client = OikbClient("http://open-webui:8080", "test-token")
        client.close()
        http = Mock()
        http.timeout.read = 0.1
        first_upload = Mock()
        first_upload.json.return_value = {"id": "first"}
        second_upload = Mock()
        second_upload.json.return_value = {"id": "second"}
        http.post.side_effect = [first_upload, second_upload]
        status = Mock()
        status.json.return_value = {"status": "pending"}
        kb = Mock()
        kb.json.return_value = {"items": [], "total": 0}
        http.get.side_effect = [status, kb, status, kb]
        client._http = http
        with (
            patch("oikb.client.time.monotonic", side_effect=[0, 1, 2, 3]),
            patch("oikb.client.time.sleep"),
            self.assertRaisesRegex(RuntimeError, "retry failed"),
        ):
            client.upload_file(b"pdf", "sample.pdf", "kb-a", "hash")
        self.assertEqual(http.post.call_count, 2)
        self.assertEqual(
            [call.args[0] for call in http.delete.call_args_list],
            ["/files/first", "/files/second"],
        )

    def test_cleanup_failure_does_not_create_duplicate_upload(self) -> None:
        """失敗fileを削除できない場合は再uploadを止める。

        Args:
            なし。

        Returns:
            なし。
        """
        client = OikbClient("http://open-webui:8080", "test-token")
        client.close()
        http = Mock()
        http.timeout.read = 10
        upload = Mock()
        upload.json.return_value = {"id": "failed-file"}
        http.post.return_value = upload
        status = Mock()
        status.json.return_value = {"status": "failed", "error": "conversion failed"}
        http.get.return_value = status
        http.delete.return_value.raise_for_status.side_effect = RuntimeError(
            "delete failed"
        )
        client._http = http
        with self.assertRaisesRegex(RuntimeError, "cleanup failed"):
            client.upload_file(b"pdf", "sample.pdf", "kb-a", "hash")
        http.post.assert_called_once()

    def test_dry_run_returns_details_without_writes(self) -> None:
        """dry-runはfile詳細を返しcleanupとuploadを実行しない。

        Args:
            なし。

        Returns:
            なし。
        """
        connector = Mock()
        connector.build_manifest.return_value = [
            ManifestEntry("a.md", "docs", "hash", 10)
        ]
        client = Mock()
        client.sync_diff.return_value = {
            "added": [{"path": "docs", "filename": "a.md"}],
            "modified": [],
            "deleted": [],
            "mkdir": [],
            "rmdir": [],
        }
        with patch("oikb.sync.click.echo"):
            result = run_sync(client, connector, "kb-a", dry_run=True, quiet=True)
        self.assertEqual(result.files, [{"action": "added", "path": "docs/a.md"}])
        client.upload_file.assert_not_called()
        client.sync_cleanup.assert_not_called()
        client.create_directory.assert_not_called()

    def test_failed_file_stops_remaining_uploads(self) -> None:
        """同一sourceで最初のfileが失敗したら次を送らない。

        Args:
            なし。

        Returns:
            なし。
        """
        connector = Mock()
        connector.build_manifest.return_value = [
            ManifestEntry("a.pdf", "", "hash-a", 10),
            ManifestEntry("b.pdf", "", "hash-b", 10),
        ]
        connector.read_file.return_value = b"pdf"
        client = Mock()
        client.sync_diff.return_value = {
            "added": [
                {"path": "", "filename": "a.pdf"},
                {"path": "", "filename": "b.pdf"},
            ],
            "modified": [],
            "deleted": [],
            "mkdir": [],
            "rmdir": [],
        }
        client.upload_file.side_effect = RuntimeError("conversion failed")
        with patch("oikb.sync.click.echo"):
            result = run_sync(client, connector, "kb-a", quiet=True)
        self.assertEqual(len(result.errors), 1)
        client.upload_file.assert_called_once()


class OikbDaemonRuntimeTest(unittest.IsolatedAsyncioTestCase):
    """daemonのKB間逐次性と状態遷移を確認する。"""

    async def test_different_kbs_do_not_overlap(self) -> None:
        """異なるKBへの手動実行も同時には処理しない。

        Args:
            なし。

        Returns:
            なし。
        """
        active = 0
        maximum = 0

        async def run_locked(entry, dry_run=False):
            """同時実行数を記録する。

            Args:
                entry: 同期source。
                dry_run: dry-run指定。

            Returns:
                なし。
            """
            nonlocal active, maximum
            active += 1
            maximum = max(maximum, active)
            await asyncio.sleep(0.01)
            active -= 1

        entries = [{"source": "a", "kb-id": "kb-a"}, {"source": "b", "kb-id": "kb-b"}]
        with (
            patch.object(daemon, "_run_entry_locked", side_effect=run_locked),
            patch.object(daemon, "_sync_locks", {}),
            patch.object(daemon, "_all_sync_lock", asyncio.Lock()),
        ):
            await asyncio.gather(*(daemon._run_entry(entry) for entry in entries))
        self.assertEqual(maximum, 1)

    async def test_scheduler_stops_after_first_failure(self) -> None:
        """先行KBの部分失敗後に次のKBを開始しない。

        Args:
            なし。

        Returns:
            なし。
        """
        entries = [{"source": "a", "kb-id": "kb-a"}, {"source": "b", "kb-id": "kb-b"}]
        started = []

        async def run_entry(entry):
            """最初のKBを部分失敗へ遷移させる。

            Args:
                entry: 同期source。

            Returns:
                なし。
            """
            started.append(entry["source"])
            daemon._scheduler_state[entry["source"]] = {"status": "partial"}
            daemon._shutdown_event.set()

        with (
            patch.object(daemon, "_run_entry", side_effect=run_entry),
            patch.object(daemon, "_entries", entries),
            patch.object(daemon, "_scheduler_state", {}),
        ):
            await daemon._run_scheduler(entries)
        self.assertEqual(started, ["a"])

    async def test_scheduler_runs_each_kb_group_in_configured_order(self) -> None:
        """同一KBを一度だけ処理し、異なるKBへ設定順に進む。

        Args:
            なし。

        Returns:
            なし。
        """
        entries = [
            {"source": "a", "kb-id": "kb-a"},
            {"source": "a2", "kb-id": "kb-a"},
            {"source": "b", "kb-id": "kb-b"},
        ]
        started = []

        async def run_entry(entry):
            """処理順序と成功状態を記録する。

            Args:
                entry: 同期source。

            Returns:
                なし。
            """
            started.append(entry["source"])
            daemon._scheduler_state[entry["source"]] = {"status": "success"}
            if len(started) == 2:
                daemon._shutdown_event.set()

        with (
            patch.object(daemon, "_run_entry", side_effect=run_entry),
            patch.object(daemon, "_entries", entries),
            patch.object(daemon, "_scheduler_state", {}),
        ):
            await daemon._run_scheduler(entries)
        self.assertEqual(started, ["a", "b"])

    async def test_dry_run_returns_to_idle(self) -> None:
        """daemon dry-runの後はidleとfile詳細を返す。

        Args:
            なし。

        Returns:
            なし。
        """
        from oikb.sync import SyncResult

        entry = {"source": "a", "kb-id": "kb-a"}
        result = SyncResult(added=1, files=[{"action": "added", "path": "a.md"}])
        with (
            patch.object(daemon, "_entries", [entry]),
            patch.object(daemon, "_scheduler_state", {"a": {"status": "idle"}}),
            patch.object(daemon, "_sync_locks", {}),
            patch.object(daemon, "_all_sync_lock", asyncio.Lock()),
            patch.object(daemon, "_shutdown_event", asyncio.Event()),
            patch("oikb.cli._make_client", return_value=Mock()),
            patch("oikb.kb_sync.run_entries_sync", return_value=result),
        ):
            payload = await daemon._run_entry(entry, dry_run=True)
            self.assertEqual(daemon._scheduler_state["a"]["status"], "idle")
        self.assertEqual(payload["files"], [{"action": "added", "path": "a.md"}])
