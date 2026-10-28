"""Open WebUI 0.12.4実imageのDoclingLoader分割動作を確認する。"""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

try:
    from pypdf import PdfWriter
except ModuleNotFoundError as error:
    raise unittest.SkipTest("pypdfを含むOpen WebUI image内で実行する") from error

LOADER_PATH = Path("/app/backend/open_webui/retrieval/loaders/main.py")
PATCH_PATH = Path("/patch/patch-docling-pdf-batches.py")
CONFIG_PATH = Path("/patch/docling_params_slim.json")


class DoclingUpgradeRuntimeTest(unittest.TestCase):
    """標準Loaderへの委譲と分割境界の原本ページ番号を検証する。"""

    @classmethod
    def setUpClass(cls) -> None:
        """実imageのLoaderに分割パッチを適用して読み込む。

        Args:
            cls: テストclass。

        Returns:
            なし。
        """
        spec = importlib.util.spec_from_file_location(
            "docling_patch_runtime", PATCH_PATH
        )
        if spec is None or spec.loader is None:
            raise RuntimeError("patch script could not be loaded")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source = LOADER_PATH.read_text(encoding="utf-8")
        patched = module.patch_source(source)
        if module.patch_source(patched) != patched:
            raise RuntimeError("patch is not idempotent")
        start = patched.index("class _InferlabBaseDoclingLoader:")
        end = patched.index("\n\nclass Loader:", start)
        cls.loader_source = patched[start:end]

    def setUp(self) -> None:
        """標準LoaderのHTTP送信をテスト用responseへ差し替える。

        Args:
            なし。

        Returns:
            なし。
        """
        self.requests = Mock()
        self.namespace = {
            "__name__": "patched_docling_runtime",
            "AIOHTTP_CLIENT_SESSION_SSL": False,
            "Document": SimpleNamespace,
            "log": Mock(),
            "os": os,
            "requests": self.requests,
        }
        exec(self.loader_source, self.namespace)

    @contextmanager
    def _pdf(self, page_count: int):
        """ページ番号確認用の空白PDFを作成する。

        Args:
            page_count: PDFページ数。

        Returns:
            書き込み済みの一時PDF fileをyieldするcontext manager。
        """
        with tempfile.NamedTemporaryFile(suffix=".pdf") as pdf:
            writer = PdfWriter()
            for _ in range(page_count):
                writer.add_blank_page(width=100, height=100)
            writer.write(pdf)
            pdf.flush()
            yield pdf

    def test_provenance_across_batch_boundary(self) -> None:
        """空白ページを挟む分割境界でも原本ページ番号を維持する。

        Args:
            なし。

        Returns:
            なし。
        """
        batches = [
            ("page-1\fpage-3", [1, 3]),
            ("page-4\fpage-6", [1, 3]),
        ]

        def post(url, **kwargs):
            """Doclingの局所provenanceを返す。

            Args:
                url: Docling endpoint。
                **kwargs: multipart request。

            Returns:
                変換response。
            """
            self.assertEqual(url, "http://docling/v1/convert/file")
            self.assertEqual(kwargs["data"]["to_formats"], ["md", "json"])
            index = self.requests.post.call_count - 1
            text, pages = batches[index]
            response = Mock(ok=True, reason="OK", text="")
            response.json.return_value = {
                "status": "success",
                "document": {
                    "md_content": text,
                    "json_content": {
                        "texts": [
                            {"content_layer": "body", "prov": [{"page_no": page}]}
                            for page in pages
                        ]
                    },
                },
            }
            return response

        self.requests.post.side_effect = post
        params = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        with (
            self._pdf(6) as pdf,
            patch.dict(os.environ, {"DOCLING_PDF_BATCH_PAGES": "3"}),
        ):
            loader = self.namespace["DoclingLoader"](
                "http://docling",
                file_path=pdf.name,
                mime_type="application/pdf",
                params=params,
            )
            documents = loader.load()
        self.assertEqual(self.requests.post.call_count, 2)
        self.assertEqual([item.metadata["page"] for item in documents], [0, 2, 3, 5])

    def test_http_200_failure_and_skipped_are_not_success(self) -> None:
        """標準Loaderのfailureとskipped判定を分割時にも維持する。

        Args:
            なし。

        Returns:
            なし。
        """
        for status in ("failure", "skipped"):
            with self.subTest(status=status):
                response = Mock(ok=True, reason="OK", text="")
                response.json.return_value = {
                    "status": status,
                    "errors": [{"error_message": "conversion failed"}],
                }
                self.requests.post.return_value = response
                with (
                    self._pdf(2) as pdf,
                    patch.dict(os.environ, {"DOCLING_PDF_BATCH_PAGES": "1"}),
                    self.assertRaisesRegex(Exception, status),
                ):
                    self.namespace["DoclingLoader"](
                        "http://docling",
                        file_path=pdf.name,
                        mime_type="application/pdf",
                    ).load()

    def test_single_content_page_after_blank_page(self) -> None:
        """空白ページの後に本文が一つだけあるbatchでも位置を保持する。

        Args:
            なし。

        Returns:
            なし。
        """
        response = Mock(ok=True, reason="OK", text="")
        response.json.return_value = {
            "status": "success",
            "document": {
                "md_content": "page-2",
                "json_content": {
                    "texts": [{"content_layer": "body", "prov": [{"page_no": 2}]}]
                },
            },
        }
        self.requests.post.return_value = response
        with (
            self._pdf(4) as pdf,
            patch.dict(os.environ, {"DOCLING_PDF_BATCH_PAGES": "2"}),
        ):
            documents = self.namespace["DoclingLoader"](
                "http://docling", file_path=pdf.name, mime_type="application/pdf"
            ).load()
        self.assertEqual([item.metadata["page"] for item in documents], [1, 3])
