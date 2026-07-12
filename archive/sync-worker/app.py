import hashlib
import html
import json
import mimetypes
import os
import re
import sqlite3
import time
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Iterable

import requests
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


DATA_DIR = Path(os.getenv("SYNC_WORKER_DATA_DIR", "/data"))
STATE_PATH = Path(os.getenv("SYNC_WORKER_STATE_PATH", str(DATA_DIR / "sync.sqlite3")))


def env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def env_int(name: str, default: int) -> int:
    value = env(name)
    return int(value) if value else default


def ragflow_model_id(value: str, factory: str) -> str:
    return value if not value or "@" in value else f"{value}@{factory}"


class TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in {"p", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        text = data.strip()
        if text:
            self.parts.append(text)

    def get_text(self) -> str:
        text = " ".join(self.parts)
        text = re.sub(r"[ \t\r\f\v]+", " ", text)
        text = re.sub(r"\n\s+", "\n", text)
        return html.unescape(text).strip()


def html_to_text(value: str) -> str:
    parser = TextExtractor()
    parser.feed(value or "")
    return parser.get_text()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def safe_name(value: str, suffix: str = ".md") -> str:
    stem = re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("._")
    return f"{stem or 'document'}{suffix}"


def api_data(payload: Any) -> Any:
    if isinstance(payload, dict) and "code" in payload and payload.get("code") not in (0, "0"):
        raise HTTPException(status_code=502, detail=payload)
    if isinstance(payload, dict) and "data" in payload:
        return payload["data"]
    return payload


class SyncState:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_state (
              source TEXT NOT NULL,
              source_id TEXT NOT NULL,
              fingerprint TEXT NOT NULL,
              ragflow_dataset_id TEXT,
              ragflow_document_id TEXT,
              metadata_json TEXT NOT NULL,
              synced_at INTEGER NOT NULL,
              PRIMARY KEY (source, source_id)
            )
            """
        )
        self.conn.commit()

    def get(self, source: str, source_id: str) -> dict[str, Any] | None:
        row = self.conn.execute(
            """
            SELECT fingerprint, ragflow_dataset_id, ragflow_document_id, metadata_json, synced_at
            FROM sync_state WHERE source = ? AND source_id = ?
            """,
            (source, source_id),
        ).fetchone()
        if not row:
            return None
        return {
            "fingerprint": row[0],
            "ragflow_dataset_id": row[1],
            "ragflow_document_id": row[2],
            "metadata": json.loads(row[3]),
            "synced_at": row[4],
        }

    def put(
        self,
        source: str,
        source_id: str,
        fingerprint: str,
        dataset_id: str,
        document_id: str,
        metadata: dict[str, Any],
    ) -> None:
        self.conn.execute(
            """
            INSERT INTO sync_state
              (source, source_id, fingerprint, ragflow_dataset_id, ragflow_document_id, metadata_json, synced_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, source_id) DO UPDATE SET
              fingerprint = excluded.fingerprint,
              ragflow_dataset_id = excluded.ragflow_dataset_id,
              ragflow_document_id = excluded.ragflow_document_id,
              metadata_json = excluded.metadata_json,
              synced_at = excluded.synced_at
            """,
            (
                source,
                source_id,
                fingerprint,
                dataset_id,
                document_id,
                json.dumps(metadata, ensure_ascii=False, sort_keys=True),
                int(time.time()),
            ),
        )
        self.conn.commit()


class RAGFlowClient:
    def __init__(self) -> None:
        self.base_url = env("RAGFLOW_BASE_URL", "http://ragflow:9380").rstrip("/")
        self.api_key = env("RAGFLOW_API_KEY")
        self.timeout = env_int("RAGFLOW_TIMEOUT_SECONDS", 300)
        self.chat_id = env("RAGFLOW_CHAT_ID")
        self.embedding_model = ragflow_model_id(env("RAGFLOW_EMBEDDING_MODEL", "ruri-v3:310m"), "OpenAI")
        self.rerank_id = ragflow_model_id(
            env("RAGFLOW_RERANK_MODEL", "ruri-v3-reranker:310m"),
            env("RAGFLOW_RERANK_FACTORY", "OpenAI-API-Compatible"),
        )

    def headers(self) -> dict[str, str]:
        if not self.api_key:
            raise HTTPException(status_code=500, detail="RAGFLOW_API_KEY is not configured")
        return {"Authorization": f"Bearer {self.api_key}"}

    def request(self, method: str, path: str, **kwargs: Any) -> Any:
        headers = kwargs.pop("headers", {})
        headers.update(self.headers())
        response = requests.request(
            method,
            f"{self.base_url}{path}",
            headers=headers,
            timeout=self.timeout,
            **kwargs,
        )
        try:
            payload = response.json()
        except ValueError:
            payload = response.text
        if response.status_code >= 400:
            raise HTTPException(status_code=502, detail={"status": response.status_code, "body": payload})
        return api_data(payload)

    def list_datasets(self) -> list[dict[str, Any]]:
        data = self.request("GET", "/api/v1/datasets", params={"page": 1, "page_size": 1000})
        if isinstance(data, dict):
            return data.get("kbs") or data.get("datasets") or data.get("items") or []
        return data if isinstance(data, list) else []

    def ensure_dataset(self, name: str, description: str) -> str:
        for dataset in self.list_datasets():
            if str(dataset.get("name", "")).lower() == name.lower():
                return str(dataset["id"])
        payload = {
            "name": name,
            "description": description,
            "permission": "me",
            "chunk_method": "naive",
            "parser_config": {
                "chunk_token_num": env_int("RAGFLOW_CHUNK_TOKEN_NUM", 800),
                "delimiter": "\n",
                "layout_recognize": "DeepDOC",
                "auto_keywords": 0,
                "auto_questions": 0,
                "parent_child": {
                    "use_parent_child": True,
                    "children_delimiter": "\n\n",
                },
            },
        }
        if self.embedding_model:
            payload["embedding_model"] = self.embedding_model
        data = self.request(
            "POST",
            "/api/v1/datasets",
            json=payload,
            headers={"Content-Type": "application/json"},
        )
        return str(data["id"])

    def delete_document(self, dataset_id: str, document_id: str | None) -> None:
        if not document_id:
            return
        try:
            self.request(
                "DELETE",
                f"/api/v1/datasets/{dataset_id}/documents",
                json={"ids": [document_id]},
                headers={"Content-Type": "application/json"},
            )
        except HTTPException:
            pass

    def upload_document(self, dataset_id: str, filename: str, content: bytes, content_type: str | None) -> str:
        files = [("file", (filename, content, content_type or "application/octet-stream"))]
        data = self.request("POST", f"/api/v1/datasets/{dataset_id}/documents", files=files)
        if isinstance(data, list) and data:
            return str(data[0]["id"])
        raise HTTPException(status_code=502, detail={"message": "RAGFlow upload did not return a document id", "data": data})

    def parse_documents(self, dataset_id: str, document_ids: list[str]) -> None:
        if document_ids:
            self.request(
                "POST",
                f"/api/v1/datasets/{dataset_id}/chunks",
                json={"document_ids": document_ids},
                headers={"Content-Type": "application/json"},
            )

    def update_metadata(self, dataset_id: str, document_id: str, metadata: dict[str, Any]) -> None:
        updates = [{"key": key, "value": str(value)} for key, value in metadata.items() if value not in (None, "")]
        if updates:
            self.request(
                "POST",
                f"/api/v1/datasets/{dataset_id}/metadata/update",
                json={"selector": {"document_ids": [document_id]}, "updates": updates},
                headers={"Content-Type": "application/json"},
            )

    def retrieval(self, request: "SearchRequest") -> dict[str, Any]:
        dataset_ids = request.dataset_ids or [self.ensure_dataset(name, "inferlab synced dataset") for name in request.dataset_names]
        payload: dict[str, Any] = {
            "question": request.question,
            "dataset_ids": dataset_ids,
            "page": 1,
            "page_size": request.page_size,
            "similarity_threshold": request.similarity_threshold,
            "vector_similarity_weight": request.vector_similarity_weight,
            "top_k": request.top_k,
            "keyword": request.hybrid,
            "highlight": True,
        }
        if self.rerank_id:
            payload["rerank_id"] = self.rerank_id
        if request.metadata_condition:
            payload["metadata_condition"] = request.metadata_condition
        data = self.request("POST", "/api/v1/retrieval", json=payload, headers={"Content-Type": "application/json"})
        return data if isinstance(data, dict) else {"chunks": data}

    def chat_answer(self, question: str) -> str | None:
        if not self.chat_id:
            return None
        data = self.request(
            "POST",
            f"/api/v1/chats_openai/{self.chat_id}/chat/completions",
            json={
                "model": "model",
                "stream": False,
                "messages": [
                    {
                        "role": "system",
                        "content": "回答は検索根拠に基づけ、最後に参照元が分かる形で簡潔に示してください。",
                    },
                    {"role": "user", "content": question},
                ],
            },
            headers={"Content-Type": "application/json"},
        )
        choices = data.get("choices") if isinstance(data, dict) else None
        if choices:
            return choices[0].get("message", {}).get("content")
        return None


@dataclass
class SyncDocument:
    source: str
    source_id: str
    filename: str
    content: bytes
    content_type: str
    fingerprint: str
    metadata: dict[str, Any]


class BookStackClient:
    def __init__(self) -> None:
        self.base_url = env("BOOKSTACK_BASE_URL").rstrip("/")
        self.token_id = env("BOOKSTACK_TOKEN_ID")
        self.token_secret = env("BOOKSTACK_TOKEN_SECRET")
        self.timeout = env_int("BOOKSTACK_TIMEOUT_SECONDS", 60)

    def enabled(self) -> bool:
        return bool(self.base_url and self.token_id and self.token_secret)

    def get(self, path: str, **params: Any) -> Any:
        response = requests.get(
            f"{self.base_url}{path}",
            headers={"Authorization": f"Token {self.token_id}:{self.token_secret}", "Accept": "application/json"},
            params=params,
            timeout=self.timeout,
        )
        if response.status_code >= 400:
            raise HTTPException(status_code=502, detail={"bookstack_status": response.status_code, "body": response.text})
        return response.json()

    def pages(self) -> Iterable[dict[str, Any]]:
        count = env_int("BOOKSTACK_PAGE_SIZE", 100)
        offset = 0
        while True:
            payload = self.get("/api/pages", count=count, offset=offset)
            items = payload.get("data") if isinstance(payload, dict) else payload
            if not items:
                break
            yield from items
            if len(items) < count:
                break
            offset += count

    def documents(self) -> Iterable[SyncDocument]:
        for page_ref in self.pages():
            page_id = str(page_ref["id"])
            page = self.get(f"/api/pages/{page_id}")
            title = page.get("name") or page_ref.get("name") or f"bookstack-page-{page_id}"
            body = page.get("markdown") or html_to_text(page.get("html") or page.get("raw_html") or "")
            url = page.get("url") or page_ref.get("url") or f"{self.base_url}/books/{page.get('book_slug', '')}/page/{page.get('slug', page_id)}"
            metadata = {
                "source": "bookstack",
                "source_name": title,
                "source_id": page_id,
                "page_url": url,
                "book_id": page.get("book_id") or page_ref.get("book_id"),
                "chapter_id": page.get("chapter_id") or page_ref.get("chapter_id"),
                "updated_at": page.get("updated_at") or page_ref.get("updated_at"),
                "approval_status": page.get("draft") and "draft" or "approved",
            }
            markdown = f"# {title}\n\n{body}\n\n---\nsource: {url}\n"
            content = markdown.encode("utf-8")
            fingerprint = sha256_bytes(content + json.dumps(metadata, sort_keys=True).encode("utf-8"))
            yield SyncDocument(
                source="bookstack",
                source_id=page_id,
                filename=safe_name(f"bookstack-{page_id}-{title}"),
                content=content,
                content_type="text/markdown; charset=utf-8",
                fingerprint=fingerprint,
                metadata=metadata,
            )


class SeafileClient:
    def __init__(self) -> None:
        self.base_url = env("SEAFILE_BASE_URL").rstrip("/")
        self.api_token = env("SEAFILE_API_TOKEN")
        self.timeout = env_int("SEAFILE_TIMEOUT_SECONDS", 120)
        self.library_ids = [x.strip() for x in env("SEAFILE_LIBRARY_IDS").split(",") if x.strip()]
        self.roots = [x.strip() for x in env("SEAFILE_PATHS", "/").split(",") if x.strip()]

    def enabled(self) -> bool:
        return bool(self.base_url and self.api_token)

    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Token {self.api_token}", "Accept": "application/json"}

    def request(self, method: str, path: str, **kwargs: Any) -> Any:
        response = requests.request(method, f"{self.base_url}{path}", headers=self.headers(), timeout=self.timeout, **kwargs)
        if response.status_code >= 400:
            raise HTTPException(status_code=502, detail={"seafile_status": response.status_code, "body": response.text})
        try:
            return response.json()
        except ValueError:
            return response.text.strip().strip('"')

    def libraries(self) -> Iterable[dict[str, Any]]:
        repos = self.request("GET", "/api2/repos/")
        for repo in repos:
            if not self.library_ids or repo.get("id") in self.library_ids:
                yield repo

    def entries(self, repo_id: str, path: str) -> Iterable[dict[str, Any]]:
        entries = self.request("GET", f"/api2/repos/{repo_id}/dir/", params={"p": path})
        for entry in entries:
            entry_path = f"{path.rstrip('/')}/{entry['name']}" if path != "/" else f"/{entry['name']}"
            if entry.get("type") == "dir":
                yield from self.entries(repo_id, entry_path)
            elif entry.get("type") == "file":
                entry["path"] = entry_path
                yield entry

    def download_file(self, repo_id: str, path: str) -> bytes:
        download_url = self.request("GET", f"/api2/repos/{repo_id}/file/", params={"p": path})
        response = requests.get(download_url, timeout=self.timeout)
        if response.status_code >= 400:
            raise HTTPException(status_code=502, detail={"download_status": response.status_code, "path": path})
        return response.content

    def documents(self) -> Iterable[SyncDocument]:
        allowed_ext = {x.strip().lower() for x in env("SEAFILE_ALLOWED_EXTENSIONS", ".pdf,.docx,.xlsx,.pptx,.md,.txt,.html,.htm,.csv").split(",")}
        for repo in self.libraries():
            repo_id = repo["id"]
            repo_name = repo.get("name") or repo_id
            for root in self.roots:
                for entry in self.entries(repo_id, root or "/"):
                    ext = Path(entry["path"]).suffix.lower()
                    if allowed_ext and ext not in allowed_ext:
                        continue
                    content = self.download_file(repo_id, entry["path"])
                    if ext in {".html", ".htm"}:
                        text = html_to_text(content.decode("utf-8", errors="replace"))
                        content = text.encode("utf-8")
                        content_type = "text/markdown; charset=utf-8"
                        filename = safe_name(f"seafile-{repo_id}-{entry['path']}")
                    else:
                        content_type = mimetypes.guess_type(entry["path"])[0] or "application/octet-stream"
                        filename = safe_name(f"seafile-{repo_id}-{entry['path']}", suffix=ext or ".bin")
                    metadata = {
                        "source": "seafile",
                        "source_name": entry.get("name") or Path(entry["path"]).name,
                        "source_id": f"{repo_id}:{entry['path']}",
                        "file_path": entry["path"],
                        "library_id": repo_id,
                        "library_name": repo_name,
                        "updated_at": entry.get("mtime") or entry.get("last_modified"),
                    }
                    fingerprint = entry.get("id") or entry.get("modifier_email") or sha256_bytes(content)
                    yield SyncDocument(
                        source="seafile",
                        source_id=f"{repo_id}:{entry['path']}",
                        filename=filename,
                        content=content,
                        content_type=content_type,
                        fingerprint=str(fingerprint),
                        metadata=metadata,
                    )


class SyncResponse(BaseModel):
    source: str
    dataset_id: str
    scanned: int = 0
    uploaded: int = 0
    skipped: int = 0
    document_ids: list[str] = Field(default_factory=list)


class SearchRequest(BaseModel):
    question: str
    dataset_names: list[str] = Field(default_factory=lambda: [
        env("BOOKSTACK_DATASET_NAME", "rag_bookstack"),
        env("SEAFILE_DATASET_NAME", "rag_seafile"),
    ])
    dataset_ids: list[str] = Field(default_factory=list)
    metadata_condition: dict[str, Any] | None = None
    page_size: int = 12
    top_k: int = 30
    hybrid: bool = True
    similarity_threshold: float = 0.2
    vector_similarity_weight: float = 0.7


app = FastAPI(title="InferLab Sync Worker", version="1.0.0")
state = SyncState(STATE_PATH)
ragflow = RAGFlowClient()


def sync_documents(source: str, dataset_name: str, docs: Iterable[SyncDocument]) -> SyncResponse:
    dataset_id = ragflow.ensure_dataset(dataset_name, f"{source} synced by inferlab sync-worker")
    response = SyncResponse(source=source, dataset_id=dataset_id)
    parse_ids: list[str] = []
    for doc in docs:
        response.scanned += 1
        previous = state.get(doc.source, doc.source_id)
        if previous and previous["fingerprint"] == doc.fingerprint:
            response.skipped += 1
            continue
        if previous and previous.get("ragflow_dataset_id") == dataset_id:
            ragflow.delete_document(dataset_id, previous.get("ragflow_document_id"))
        document_id = ragflow.upload_document(dataset_id, doc.filename, doc.content, doc.content_type)
        ragflow.update_metadata(dataset_id, document_id, doc.metadata)
        state.put(doc.source, doc.source_id, doc.fingerprint, dataset_id, document_id, doc.metadata)
        response.uploaded += 1
        response.document_ids.append(document_id)
        parse_ids.append(document_id)
    ragflow.parse_documents(dataset_id, parse_ids)
    return response


def build_citations(chunks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    citations = []
    for index, chunk in enumerate(chunks, start=1):
        citations.append(
            {
                "ref": index,
                "document_id": chunk.get("document_id") or chunk.get("doc_id"),
                "chunk_id": chunk.get("id") or chunk.get("chunk_id"),
                "source_name": chunk.get("source_name") or chunk.get("docnm_kwd"),
                "page_url": chunk.get("page_url"),
                "file_path": chunk.get("file_path"),
                "score": chunk.get("similarity") or chunk.get("score"),
            }
        )
    return citations


@app.get("/health")
def health() -> dict[str, Any]:
    return {"ok": True, "state_path": str(STATE_PATH)}


@app.post("/sync/bookstack", response_model=SyncResponse)
def sync_bookstack() -> SyncResponse:
    client = BookStackClient()
    if not client.enabled():
        raise HTTPException(status_code=400, detail="BOOKSTACK_BASE_URL, BOOKSTACK_TOKEN_ID and BOOKSTACK_TOKEN_SECRET are required")
    return sync_documents("bookstack", env("BOOKSTACK_DATASET_NAME", "rag_bookstack"), client.documents())


@app.post("/sync/seafile", response_model=SyncResponse)
def sync_seafile() -> SyncResponse:
    client = SeafileClient()
    if not client.enabled():
        raise HTTPException(status_code=400, detail="SEAFILE_BASE_URL and SEAFILE_API_TOKEN are required")
    return sync_documents("seafile", env("SEAFILE_DATASET_NAME", "rag_seafile"), client.documents())


@app.post("/sync/all")
def sync_all() -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    if BookStackClient().enabled():
        results.append(sync_bookstack().model_dump())
    if SeafileClient().enabled():
        results.append(sync_seafile().model_dump())
    if not results:
        raise HTTPException(status_code=400, detail="No source connector is configured")
    return {"results": results}


@app.post("/search")
def search(request: SearchRequest) -> dict[str, Any]:
    data = ragflow.retrieval(request)
    chunks = data.get("chunks") or data.get("hits") or data.get("documents") or []
    return {"question": request.question, "chunks": chunks, "citations": build_citations(chunks)}


@app.post("/answer")
def answer(request: SearchRequest) -> dict[str, Any]:
    result = search(request)
    chunks = result["chunks"]
    llm_answer = ragflow.chat_answer(request.question)
    if llm_answer:
        return {"answer": llm_answer, "citations": result["citations"], "chunks": chunks}

    lines = [f"質問: {request.question}", "", "根拠に基づく候補回答:"]
    for index, chunk in enumerate(chunks[: min(6, len(chunks))], start=1):
        content = chunk.get("content") or chunk.get("content_with_weight") or ""
        content = re.sub(r"\s+", " ", str(content)).strip()
        if content:
            lines.append(f"[{index}] {content[:500]}")
    lines.append("")
    lines.append("Citations:")
    for citation in result["citations"][: min(6, len(result["citations"]))]:
        label = citation.get("source_name") or citation.get("file_path") or citation.get("page_url") or citation.get("document_id")
        lines.append(f"[{citation['ref']}] {label}")
    return {"answer": "\n".join(lines), "citations": result["citations"], "chunks": chunks}
