"""外部API共通HTTP clientのretry境界を検証する。"""

from __future__ import annotations

from datetime import timedelta

import httpx
import pytest

from llm_wiki_platform.config import RateLimitConfig, RetryConfig
from llm_wiki_platform.connectors.base import RetryingHttpClient


async def test_client_does_not_retry_non_transient_4xx() -> None:
    """設定不備や認証失敗を示す4xxが即時返されることを検証する。"""
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        """常に400を返しrequest回数を記録する。

        Args:
            request: MockTransportが受け取ったrequest。

        Returns:
            400 response。
        """
        nonlocal calls
        del request
        calls += 1
        return httpx.Response(400, json={"detail": "invalid"})

    retry = RetryConfig(
        max_attempts=3,
        backoff="exponential",
        initial_delay=timedelta(seconds=1),
        max_delay=timedelta(seconds=1),
    )
    async with httpx.AsyncClient(
        base_url="http://service.test", transport=httpx.MockTransport(handler)
    ) as client:
        retrying = RetryingHttpClient(client, retry, RateLimitConfig(requests_per_minute=60))
        with pytest.raises(httpx.HTTPStatusError):
            await retrying.request("GET", "/invalid")

    assert calls == 1
