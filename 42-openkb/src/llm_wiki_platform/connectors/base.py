"""Connector interfaceと外部API呼出しの共通制御。"""

from __future__ import annotations

import asyncio
import json
import time
from abc import ABC, abstractmethod
from collections import deque
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

import httpx

from llm_wiki_platform.config import RateLimitConfig, RetryConfig
from llm_wiki_platform.models import KnowledgeDocument, SourceObject


@dataclass(frozen=True, slots=True)
class ConnectorBatch:
    """1回のdiscover結果とsnapshot完全性を表す。"""

    objects: tuple[SourceObject, ...]
    complete_snapshot: bool


class RateLimiter:
    """process内で1分間のrequest数を制限する。"""

    def __init__(self, requests_per_minute: int) -> None:
        """RateLimiterを初期化する。

        Args:
            requests_per_minute: 60秒内に許可する最大request数。

        Returns:
            なし。
        """
        self._limit = requests_per_minute
        self._timestamps: deque[float] = deque()
        self._lock = asyncio.Lock()

    async def acquire(self) -> None:
        """request slotが空くまで待機する。

        Returns:
            なし。

        Side Effects:
            上限到達時はasync taskを待機させる。
        """
        while True:
            async with self._lock:
                now = time.monotonic()
                while self._timestamps and now - self._timestamps[0] >= 60:
                    self._timestamps.popleft()
                if len(self._timestamps) < self._limit:
                    self._timestamps.append(now)
                    return
                wait_seconds = 60 - (now - self._timestamps[0])
            await asyncio.sleep(wait_seconds)


class RetryingHttpClient:
    """retryとrate limitを適用するasync HTTP client。"""

    def __init__(
        self,
        client: httpx.AsyncClient,
        retry: RetryConfig,
        rate_limit: RateLimitConfig,
    ) -> None:
        """RetryingHttpClientを初期化する。

        Args:
            client: 実requestを送るhttpx client。
            retry: retry回数とbackoff設定。
            rate_limit: 1分当たりのrequest上限。

        Returns:
            なし。
        """
        self._client = client
        self._retry = retry
        self._rate_limiter = RateLimiter(rate_limit.requests_per_minute)

    async def request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        """一時的な失敗へretryを適用してHTTP requestを送る。

        Args:
            method: HTTP method。
            url: absoluteまたはclient base URL相対path。
            **kwargs: `httpx.AsyncClient.request`へ渡す引数。

        Returns:
            成功したHTTP response。

        Raises:
            httpx.HTTPError: retry上限まで成功しない場合。
        """
        last_error: httpx.HTTPError | None = None
        for attempt in range(1, self._retry.max_attempts + 1):
            await self._rate_limiter.acquire()
            try:
                response = await self._client.request(method, url, **kwargs)
            except httpx.TransportError as error:
                last_error = error
            else:
                if response.status_code != 429 and response.status_code < 500:
                    response.raise_for_status()
                    return response
                try:
                    response.raise_for_status()
                except httpx.HTTPStatusError as error:
                    last_error = error
            if attempt == self._retry.max_attempts:
                if last_error is None:
                    raise RuntimeError("retry対象responseにerrorがありません")
                raise last_error
            await asyncio.sleep(self._delay_seconds(attempt))
        if last_error is None:
            raise RuntimeError("HTTP retry loopが結果なしで終了しました")
        raise last_error

    def _delay_seconds(self, attempt: int) -> float:
        """attempt番号から次回retryまでの秒数を計算する。

        Args:
            attempt: 失敗したattempt番号。1から始まる。

        Returns:
            max delay以下の待機秒数。
        """
        initial = self._retry.initial_delay.total_seconds()
        multiplier = 2 ** (attempt - 1) if self._retry.backoff == "exponential" else 1
        return min(initial * multiplier, self._retry.max_delay.total_seconds())


class SourceConnector(ABC):
    """Source SystemをCanonical Documentへ変換する共通interface。"""

    name: str

    @abstractmethod
    async def discover(self, checkpoint: str | None) -> ConnectorBatch:
        """前回checkpoint以降の取得対象を発見する。

        Args:
            checkpoint: Connector固有の前回取得位置。

        Returns:
            取得対象とsnapshot完全性。
        """

    @abstractmethod
    async def fetch(self, source: SourceObject) -> bytes:
        """Source Objectのraw contentを取得する。

        Args:
            source: discoverで発見した対象。

        Returns:
            Source System由来のraw bytes。
        """

    @abstractmethod
    def normalize(self, source: SourceObject, raw: bytes) -> KnowledgeDocument:
        """raw contentをCanonical Documentへ変換する。

        Args:
            source: discoverで発見した対象。
            raw: fetch結果。

        Returns:
            正規化済みKnowledgeDocument。
        """

    @abstractmethod
    def checkpoint(self, objects: tuple[SourceObject, ...], previous: str | None) -> str | None:
        """batch成功後に保存するcheckpointを計算する。

        Args:
            objects: 成功した取得対象。
            previous: 前回checkpoint。

        Returns:
            次回取得位置。更新不要ならprevious。
        """

    def raw_filename(self, source: SourceObject) -> str:
        """Source Storeへ保存するraw filenameを決定する。

        Args:
            source: 取得対象。

        Returns:
            path separatorを含まないfilename。
        """
        extension = str(source.metadata.get("extension", ".json"))
        if extension and not extension.startswith("."):
            extension = f".{extension}"
        return f"source{extension}"


def json_bytes(value: object) -> bytes:
    """JSON互換objectをUTF-8 bytesへ変換する。

    Args:
        value: JSON互換object。

    Returns:
        非ASCIIを保持したJSON bytes。
    """
    return json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")


def decode_json_object(raw: bytes) -> dict[str, Any]:
    """raw JSONがobjectであることを検証してdecodeする。

    Args:
        raw: UTF-8 JSON bytes。

    Returns:
        decode済みobject。

    Raises:
        ValueError: JSON rootがobjectではない場合。
    """
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("JSON rootはobjectである必要があります")
    return value


def require_mapping(value: object, context: str) -> Mapping[str, Any]:
    """外部API値がmappingであることを検証する。

    Args:
        value: 検証対象。
        context: errorへ含める項目名。

    Returns:
        mappingとして絞り込んだ値。

    Raises:
        ValueError: mappingではない場合。
    """
    if not isinstance(value, Mapping):
        raise ValueError(f"{context}はobjectである必要があります")
    return value


def parse_datetime(value: object) -> datetime | None:
    """外部APIのISO 8601文字列をdatetimeへ変換する。

    Args:
        value: ISO 8601文字列またはNone。

    Returns:
        timezone付きdatetime。値がなければNone。
    """
    if not isinstance(value, str) or not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=UTC)
