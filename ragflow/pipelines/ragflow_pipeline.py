"""
title: RAGFlow Pipeline
author: inferlab
version: 1.0
license: MIT
description: Exposes RAGFlow chats or agents to Open WebUI through Pipelines.
requirements: requests
"""

import os
import re
from typing import Generator, Iterator, List, Union

import requests
from pydantic import BaseModel


class Pipeline:
    class Valves(BaseModel):
        RAGFLOW_BASE_URL: str = "http://ragflow:9380"
        RAGFLOW_API_KEY: str = ""
        RAGFLOW_CHAT_IDS: str = ""
        RAGFLOW_AGENT_IDS: str = ""
        RAGFLOW_TIMEOUT_SECONDS: int = 300

    def __init__(self):
        self.type = "manifold"
        self.name = "RAGFlow: "
        self.valves = self.Valves(
            **{
                "RAGFLOW_BASE_URL": os.getenv("RAGFLOW_BASE_URL", "http://ragflow:9380"),
                "RAGFLOW_API_KEY": os.getenv("RAGFLOW_API_KEY", ""),
                "RAGFLOW_CHAT_IDS": os.getenv("RAGFLOW_CHAT_IDS", ""),
                "RAGFLOW_AGENT_IDS": os.getenv("RAGFLOW_AGENT_IDS", ""),
                "RAGFLOW_TIMEOUT_SECONDS": int(
                    os.getenv("RAGFLOW_TIMEOUT_SECONDS", "300")
                ),
            }
        )
        self._targets = {}
        self.pipelines = self._build_pipelines()

    async def on_startup(self):
        self.pipelines = self._build_pipelines()

    async def on_valves_updated(self):
        self.pipelines = self._build_pipelines()

    async def on_shutdown(self):
        pass

    def _build_pipelines(self):
        self._targets = {}
        pipelines = []
        for target_type, raw_targets in (
            ("chat", self.valves.RAGFLOW_CHAT_IDS),
            ("agent", self.valves.RAGFLOW_AGENT_IDS),
        ):
            for index, (label, target_id) in enumerate(self._parse_targets(raw_targets)):
                model_id = self._model_id(target_type, label, target_id, index)
                self._targets[model_id] = {
                    "label": label,
                    "target_id": target_id,
                    "target_type": target_type,
                }
                pipelines.append(
                    {
                        "id": model_id,
                        "name": f"{target_type.title()}: {label}",
                    }
                )

        if pipelines:
            return pipelines

        return [
            {
                "id": "not-configured",
                "name": "Set RAGFLOW_API_KEY and RAGFLOW_CHAT_IDS or RAGFLOW_AGENT_IDS",
            }
        ]

    def _parse_targets(self, raw_targets: str):
        targets = []
        for raw_item in re.split(r"[,;\n]", raw_targets or ""):
            item = raw_item.strip()
            if not item:
                continue

            if ":" in item:
                label, target_id = item.split(":", 1)
                label = label.strip()
                target_id = target_id.strip()
            else:
                target_id = item
                label = item[:12]

            if target_id:
                targets.append((label or target_id[:12], target_id))

        return targets

    def _model_id(self, target_type: str, label: str, target_id: str, index: int):
        slug_source = label or target_id
        slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", slug_source).strip("-").lower()
        return f"{target_type}-{slug or index}"

    def _resolve_target(self, model_id: str):
        candidates = [model_id]
        if "." in model_id:
            candidates.append(model_id.rsplit(".", 1)[-1])
        if "/" in model_id:
            candidates.append(model_id.rsplit("/", 1)[-1])

        for candidate in candidates:
            if candidate in self._targets:
                return self._targets[candidate]

        return None

    def _completion_url(self, target):
        base_url = self.valves.RAGFLOW_BASE_URL.rstrip("/")
        target_id = target["target_id"]
        if target["target_type"] == "agent":
            return f"{base_url}/api/v1/agents_openai/{target_id}/chat/completions"
        return f"{base_url}/api/v1/chats_openai/{target_id}/chat/completions"

    def pipe(
        self, user_message: str, model_id: str, messages: List[dict], body: dict
    ) -> Union[str, Generator, Iterator, dict]:
        target = self._resolve_target(model_id)
        if not target:
            return (
                "RAGFlow pipeline is not configured. Set RAGFLOW_API_KEY and "
                "RAGFLOW_CHAT_IDS or RAGFLOW_AGENT_IDS, then restart Pipelines."
            )

        if not self.valves.RAGFLOW_API_KEY:
            return "RAGFlow API key is not configured. Set RAGFLOW_API_KEY."

        stream = bool(body.get("stream", True))
        payload = {
            "model": "model",
            "messages": body.get("messages") or messages,
            "stream": stream,
        }
        if body.get("session_id"):
            payload["session_id"] = body["session_id"]

        headers = {
            "Authorization": f"Bearer {self.valves.RAGFLOW_API_KEY}",
            "Content-Type": "application/json",
        }

        try:
            response = requests.post(
                self._completion_url(target),
                json=payload,
                headers=headers,
                stream=stream,
                timeout=self.valves.RAGFLOW_TIMEOUT_SECONDS,
            )
            response.raise_for_status()
            if stream:
                return response.iter_lines()
            return response.json()
        except requests.HTTPError as exc:
            return f"RAGFlow HTTP error: {exc.response.status_code} {exc.response.text}"
        except requests.RequestException as exc:
            return f"RAGFlow request error: {exc}"
