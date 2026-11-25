"""稼働中のOpen WebUIに対するAgent SkillsのContract Test。

Skillの例が前提とするresponse形状と、API keyのallowlistによる拒否を実機で確認する。
Open WebUIのupgrade後や`API_KEYS_ALLOWED_ENDPOINTS`の変更後に実行する。
副作用の無いGETと、拒否されることを期待するrequestだけを送る。

実行には一般userのAPI keyを使う。環境変数が無い場合はskipする。

    OWUI_CONTRACT_BASE_URL       例: http://localhost:32000
    OWUI_CONTRACT_API_KEY_FILE   API keyを1行で保存したfile (mode 600)
"""

from __future__ import annotations

import json
import os
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

BASE_URL = os.environ.get("OWUI_CONTRACT_BASE_URL", "").rstrip("/")
KEY_FILE = os.environ.get("OWUI_CONTRACT_API_KEY_FILE", "")

# Skillの例が参照するpathと、responseの型 (list) またはobjectが持つkey。
SHAPES: dict[str, type | frozenset[str]] = {
    "/api/models": frozenset({"data"}),
    "/api/v1/knowledge/": frozenset({"items", "total"}),
    "/api/v1/files/": frozenset({"items", "total"}),
    "/api/v1/tools/": list,
    "/api/v1/memories/": list,
    "/api/v1/notes/search?query=contract": frozenset({"items", "total"}),
    "/api/v1/chats/": list,
    "/api/v1/folders/": list,
    "/api/v1/calendars/": list,
    "/api/v1/channels/": list,
    "/api/v1/prompts/": list,
    "/api/v1/skills/": list,
    "/api/v1/images/models": list,
    "/api/v1/evaluations/feedbacks/user": frozenset({"items", "total"}),
    "/api/v1/notifications/inbox": frozenset({"items", "next_cursor"}),
    "/api/v1/search?q=contract": frozenset({"items", "kinds", "scopes", "has_more"}),
}

# API keyでは到達できないこと (403) を期待するrequest。再帰起動、管理機能、認証、code実行。
FORBIDDEN: tuple[tuple[str, str], ...] = (
    ("POST", "/api/chat/completions"),
    ("POST", "/api/v1/chat/completions"),
    ("POST", "/api/v1/messages"),
    ("GET", "/api/v1/terminals/"),
    ("POST", "/api/v1/automations/create"),
    ("GET", "/api/v1/auths/"),
    ("GET", "/api/v1/users/"),
    ("GET", "/api/v1/configs/export"),
    ("POST", "/api/v1/utils/code/execute"),
    ("GET", "/api/v1/apps"),
)


def request(method: str, path: str, key: str) -> tuple[int, Any]:
    """Open WebUIへrequestを送る。

    Args:
        method: HTTP method。
        path: query stringを含むpath。
        key: API key。

    Returns:
        HTTP statusと、JSONとして読めた場合はその値 (読めない場合None)。
    """
    data = b"{}" if method in {"POST", "PUT", "PATCH"} else None
    req = urllib.request.Request(
        BASE_URL + path,
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read()
    try:
        return status, json.loads(body)
    except ValueError:
        return status, None


@unittest.skipUnless(BASE_URL and KEY_FILE, "OWUI_CONTRACT_BASE_URLとOWUI_CONTRACT_API_KEY_FILEを指定する")
class OwuiContractTest(unittest.TestCase):
    """稼働中のOpen WebUIとSkillの前提が一致することを検査する。"""

    key: str

    @classmethod
    def setUpClass(cls) -> None:
        """API keyを読み込む。"""
        cls.key = Path(KEY_FILE).read_text(encoding="utf-8").strip()

    def test_skill_endpoints_return_expected_shape(self) -> None:
        """Skillが使うendpointは200で、例が参照する形状を返す。"""
        for path, shape in SHAPES.items():
            with self.subTest(path=path):
                status, body = request("GET", path, self.key)
                self.assertEqual(status, 200)
                if shape is list:
                    self.assertIsInstance(body, list)
                else:
                    self.assertIsInstance(body, dict)
                    self.assertLessEqual(shape, set(body))

    def test_recursion_admin_and_auth_endpoints_are_forbidden(self) -> None:
        """再帰起動、管理、認証、code実行のAPIはAPI keyで403になる。"""
        for method, path in FORBIDDEN:
            with self.subTest(method=method, path=path):
                status, _ = request(method, path, self.key)
                self.assertEqual(status, 403)


if __name__ == "__main__":
    unittest.main()
