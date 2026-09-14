#!/usr/bin/env python3
"""Open WebUIのDoclingLoaderへPDF分割処理を追加する。"""

from __future__ import annotations

import importlib.util
import logging
import sys
import time
from collections.abc import Sequence
from pathlib import Path

LOGGER = logging.getLogger(__name__)
PATCH_MARKER = "_INFERLAB_DOCLING_PDF_BATCHES = True"

DOCLING_LOADER = r'''class DoclingLoader:
    """PDFを分割してDoclingへ逐次送信するloader。"""

    _INFERLAB_DOCLING_PDF_BATCHES = True

    def __init__(self, url, api_key=None, file_path=None, mime_type=None, params=None):
        """Docling接続情報と処理対象fileを保持する。

        Args:
            url: Docling Serveのbase URL。
            api_key: Docling ServeのAPI key。
            file_path: 処理対象fileのpath。
            mime_type: 処理対象fileのMIME type。
            params: Docling Serveへ渡すparameter。

        Returns:
            なし。
        """
        self.url = url.rstrip('/')
        self.api_key = api_key
        self.file_path = file_path
        self.mime_type = mime_type
        self.params = params or {}

    def _batch_pages(self):
        """環境変数からPDFの分割ページ数を取得する。

        Args:
            なし。

        Returns:
            1分割あたりのページ数。0の場合は分割しない。

        Raises:
            ValueError: 環境変数が0以上の整数でない場合。
        """
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
        return batch_pages

    def _is_batch_target(self, batch_pages):
        """処理対象が分割可能なPDFか判定する。

        Args:
            batch_pages: 1分割あたりのページ数。

        Returns:
            PDF分割を行う場合はTrue、それ以外はFalse。
        """
        is_pdf = self.mime_type == 'application/pdf' or str(
            self.file_path
        ).lower().endswith('.pdf')
        return batch_pages > 0 and is_pdf and 'page_range' not in self.params

    def _post_file(
        self,
        file_name,
        file_handle,
        page_offset=0,
        include_page_metadata=False,
    ):
        """1つのfileをDoclingへ送信して文書を生成する。

        Args:
            file_name: multipartで送るfile名。
            file_handle: 読み込み可能なfile object。
            page_offset: 元PDF上の0始まりページ位置。
            include_page_metadata: 単一文書にもページ位置を付けるか。

        Returns:
            DoclingのMarkdownから生成したDocumentのlist。

        Raises:
            Exception: Docling Serveがerror responseを返した場合。

        Side Effects:
            Docling Serveへ同期HTTP requestを送信する。
        """
        page_break_marker = '\f'
        headers = {}
        if self.api_key:
            headers['X-Api-Key'] = f'{self.api_key}'

        response = requests.post(
            f'{self.url}/v1/convert/file',
            files={
                'files': (
                    file_name,
                    file_handle,
                    self.mime_type or 'application/octet-stream',
                )
            },
            data={
                'image_export_mode': 'placeholder',
                'md_page_break_placeholder': page_break_marker,
                **self.params,
            },
            headers=headers,
            verify=AIOHTTP_CLIENT_SESSION_SSL,
        )
        if response.ok:
            result = response.json()
            document_data = result.get('document', {})
            md_content = document_data.get('md_content', '')
            text = md_content or '<No text content found>'
            metadata = {'Content-Type': self.mime_type} if self.mime_type else {}
            if page_break_marker in md_content:
                documents = [
                    Document(
                        page_content=page.strip(),
                        metadata={**metadata, 'page': page_offset + page_index},
                    )
                    for page_index, page in enumerate(
                        md_content.split(page_break_marker)
                    )
                    if page.strip()
                ]
                if documents:
                    log.debug('Docling extracted text: %s', text)
                    return documents

            if include_page_metadata:
                metadata['page'] = page_offset
            log.debug('Docling extracted text: %s', text)
            return [Document(page_content=text, metadata=metadata)]

        error_msg = f'Error calling Docling API: {response.reason}'
        if response.text:
            try:
                error_data = response.json()
                if 'detail' in error_data:
                    error_msg += f' - {error_data["detail"]}'
            except Exception:
                error_msg += f' - {response.text}'
        raise Exception(f'Error calling Docling: {error_msg}')

    def _load_pdf_batches(self, batch_pages):
        """PDFを指定ページ数へ分割してDoclingへ逐次送信する。

        Args:
            batch_pages: 1分割あたりのページ数。

        Returns:
            全分割から生成したDocumentのlist。

        Raises:
            pypdf.errors.PdfReadError: PDFを読み込めない場合。
            Exception: Docling Serveがerror responseを返した場合。

        Side Effects:
            分割PDFを一時fileへ書き込み、Docling Serveへ逐次送信する。
        """
        from pathlib import Path
        from tempfile import TemporaryFile

        from pypdf import PdfReader, PdfWriter

        with open(self.file_path, 'rb') as source_file:
            reader = PdfReader(source_file)
            page_count = len(reader.pages)
            if page_count <= batch_pages:
                source_file.seek(0)
                return self._post_file(self.file_path, source_file)

            documents = []
            stem = Path(self.file_path).stem
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
                with TemporaryFile(mode='w+b') as part_file:
                    writer.write(part_file)
                    part_file.seek(0)
                    part_name = (
                        f'{stem}__pages_{start_index + 1:05d}-'
                        f'{end_index:05d}.pdf'
                    )
                    documents.extend(
                        self._post_file(
                            part_name,
                            part_file,
                            page_offset=start_index,
                            include_page_metadata=True,
                        )
                    )
            return documents

    def load(self) -> list[Document]:
        """対象fileをDoclingでMarkdownへ変換する。

        Args:
            なし。

        Returns:
            変換したDocumentのlist。

        Raises:
            ValueError: PDF分割ページ数が不正な場合。
            OSError: 対象fileを読み込めない場合。
            Exception: Docling Serveがerror responseを返した場合。

        Side Effects:
            Docling Serveへ同期HTTP requestを送信する。
        """
        batch_pages = self._batch_pages()
        if self._is_batch_target(batch_pages):
            return self._load_pdf_batches(batch_pages)

        with open(self.file_path, 'rb') as file_handle:
            return self._post_file(self.file_path, file_handle)
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
    """PDF分割に必要なinstall済みdependencyを検証する。

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
    """Open WebUIのDoclingLoaderをPDF分割対応へ置換する。

    Args:
        source: patch前のOpen WebUI loader source code。

    Returns:
        PDF分割対応のDoclingLoaderを含むsource code。

    Raises:
        RuntimeError: 想定したpatch対象が存在しない場合。
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
        "requests.post",
    )
    if not all(fragment in original_class for fragment in required_fragments):
        raise RuntimeError("Open WebUI DoclingLoader source is incompatible")
    return source[:class_start] + DOCLING_LOADER + source[class_end:]


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
