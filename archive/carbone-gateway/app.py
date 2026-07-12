import base64
import os
import re
import time
from pathlib import Path
from typing import Any, Literal

import requests
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field


OUTPUT_DIR = Path(os.getenv("CARBONE_OUTPUT_DIR", "/app/outputs"))
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


def env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip(".-").lower()
    return slug[:80] or "report"


class Section(BaseModel):
    title: str
    body: str = ""
    bullets: list[str] = Field(default_factory=list)


class Citation(BaseModel):
    ref: int | str | None = None
    source_name: str | None = None
    page_url: str | None = None
    file_path: str | None = None


class ReportRequest(BaseModel):
    title: str
    summary: str = ""
    sections: list[Section] = Field(default_factory=list)
    citations: list[Citation] = Field(default_factory=list)
    formats: list[Literal["docx", "pdf"]] = Field(default_factory=lambda: ["docx", "pdf"])
    slug: str | None = None


class ConvertRequest(BaseModel):
    title: str = "report"
    markdown: str
    formats: list[Literal["docx", "pdf"]] = Field(default_factory=lambda: ["docx", "pdf"])
    slug: str | None = None


class RenderedFile(BaseModel):
    format: str
    filename: str
    path: str
    url: str
    bytes: int


class ReportResponse(BaseModel):
    title: str
    files: list[RenderedFile]


def report_to_markdown(report: ReportRequest) -> str:
    lines = [f"# {report.title}", ""]
    if report.summary:
        lines.extend(["## Summary", "", report.summary.strip(), ""])
    for section in report.sections:
        lines.extend([f"## {section.title}", ""])
        if section.body:
            lines.extend([section.body.strip(), ""])
        for bullet in section.bullets:
            lines.append(f"- {bullet.strip()}")
        if section.bullets:
            lines.append("")
    if report.citations:
        lines.extend(["## Citations", ""])
        for idx, citation in enumerate(report.citations, start=1):
            ref = citation.ref or idx
            label = citation.source_name or citation.file_path or citation.page_url or "source"
            if citation.page_url:
                lines.append(f"- [{ref}] [{label}]({citation.page_url})")
            elif citation.file_path:
                lines.append(f"- [{ref}] {label} ({citation.file_path})")
            else:
                lines.append(f"- [{ref}] {label}")
    return "\n".join(lines).strip() + "\n"


class CarboneClient:
    def __init__(self) -> None:
        self.base_url = env("CARBONE_BASE_URL", "http://carbone:4000").rstrip("/")
        self.api_key = env("CARBONE_API_KEY", env("CARBONE_EE_LICENSE", ""))
        self.timeout = int(env("CARBONE_TIMEOUT_SECONDS", "300"))
        self.public_url = env("CARBONE_GATEWAY_PUBLIC_URL", "http://localhost:31010").rstrip("/")

    def headers(self) -> dict[str, str]:
        headers = {"carbone-version": "5", "Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def render_markdown(self, markdown: str, title: str, formats: list[str], slug: str | None = None) -> list[RenderedFile]:
        template = base64.b64encode(markdown.encode("utf-8")).decode("ascii")
        base_slug = safe_slug(slug or title)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        files: list[RenderedFile] = []
        for output_format in formats:
            filename = f"{base_slug}-{stamp}.{output_format}"
            payload: dict[str, Any] = {
                "data": {},
                "template": template,
                "convertTo": output_format,
                "converter": "L",
                "reportName": filename,
            }
            response = requests.post(
                f"{self.base_url}/render/template?download=true",
                json=payload,
                headers=self.headers(),
                timeout=self.timeout,
            )
            if response.status_code >= 400:
                raise HTTPException(
                    status_code=502,
                    detail={"carbone_status": response.status_code, "body": response.text[:2000]},
                )
            output_path = OUTPUT_DIR / filename
            output_path.write_bytes(response.content)
            files.append(
                RenderedFile(
                    format=output_format,
                    filename=filename,
                    path=str(output_path),
                    url=f"{self.public_url}/outputs/{filename}",
                    bytes=len(response.content),
                )
            )
        return files


app = FastAPI(title="InferLab Carbone Gateway", version="1.0.0")
app.mount("/outputs", StaticFiles(directory=str(OUTPUT_DIR)), name="outputs")
carbone = CarboneClient()


@app.get("/health")
def health() -> dict[str, Any]:
    return {"ok": True, "output_dir": str(OUTPUT_DIR)}


@app.post("/v1/reports", response_model=ReportResponse)
def create_report(report: ReportRequest) -> ReportResponse:
    markdown = report_to_markdown(report)
    files = carbone.render_markdown(markdown, report.title, report.formats, report.slug)
    return ReportResponse(title=report.title, files=files)


@app.post("/v1/convert", response_model=ReportResponse)
def convert_markdown(request: ConvertRequest) -> ReportResponse:
    files = carbone.render_markdown(request.markdown, request.title, request.formats, request.slug)
    return ReportResponse(title=request.title, files=files)
