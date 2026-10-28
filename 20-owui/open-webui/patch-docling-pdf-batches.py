#!/usr/bin/env python3
"""Open WebUIの標準DoclingLoaderへPDF事前分割を追加する。"""

from __future__ import annotations

import importlib.util
import logging
import sys
import time
from collections.abc import Sequence
from pathlib import Path

LOGGER = logging.getLogger(__name__)
PATCH_MARKER = "_INFERLAB_DOCLING_PDF_BATCHES = True"

DOCLING_LOADER = r'''class DoclingLoader(_InferlabBaseDoclingLoader):
    """標準Loaderの変換結果を利用してPDFだけを物理分割する。"""

    _INFERLAB_DOCLING_PDF_BATCHES = True

    def load(self) -> list[Document]:
        """PDFをページ単位で分割し、原本ページ番号を付けて変換する。

        Args:
            なし。

        Returns:
            標準Loaderで変換したDocumentのlist。

        Raises:
            ValueError: 分割ページ数が不正な場合。
            pypdf.errors.PdfReadError: PDFを読み込めない場合。
            Exception: Docling変換が失敗した場合。

        Side Effects:
            分割PDFを一時fileへ書き込み、Docling Serveへ順番に送信する。
        """
        from pathlib import Path
        from tempfile import NamedTemporaryFile

        from pypdf import PdfReader, PdfWriter

        value = os.getenv('DOCLING_PDF_BATCH_PAGES', '0')
        try:
            batch_pages = int(value)
        except ValueError as error:
            raise ValueError(
                'DOCLING_PDF_BATCH_PAGES must be a non-negative integer'
            ) from error
        if batch_pages < 0:
            raise ValueError(
                'DOCLING_PDF_BATCH_PAGES must be a non-negative integer'
            )

        is_pdf = self.mime_type == 'application/pdf' or str(
            self.file_path
        ).lower().endswith('.pdf')
        if not batch_pages or not is_pdf or 'page_range' in self.params:
            return super().load()

        with open(self.file_path, 'rb') as source_file:
            reader = PdfReader(source_file)
            page_count = len(reader.pages)
            if page_count <= batch_pages:
                return super().load()

            documents = []
            for start_index in range(0, page_count, batch_pages):
                end_index = min(start_index + batch_pages, page_count)
                log.info(
                    'Docling PDF batch: file=%s pages=%d-%d/%d',
                    Path(self.file_path).name,
                    start_index + 1,
                    end_index,
                    page_count,
                )
                writer = PdfWriter()
                for page_index in range(start_index, end_index):
                    writer.add_page(reader.pages[page_index])
                with NamedTemporaryFile(mode='w+b', suffix='.pdf') as part_file:
                    writer.write(part_file)
                    part_file.flush()
                    part_loader = _InferlabBaseDoclingLoader(
                        url=self.url,
                        api_key=self.api_key,
                        file_path=part_file.name,
                        mime_type='application/pdf',
                        params=self.params,
                    )
                    for document in part_loader.load():
                        document.metadata['page'] = (
                            start_index + document.metadata.get('page', 0)
                        )
                        documents.append(document)
            return documents
'''


def load_loader_path() -> Path:
    """install済みOpen WebUI loader moduleのpathを解決する。

    Args:
        なし。

    Returns:
        Open WebUI loader moduleのpath。

    Raises:
        RuntimeError: moduleのpathを解決できない場合。
    """
    image_path = Path("/app/backend/open_webui/retrieval/loaders/main.py")
    if image_path.is_file():
        return image_path

    try:
        spec = importlib.util.find_spec("open_webui.retrieval.loaders.main")
    except ModuleNotFoundError as error:
        raise RuntimeError("Open WebUI loader module was not found") from error
    if spec is None or spec.origin is None:
        raise RuntimeError("Open WebUI loader module path was not found")
    return Path(spec.origin)


def validate_dependencies() -> None:
    """PDF分割に必要なpypdfを検証する。

    Args:
        なし。

    Returns:
        なし。

    Raises:
        RuntimeError: pypdfを利用できない場合。
    """
    if importlib.util.find_spec("pypdf") is None:
        raise RuntimeError("pypdf module was not found")


def patch_source(source: str) -> str:
    """標準DoclingLoaderを保持してPDF分割用subclassを追加する。

    Args:
        source: patch前のOpen WebUI loader source code。

    Returns:
        PDF分割対応のDoclingLoaderを含むsource code。

    Raises:
        RuntimeError: 想定したv0.12.4のLoaderが存在しない場合。
    """
    if PATCH_MARKER in source:
        return source

    class_start = source.find("class DoclingLoader:")
    class_end = source.find("\n\nclass Loader:", class_start)
    if class_start < 0 or class_end < 0:
        raise RuntimeError("Open WebUI DoclingLoader patch target was not found")

    original_class = source[class_start:class_end]
    required_fragments = (
        "/v1/convert/file",
        "md_page_break_placeholder",
        "'to_formats': ['md', 'json']",
        "conversion_status in ['failure', 'skipped']",
        "json_content = document_data.get('json_content') or {}",
        "if page_break_marker in md_content:",
        "requests.post",
    )
    if not all(fragment in original_class for fragment in required_fragments):
        raise RuntimeError("Open WebUI DoclingLoader source is incompatible")

    base_class = original_class.replace(
        "class DoclingLoader:", "class _InferlabBaseDoclingLoader:", 1
    )
    base_class = base_class.replace(
        "if page_break_marker in md_content:",
        "if page_break_marker in md_content or (self.mime_type == 'application/pdf' and md_content):",
        1,
    )
    return (
        source[:class_start] + base_class + "\n\n" + DOCLING_LOADER + source[class_end:]
    )


def main(argv: Sequence[str]) -> int:
    """install済みOpen WebUIへPDF分割patchを適用する。

    Args:
        argv: プログラム名を含むcommand line引数。

    Returns:
        patch成功時は0、dependency検証またはfile更新の失敗時は1。

    Side Effects:
        install済みOpen WebUI loader moduleを書き換え、実行時間をlogへ記録する。
    """
    del argv
    started_at = time.perf_counter()
    logging.basicConfig(level=logging.INFO)
    try:
        validate_dependencies()
        path = load_loader_path()
        source = path.read_text(encoding="utf-8")
        patched = patch_source(source)
        if patched != source:
            path.write_text(patched, encoding="utf-8")
            LOGGER.info("Open WebUI Docling PDF batch patch applied")
        else:
            LOGGER.info("Open WebUI Docling PDF batch patch already applied")
        return 0
    except (OSError, RuntimeError) as error:
        LOGGER.error("Open WebUI Docling PDF batch patch failed: %s", error)
        return 1
    finally:
        LOGGER.info("Elapsed time: %.3f seconds", time.perf_counter() - started_at)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
