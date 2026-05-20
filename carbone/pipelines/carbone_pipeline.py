"""
title: Carbone Report Pipeline
author: inferlab
version: 1.0
license: MIT
description: Generates DOCX/PDF reports through inferlab carbone-gateway.
requirements: requests
"""

import json
import os
import re
from typing import Generator, Iterator, List, Union

import requests
from pydantic import BaseModel


class Pipeline:
    class Valves(BaseModel):
        CARBONE_GATEWAY_URL: str = "http://carbone-gateway:8080"
        CARBONE_TIMEOUT_SECONDS: int = 300

    def __init__(self):
        self.type = "pipe"
        self.name = "Carbone: DOCX/PDF Report"
        self.valves = self.Valves(
            **{
                "CARBONE_GATEWAY_URL": os.getenv("CARBONE_GATEWAY_URL", "http://carbone-gateway:8080"),
                "CARBONE_TIMEOUT_SECONDS": int(os.getenv("CARBONE_TIMEOUT_SECONDS", "300")),
            }
        )

    async def on_startup(self):
        pass

    async def on_valves_updated(self):
        pass

    async def on_shutdown(self):
        pass

    def _extract_json(self, text: str):
        text = text.strip()
        fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, flags=re.DOTALL)
        candidate = fenced.group(1) if fenced else text
        if "{" in candidate and "}" in candidate:
            candidate = candidate[candidate.find("{") : candidate.rfind("}") + 1]
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            return None

    def _fallback_report(self, text: str):
        title = text.strip().splitlines()[0][:80] if text.strip() else "Generated Report"
        return {
            "title": title,
            "summary": "",
            "sections": [{"title": "Content", "body": text.strip()}],
            "citations": [],
            "formats": ["docx", "pdf"],
        }

    def _format_response(self, payload):
        files = payload.get("files", [])
        if not files:
            return "Carbone did not return any generated files."
        lines = [f"Generated: {payload.get('title', 'report')}", ""]
        for item in files:
            label = item.get("format", "").upper() or item.get("filename", "file")
            lines.append(f"- {label}: [{item.get('filename')}]({item.get('url')})")
        return "\n".join(lines)

    def pipe(
        self, user_message: str, model_id: str, messages: List[dict], body: dict
    ) -> Union[str, Generator, Iterator, dict]:
        report = self._extract_json(user_message) or self._fallback_report(user_message)
        try:
            response = requests.post(
                f"{self.valves.CARBONE_GATEWAY_URL.rstrip('/')}/v1/reports",
                json=report,
                timeout=self.valves.CARBONE_TIMEOUT_SECONDS,
            )
            response.raise_for_status()
            return self._format_response(response.json())
        except requests.HTTPError as exc:
            return f"Carbone HTTP error: {exc.response.status_code} {exc.response.text}"
        except requests.RequestException as exc:
            return f"Carbone request error: {exc}"
