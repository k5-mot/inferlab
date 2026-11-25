#!/usr/bin/env python3
"""Open WebUIのOpenAPI SchemaからAgent Skills用のAPI referenceを生成する。

検証用Open WebUI (ENV=dev) から取得した`openapi.json`を入力とし、
Skillごとの`references/api.md`と、全routerの分類表`api-index.md`を出力する。
本番Open WebUIで開発modeを有効化しないため、Schema取得とreference生成を分離している。
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

HTTP_METHODS = ("get", "post", "put", "patch", "delete")


@dataclass(frozen=True)
class SkillSpec:
    """Skillと担当API prefixの対応。

    Attributes:
        name: Skill directory名。
        prefixes: Skillが扱うAPI path prefix。前方一致で判定する。
        exclude: prefixに一致しても除外するAPI path prefix。
    """

    name: str
    prefixes: tuple[str, ...]
    exclude: tuple[str, ...] = ()


# Skill化するAPI。prefixはAPI_KEYS_ALLOWED_ENDPOINTSと一致させる。
SKILLS: tuple[SkillSpec, ...] = (
    SkillSpec("owui-knowledge", ("/api/v1/knowledge", "/api/v1/retrieval/query")),
    SkillSpec("owui-files", ("/api/v1/files",)),
    SkillSpec("owui-web-search", ("/api/v1/retrieval/process/web",)),
    SkillSpec("owui-tools", ("/api/v1/tools",)),
    SkillSpec("owui-memory", ("/api/v1/memories",)),
    SkillSpec("owui-notes", ("/api/v1/notes",)),
    SkillSpec("owui-chats", ("/api/v1/chats",)),
    SkillSpec("owui-folders", ("/api/v1/folders",)),
    SkillSpec("owui-calendar", ("/api/v1/calendars",)),
    SkillSpec("owui-channels", ("/api/v1/channels",)),
    SkillSpec("owui-models", ("/api/models", "/api/v1/models")),
    SkillSpec("owui-prompts", ("/api/v1/prompts",)),
    SkillSpec("owui-skills", ("/api/v1/skills",)),
    SkillSpec("owui-images", ("/api/v1/images",)),
    SkillSpec("owui-audio", ("/api/v1/audio",)),
    SkillSpec("owui-evaluations", ("/api/v1/evaluations",)),
    SkillSpec("owui-notifications", ("/api/v1/notifications",)),
)

# Skill化しないAPIと理由。api-index.mdへ記録し、判断を版管理する。
EXCLUDED: tuple[tuple[str, str], ...] = (
    ("/api/chat", "Pi自身をagent modelとして呼べるため、再帰防止で禁止する。"),
    ("/api/v1/chat", "同上。"),
    ("/api/message", "Anthropic Messages互換のchat APIであり、再帰防止で禁止する。"),
    ("/api/v1/messages", "同上。"),
    ("/api/embeddings", "推論はLiteLLMへ集約する。RAGはowui-knowledge経由で使う。"),
    ("/api/v1/embeddings", "同上。"),
    ("/api/v1/retrieval", "query、web以外はRAG設定の変更やresetを含む管理機能。"),
    ("/api/v1/utils", "server側code実行とDB downloadを含むため禁止する。"),
    ("/api/v1/terminals", "Open Terminal経由でagent sessionを起動できるため、再帰防止で禁止する。"),
    ("/api/v1/automations", "agent modelを定期実行できるため、再帰防止で禁止する。"),
    ("/api/v1/tasks", "chat taskの制御であり、agent loopから使う必要がない。"),
    ("/api/tasks", "同上。"),
    ("/api/v1/users", "管理機能（owui-admin、原則無効）。"),
    ("/api/v1/groups", "管理機能（owui-admin、原則無効）。"),
    ("/api/v1/configs", "管理機能（owui-admin、原則無効）。"),
    ("/api/v1/auths", "認証情報の発行・変更を伴うため禁止する。"),
    ("/api/v1/analytics", "管理機能。"),
    ("/api/v1/functions", "server側code実行の登録を伴うため禁止する。"),
    ("/api/v1/pipelines", "管理機能。"),
    ("/ollama", "推論はLiteLLMへ集約する。"),
    ("/openai", "推論はLiteLLMへ集約する。"),
    ("/oauth", "認証flow。"),
)


def iter_operations(schema: Mapping[str, Any]) -> list[tuple[str, str, Mapping[str, Any]]]:
    """OpenAPI Schemaのoperationを列挙する。

    Args:
        schema: OpenAPI Schema。

    Returns:
        (path, HTTP method, operation object) のlist。path順に並ぶ。
    """
    operations = []
    for path, item in sorted(schema.get("paths", {}).items()):
        for method in HTTP_METHODS:
            if method in item:
                operations.append((path, method.upper(), item[method]))
    return operations


def matches(path: str, prefixes: Sequence[str]) -> bool:
    """pathがprefixのいずれかに一致するか判定する。

    Open WebUIのAPI key endpoint restrictionと同じく、完全一致または`prefix/`配下を一致とする。

    Args:
        path: API path。
        prefixes: 判定するprefix。

    Returns:
        一致する場合はTrue。
    """
    return any(path == prefix or path.startswith(prefix + "/") for prefix in prefixes)


def resolve_ref(schema: Mapping[str, Any], node: Mapping[str, Any]) -> Mapping[str, Any]:
    """`$ref`をcomponents内のschemaへ解決する。

    Args:
        schema: OpenAPI Schema全体。
        node: `$ref`を含む可能性があるschema object。

    Returns:
        解決後のschema object。解決できない場合は入力をそのまま返す。
    """
    ref = node.get("$ref")
    if not isinstance(ref, str) or not ref.startswith("#/"):
        return node
    target: Any = schema
    for part in ref[2:].split("/"):
        target = target.get(part, {})
    return target


def type_label(schema: Mapping[str, Any], node: Mapping[str, Any]) -> str:
    """schema objectを短い型表記へ変換する。

    Args:
        schema: OpenAPI Schema全体。
        node: 型を表すschema object。

    Returns:
        `string`、`array<string>`、`object`などの型表記。
    """
    if "$ref" in node:
        return node["$ref"].rsplit("/", 1)[-1]
    if "anyOf" in node:
        labels = [type_label(schema, item) for item in node["anyOf"] if item.get("type") != "null"]
        return " | ".join(labels) or "null"
    if node.get("type") == "array":
        return f"array<{type_label(schema, node.get('items', {}))}>"
    return str(node.get("type", "any"))


def describe_operation(schema: Mapping[str, Any], path: str, method: str, operation: Mapping[str, Any]) -> list[str]:
    """1つのoperationをMarkdownの行へ変換する。

    Args:
        schema: OpenAPI Schema全体。
        path: API path。
        method: HTTP method。
        operation: operation object。

    Returns:
        Markdownの行。
    """
    lines = [f"### `{method} {path}`", ""]
    summary = operation.get("summary")
    if summary:
        lines += [summary, ""]
    params = [
        f"`{p['name']}` ({p.get('in')}, {type_label(schema, p.get('schema', {}))}{', required' if p.get('required') else ''})"
        for p in operation.get("parameters", [])
    ]
    if params:
        lines += ["- parameters: " + ", ".join(params)]
    content = operation.get("requestBody", {}).get("content", {})
    for media_type, media in content.items():
        body = resolve_ref(schema, media.get("schema", {}))
        required = set(body.get("required", []))
        fields = [
            f"`{name}`{'*' if name in required else ''}: {type_label(schema, prop)}"
            for name, prop in body.get("properties", {}).items()
        ]
        lines += [f"- body ({media_type}): " + (", ".join(fields) if fields else type_label(schema, body))]
    lines.append("")
    return lines


def write_skill_reference(schema: Mapping[str, Any], skill: SkillSpec, skills_dir: Path, version: str) -> int:
    """Skillの`references/api.md`を書き出す。

    Args:
        schema: OpenAPI Schema全体。
        skill: 対象Skill。
        skills_dir: Skill群のroot directory。
        version: Open WebUIのversion表記。

    Returns:
        書き出したoperation数。

    Side Effects:
        `<skills_dir>/<skill>/references/api.md`を上書きする。
    """
    operations = [
        (path, method, op)
        for path, method, op in iter_operations(schema)
        if matches(path, skill.prefixes) and not matches(path, skill.exclude)
    ]
    lines = [
        f"# {skill.name} API reference",
        "",
        f"Open WebUI {version}のOpenAPI Schemaから`scripts/owui-skills/generate_api_reference.py`で生成した。手で編集しない。",
        "",
        "`*`は必須field。pathの`{id}`などは実際の値へ置き換える。",
        "",
    ]
    for path, method, op in operations:
        lines += describe_operation(schema, path, method, op)
    target = skills_dir / skill.name / "references" / "api.md"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return len(operations)


def write_index(schema: Mapping[str, Any], skills_dir: Path, version: str) -> list[str]:
    """全operationの分類表`open-webui/references/api-index.md`を書き出す。

    Args:
        schema: OpenAPI Schema全体。
        skills_dir: Skill群のroot directory。
        version: Open WebUIのversion表記。

    Returns:
        Skillにも除外にも分類されなかったoperationのlist。

    Side Effects:
        `<skills_dir>/open-webui/references/api-index.md`を上書きする。
    """
    unclassified = []
    rows = []
    counts: dict[str, int] = {}
    for path, method, _ in iter_operations(schema):
        owner = next((s.name for s in SKILLS if matches(path, s.prefixes) and not matches(path, s.exclude)), None)
        if owner is None:
            owner = next((f"除外: {reason}" for prefix, reason in EXCLUDED if matches(path, (prefix,))), None)
        if owner is None:
            unclassified.append(f"{method} {path}")
            continue
        counts[owner] = counts.get(owner, 0) + 1
    for owner, count in counts.items():
        rows.append(f"| {owner} | {count} |")
    lines = [
        "# Open WebUI API index",
        "",
        f"Open WebUI {version}のOpenAPI Schemaから生成した。手で編集しない。",
        "",
        "| Skillまたは除外理由 | operation数 |",
        "| --- | --- |",
        *rows,
        "",
        "## 未分類",
        "",
        "次のoperationはSkill化しておらず、API keyのallowlistにも含めない。",
        "",
        *[f"- `{item}`" for item in unclassified],
    ]
    target = skills_dir / "open-webui" / "references" / "api-index.md"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return unclassified


def main(argv: Sequence[str]) -> int:
    """CLI entry point。

    Args:
        argv: `sys.argv`形式の引数。

    Returns:
        終了code。成功時は0、入力不正時は1。
    """
    started = time.perf_counter()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema", type=Path, help="Open WebUIのopenapi.json")
    parser.add_argument("--version", required=True, help="Schema取得元のOpen WebUI version (例: v0.13.4)")
    parser.add_argument("--skills-dir", type=Path, default=Path("20-owui/skills"), help="Skill群のroot directory")
    args = parser.parse_args(argv[1:])
    try:
        schema = json.loads(args.schema.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        logger.error("Schemaを読み込めない: %s", exc)
        return 1
    for skill in SKILLS:
        count = write_skill_reference(schema, skill, args.skills_dir, args.version)
        logger.info("%s: %d operations", skill.name, count)
    unclassified = write_index(schema, args.skills_dir, args.version)
    logger.info("未分類: %d operations", len(unclassified))
    logger.info("完了: %.2fs", time.perf_counter() - started)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
