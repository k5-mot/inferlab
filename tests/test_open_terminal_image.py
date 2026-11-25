"""Open Terminal派生imageのDockerfile群の整合性test。

閉域build用の`Dockerfile.offline`と、online build用の`Dockerfile`は、PiとOfficeCLIの導入方法だけが異なる。
片方だけを更新して導入物が食い違わないよう、共通部分の一致と、版の固定先を検査する。
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

OPEN_TERMINAL_DIR = Path(__file__).resolve().parents[1] / "20-owui" / "open-terminal"
MARKER = "# ---- DockerfileとDockerfile.offlineで共通"


def common_part(dockerfile: Path) -> str:
    """Dockerfileの共通部分 (目印のcomment以降) を返す。

    Args:
        dockerfile: Dockerfileのpath。

    Returns:
        目印のcommentから末尾までの文字列。

    Raises:
        AssertionError: 目印のcommentが無い場合。
    """
    text = dockerfile.read_text(encoding="utf-8")
    index = text.find(MARKER)
    if index < 0:
        raise AssertionError(f"marker not found: {dockerfile}")
    return text[index:]


class OpenTerminalImageTest(unittest.TestCase):
    """DockerfileとDockerfile.offlineの整合性を検査する。"""

    def test_common_part_is_identical(self) -> None:
        """目印以降の導入内容は2つのDockerfileで一致する。"""
        self.assertEqual(
            common_part(OPEN_TERMINAL_DIR / "Dockerfile"),
            common_part(OPEN_TERMINAL_DIR / "Dockerfile.offline"),
        )

    def test_same_base_image(self) -> None:
        """2つのDockerfileは同じbase imageを使う。"""
        bases = {
            re.search(
                r"^FROM (\S+)",
                (OPEN_TERMINAL_DIR / name).read_text(encoding="utf-8"),
                re.MULTILINE,
            ).group(1)
            for name in ("Dockerfile", "Dockerfile.offline")
        }
        self.assertEqual(len(bases), 1, bases)

    def test_versions_are_pinned_in_lockfile(self) -> None:
        """PiとOfficeCLIはpackage.jsonで完全固定し、lockfileと一致する。"""
        manifest = json.loads(
            (OPEN_TERMINAL_DIR / "npm" / "package.json").read_text(encoding="utf-8")
        )
        lock = json.loads(
            (OPEN_TERMINAL_DIR / "npm" / "package-lock.json").read_text(
                encoding="utf-8"
            )
        )
        for name, version in manifest["dependencies"].items():
            self.assertRegex(version, r"^\d+\.\d+\.\d+$", name)
            self.assertEqual(
                lock["packages"][f"node_modules/{name}"]["version"], version, name
            )


if __name__ == "__main__":
    unittest.main()
