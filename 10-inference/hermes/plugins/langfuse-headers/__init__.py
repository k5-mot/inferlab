"""Hermesの実行時IDをLiteLLMのLangfuseヘッダーへ注入する。"""

from __future__ import annotations

import threading
from typing import Any


# llm_request middlewareではsender_idを直接参照できないため、
# turn_idを介して一時的に対応付ける。
_sender_by_turn: dict[str, str] = {}
_lock = threading.Lock()


def _remember_sender(**kwargs: Any) -> None:
    """Hermesのturn_idに対応するsender_idを一時保存する。

    Args:
        **kwargs: Hermesのpre_llm_call hookから渡される実行時情報。

    Returns:
        Noneを返す。

    Side Effects:
        turn_idとsender_idが揃っている場合、プロセス内メモリへ
        対応関係を保存する。
    """
    turn_id = kwargs.get("turn_id")
    sender_id = kwargs.get("sender_id")

    if turn_id is None or sender_id is None:
        return

    with _lock:
        _sender_by_turn[str(turn_id)] = str(sender_id)

    return


def _forget_sender(**kwargs: Any) -> None:
    """LLM呼び出し後にturn_idとsender_idの対応関係を削除する。

    Args:
        **kwargs: Hermesのpost_llm_call hookから渡される実行時情報。

    Returns:
        Noneを返す。

    Side Effects:
        turn_idが存在する場合、プロセス内メモリから対応関係を
        削除する。
    """
    turn_id = kwargs.get("turn_id")

    if turn_id is None:
        return

    with _lock:
        _sender_by_turn.pop(str(turn_id), None)

    return


def _inject_langfuse_headers(**kwargs: Any) -> dict[str, Any]:
    """Hermesの実行時IDをLiteLLM向けLangfuseヘッダーへ変換する。

    Args:
        **kwargs: Hermesのllm_request middlewareから渡されるrequestと
            実行時ID。

    Returns:
        更新済みrequest、middleware名、変更理由を含む辞書。

    Raises:
        KeyError: kwargsにrequestが含まれない場合。
    """
    request = dict(kwargs["request"])
    headers = dict(request.get("extra_headers") or {})
    request_metadata = request.get("metadata")
    metadata = dict(request_metadata) if isinstance(request_metadata, dict) else {}

    session_id = kwargs.get("session_id")
    turn_id = kwargs.get("turn_id")
    api_request_id = kwargs.get("api_request_id")

    # HermesのsessionはLangfuseのsessionとして束ねる。
    if session_id is not None:
        headers["langfuse_session_id"] = str(session_id)

    # HermesのturnはLangfuseのtraceとして扱う。
    if turn_id is not None:
        headers["langfuse_trace_id"] = str(turn_id)

        with _lock:
            sender_id = _sender_by_turn.get(str(turn_id))

        if sender_id is not None:
            headers["langfuse_trace_user_id"] = sender_id

    # 実際のprovider呼び出しはLangfuseのgenerationとして扱う。
    if api_request_id is not None:
        headers["langfuse_generation_id"] = str(api_request_id)

    # 設定側のextra_headersが欠けても、
    # Hermes traceとして識別できるようにする。
    headers.setdefault("langfuse_trace_name", "Hermes-Agent")
    headers.setdefault("langfuse_generation_name", "Hermes-Agent")

    # LiteLLM 1.94.1はlangfuse_tagsヘッダーを文字列として扱うため、
    # list前提の標準ログ処理を壊さないmetadata側へtagを渡す。
    tags = metadata.get("tags")
    if isinstance(tags, list):
        if "hermes-agent" not in tags:
            metadata["tags"] = [*tags, "hermes-agent"]
    elif tags is None:
        metadata["tags"] = ["hermes-agent"]

    request["extra_headers"] = headers
    request["metadata"] = metadata

    return {
        "request": request,
        "source": "litellm-langfuse-headers",
        "reason": "inject Hermes correlation IDs for Langfuse",
    }


def register(ctx: Any) -> None:
    """Hermesへhookとmiddlewareを登録する。

    Args:
        ctx: Hermesのplugin登録コンテキスト。

    Returns:
        Noneを返す。

    Side Effects:
        pre_llm_call、post_llm_call、llm_requestに処理を登録する。
    """
    # sender_idはturn単位のhookでだけ得られるため、
    # 先に記録してからrequestへ反映する。
    ctx.register_hook("pre_llm_call", _remember_sender)
    ctx.register_hook("post_llm_call", _forget_sender)

    # session_id、turn_id、api_request_idはrequest直前のmiddlewareで
    # headersへ移す。
    ctx.register_middleware("llm_request", _inject_langfuse_headers)
