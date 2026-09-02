"""QwenPaw起動前設定の最小回帰test。"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

# repository rootからのtest実行でも同じdirectoryのmoduleを解決する。
sys.path.insert(0, str(Path(__file__).resolve().parent))

from configure import MODEL_IDS, configure


class ConfigureTest(unittest.TestCase):
    """DiscordとLiteLLM設定の生成結果を検証する。"""

    def test_configure_enables_discord_and_three_models(self) -> None:
        """既存agentを保ったままDiscordと3モデルを設定する。"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            working_dir = root / "working"
            secret_dir = root / "secret"
            agent_path = working_dir / "workspaces" / "default" / "agent.json"
            agent_path.parent.mkdir(parents=True)
            agent_path.write_text(
                json.dumps(
                    {
                        "id": "default",
                        "channels": {
                            "console": {"enabled": False},
                            "discord": {"enabled": False},
                        },
                        "running": {"max_iters": 50},
                    },
                ),
                encoding="utf-8",
            )

            with patch.dict(
                os.environ,
                {
                    "QWENPAW_DISCORD_BOT_TOKEN": "discord-secret",
                    "LITELLM_MASTER_KEY": "litellm-secret",
                },
            ):
                configure(working_dir, secret_dir)

            agent = json.loads(agent_path.read_text(encoding="utf-8"))
            provider = json.loads(
                (secret_dir / "providers" / "custom" / "litellm.json").read_text(
                    encoding="utf-8",
                ),
            )
            active_model = json.loads(
                (secret_dir / "providers" / "active_model.json").read_text(
                    encoding="utf-8",
                ),
            )

            self.assertTrue(agent["channels"]["console"]["enabled"])
            self.assertTrue(agent["channels"]["discord"]["enabled"])
            self.assertEqual(
                agent["channels"]["discord"]["bot_token"],
                "discord-secret",
            )
            self.assertEqual(
                [model["id"] for model in provider["extra_models"]],
                list(MODEL_IDS),
            )
            self.assertEqual(active_model["model"], MODEL_IDS[0])
            self.assertEqual(agent["running"], {"max_iters": 50})


if __name__ == "__main__":
    unittest.main()
