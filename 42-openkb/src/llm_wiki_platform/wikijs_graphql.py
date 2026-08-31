"""Wiki.js GraphQL responseの共通検証を提供する。"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from llm_wiki_platform.connectors.base import RetryingHttpClient, require_mapping


class WikiJSGraphQLError(RuntimeError):
    """Wiki.js GraphQL operationが失敗した場合に発生する例外。"""


class WikiJSGraphQLClient:
    """Wiki.js `/graphql` endpointへ検証付きrequestを送る。"""

    def __init__(self, http: RetryingHttpClient) -> None:
        """WikiJSGraphQLClientを初期化する。

        Args:
            http: 認証とretry設定済みHTTP client。

        Returns:
            なし。
        """
        self._http = http

    async def execute(
        self,
        operation_name: str,
        query: str,
        variables: Mapping[str, Any] | None = None,
    ) -> Mapping[str, Any]:
        """GraphQL operationを実行してdata objectを返す。

        Args:
            operation_name: GraphQL document内のoperation名。
            query: GraphQL queryまたはmutation。
            variables: operationへ渡す変数。

        Returns:
            GraphQL responseのdata object。

        Raises:
            WikiJSGraphQLError: GraphQL errorまたはdata欠落がある場合。
            httpx.HTTPError: HTTP request自体が失敗した場合。
        """
        response = await self._http.request(
            "POST",
            "/graphql",
            json={
                "operationName": operation_name,
                "query": query,
                "variables": dict(variables or {}),
            },
        )
        payload = require_mapping(response.json(), "Wiki.js GraphQL response")
        errors = payload.get("errors")
        if isinstance(errors, list) and errors:
            messages = [
                str(error.get("message", error)) if isinstance(error, Mapping) else str(error)
                for error in errors
            ]
            raise WikiJSGraphQLError("Wiki.js GraphQL error: " + "; ".join(messages))
        data = payload.get("data")
        if not isinstance(data, Mapping):
            raise WikiJSGraphQLError("Wiki.js GraphQL responseにdataがありません")
        return data


def require_success(value: object, context: str) -> Mapping[str, Any]:
    """Wiki.js mutationのresponseResultが成功か検証する。

    Args:
        value: mutation response object。
        context: error messageへ含めるoperation名。

    Returns:
        検証済みmutation response object。

    Raises:
        WikiJSGraphQLError: responseResultが欠落または失敗を示す場合。
    """
    result = require_mapping(value, context)
    status = require_mapping(result.get("responseResult"), f"{context}.responseResult")
    if status.get("succeeded") is not True:
        message = status.get("message") or status.get("slug") or "unknown error"
        raise WikiJSGraphQLError(f"{context}に失敗しました: {message}")
    return result
