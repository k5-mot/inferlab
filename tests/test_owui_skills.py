"""Open WebUI Agent Skillsの整合性test。

API keyのallowlist (Compose)、共通client`owui-api`のprefix、reference生成scriptのSkill定義は、
どれか1つだけを更新すると権限境界とskillの説明が食い違う。ここで3者と生成物の一致を検査する。
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
SKILLS_DIR = REPO_ROOT / "20-owui" / "skills"
SCHEMA = REPO_ROOT / "scripts" / "owui-skills" / "openapi" / "open-webui-v0.13.4.json"
GENERATOR = REPO_ROOT / "scripts" / "owui-skills" / "generate_api_reference.py"
# Skill以外の既存clientが使うprefix。Hermes (channels、chats) とOIKB (files、knowledge)。
NON_SKILL_PREFIXES = {"/api/v1/chats", "/api/v1/channels", "/api/v1/files", "/api/v1/knowledge"}


def load_generator() -> ModuleType:
    """reference生成scriptをmoduleとして読み込む。

    Returns:
        読み込んだmodule。

    Raises:
        RuntimeError: module specを作成できない場合。
    """
    spec = importlib.util.spec_from_file_location("generate_api_reference", GENERATOR)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {GENERATOR}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def compose_allowlist() -> set[str]:
    """`20-owui/docker-compose.yml`のAPI_KEYS_ALLOWED_ENDPOINTSを読む。

    Returns:
        allowlistのprefix集合。
    """
    compose = yaml.safe_load((REPO_ROOT / "20-owui" / "docker-compose.yml").read_text(encoding="utf-8"))
    value = compose["services"]["open-webui"]["environment"]["API_KEYS_ALLOWED_ENDPOINTS"]
    return {item.strip() for item in str(value).split(",") if item.strip()}


def client_allowlist() -> set[str]:
    """`owui-api`のALLOWED_PREFIXESを読む。

    Returns:
        clientが許可するprefix集合。
    """
    text = (SKILLS_DIR / "open-webui" / "scripts" / "owui-api").read_text(encoding="utf-8")
    block = re.search(r"ALLOWED_PREFIXES=\((.*?)\)", text, re.DOTALL)
    if block is None:
        raise AssertionError("ALLOWED_PREFIXES not found")
    return set(block.group(1).split())


class OwuiSkillsTest(unittest.TestCase):
    """allowlist、client、生成referenceの整合性を検査する。"""

    def test_client_matches_compose_allowlist(self) -> None:
        """clientのprefixはserver側allowlistと一致する。"""
        self.assertEqual(client_allowlist(), compose_allowlist())

    def test_skill_prefixes_are_allowed_and_recursion_paths_are_not(self) -> None:
        """全skillのprefixがallowlistに含まれ、再帰起動できるAPIは含まれない。"""
        generator = load_generator()
        allowed = compose_allowlist()
        skill_prefixes = {prefix for skill in generator.SKILLS for prefix in skill.prefixes}
        self.assertLessEqual(skill_prefixes, allowed)
        self.assertEqual(allowed - skill_prefixes - NON_SKILL_PREFIXES, set())
        for path in ("/api/chat/completions", "/api/v1/chat/completions", "/api/v1/messages", "/api/v1/terminals/x", "/api/v1/automations/create"):
            self.assertFalse(generator.matches(path, sorted(allowed)), path)

    def test_every_skill_has_skill_md(self) -> None:
        """生成対象の全skillにSKILL.mdがあり、nameがdirectory名と一致する。"""
        generator = load_generator()
        for skill in (*generator.SKILLS, generator.SkillSpec("open-webui", ())):
            text = (SKILLS_DIR / skill.name / "SKILL.md").read_text(encoding="utf-8")
            self.assertIn(f"\nname: {skill.name}\n", text)

    def test_generated_references_are_current(self) -> None:
        """commit済みreferenceは保存済みSchemaからの生成結果と一致する。"""
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(
                [sys.executable, str(GENERATOR), str(SCHEMA), "--version", "v0.13.4", "--skills-dir", tmp],
                check=True,
                capture_output=True,
            )
            for generated in Path(tmp).rglob("*.md"):
                committed = SKILLS_DIR / generated.relative_to(tmp)
                self.assertEqual(generated.read_text(encoding="utf-8"), committed.read_text(encoding="utf-8"), committed)


if __name__ == "__main__":
    unittest.main()
