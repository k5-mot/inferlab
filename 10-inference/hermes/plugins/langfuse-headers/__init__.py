"""Hermesの実行時IDをLiteLLMのLangfuseヘッダーへ注入する。"""

from __future__ import annotations

import functools
import threading
from typing import Any


# llm_request middlewareではsender_idを直接参照できないため、
# turn_idを介して一時的に対応付ける。
_sender_by_turn: dict[str, str] = {}
_lock = threading.Lock()
_RELAY_PATCH_MARKER = "_litellm_langfuse_headers_patched"


def _normalize_tag(value: Any) -> str:
    """Langfuse tagとして使う値を小文字ケバブケースへ正規化する。

    Args:
        value: tag候補の任意の値。

    Returns:
        英数字とハイフンだけに正規化したtag文字列を返す。空値の場合は
        空文字列を返す。
    """
    normalized = str(value or "").strip().lower().replace("_", "-")
    normalized = normalized.replace(":", "-")
    return "".join(
        char for char in normalized if char.isalnum() or char == "-"
    ).strip("-")


def _scope_tag(**kwargs: Any) -> str:
    """HermesのLLM呼び出し種別を表すLangfuse tagを決定する。

    Args:
        **kwargs: Hermes middlewareまたはRelay metadata由来の実行時情報。

    Returns:
        補助タスクの場合はタスク名由来のtag、通常会話の場合はchatを
        返す。
    """
    auxiliary_task = _normalize_tag(kwargs.get("auxiliary_task"))
    if auxiliary_task:
        return auxiliary_task

    call_role = str(kwargs.get("call_role") or "")
    if call_role.startswith("auxiliary:"):
        return _normalize_tag(call_role.split(":", 1)[1])

    return "chat"


def _append_langfuse_tags(metadata: dict[str, Any], *extra_tags: str) -> None:
    """LiteLLMへ渡すmetadata.tagsへLangfuse分類tagを追加する。

    Args:
        metadata: LiteLLM request metadata。関数内で更新される。
        *extra_tags: 追加したいtag文字列。

    Returns:
        Noneを返す。

    Side Effects:
        metadata["tags"]をlistとして設定または更新する。
    """
    raw_tags = metadata.get("tags")
    if isinstance(raw_tags, list):
        tags = list(raw_tags)
    elif raw_tags is None:
        tags = []
    else:
        tags = [str(raw_tags)]

    for tag in ("hermes-agent", *extra_tags):
        normalized = _normalize_tag(tag)
        if normalized and normalized not in tags:
            tags.append(normalized)

    metadata["tags"] = tags


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
    _append_langfuse_tags(metadata, _scope_tag(**kwargs))

    request["extra_headers"] = headers
    request["metadata"] = metadata

    return {
        "request": request,
        "source": "litellm-langfuse-headers",
        "reason": "inject Hermes correlation IDs for Langfuse",
    }


def _relay_context() -> Any | None:
    """現在のHermes Relay turnを取得する。

    Args:
        なし。

    Returns:
        active turnが存在する場合はRelayTurnContext、存在しない場合は
        Noneを返す。
    """
    try:
        from agent import relay_runtime

        return relay_runtime.active_turn()
    except Exception:
        return None


def _ambient_session_id() -> str:
    """補助スレッドに残されたHermes session IDを取得する。

    Args:
        なし。

    Returns:
        session IDが取得できた場合は文字列、取得できない場合は空文字列を
        返す。
    """
    try:
        from agent.portal_tags import get_conversation_context

        conversation_id = get_conversation_context()
        if conversation_id:
            return str(conversation_id)
    except Exception:
        pass

    try:
        from agent.aux_accounting import get_accounting_context

        accounting_context = get_accounting_context()
        if accounting_context is not None:
            _session_db, session_id = accounting_context
            if session_id:
                return str(session_id)
    except Exception:
        pass

    return ""


def _inject_relay_langfuse_headers(
    request: dict[str, Any],
    *,
    session_id: str | None,
    name: str,
    model_name: str,
    metadata: dict[str, Any] | None,
) -> dict[str, Any]:
    """Relay経由のLLM requestへLiteLLM向けLangfuseヘッダーを注入する。

    Args:
        request: providerへ送信されるOpenAI互換request。
        session_id: 呼び出し元が明示したHermes session ID。
        name: Relayへ記録されるprovider名。
        model_name: Relayへ記録されるmodel名。
        metadata: Relay呼び出しに付与された補助メタデータ。

    Returns:
        Langfuseヘッダーを追加したrequestを返す。注入に失敗した場合は
        元のrequestを返す。
    """
    if not isinstance(request, dict):
        return request

    api_request_id = (metadata or {}).get("api_request_id")
    relay_turn = _relay_context()
    effective_session_id = session_id or _ambient_session_id()
    turn_id = None
    task_id = None
    platform = None

    if relay_turn is not None:
        turn_id = getattr(relay_turn, "turn_id", None)
        task_id = getattr(relay_turn, "task_id", None)
        lease = getattr(relay_turn, "lease", None)
        if lease is not None:
            effective_session_id = str(
                getattr(lease, "session_id", None) or effective_session_id or ""
            )
            platform = getattr(lease, "platform", None)

    # title_generationなどのdaemon threadではactive turnが既に消えている。
    # その場合もLangfuse上で孤立traceにしないため、sessionと補助request ID
    # から安定したtrace IDを合成する。
    if turn_id is None and effective_session_id and api_request_id:
        turn_id = f"{effective_session_id}:{api_request_id}"

    try:
        result = _inject_langfuse_headers(
            request=request,
            session_id=effective_session_id,
            task_id=task_id,
            turn_id=turn_id,
            api_request_id=api_request_id,
            platform=platform or "",
            model=model_name or request.get("model"),
            provider=name,
            api_mode=(metadata or {}).get("api_mode"),
            auxiliary_task=(metadata or {}).get("auxiliary_task"),
            call_role=(metadata or {}).get("call_role"),
        )
    except Exception:
        return request

    next_request = result.get("request")
    return next_request if isinstance(next_request, dict) else request


def _patch_relay_llm() -> None:
    """Hermes Relay経由の補助LLM呼び出しにもヘッダー注入を適用する。

    Args:
        なし。

    Returns:
        Noneを返す。

    Side Effects:
        agent.relay_llmのexecute、execute_async、streamをプロセス内で
        ラップする。既にラップ済みの場合は何もしない。
    """
    try:
        from agent import relay_llm
    except Exception:
        return

    if getattr(relay_llm, _RELAY_PATCH_MARKER, False):
        return

    original_execute = relay_llm.execute
    original_execute_async = relay_llm.execute_async
    original_execute_current = relay_llm.execute_current
    original_execute_current_async = relay_llm.execute_current_async
    original_stream = relay_llm.stream
    original_stream_current = relay_llm.stream_current

    @functools.wraps(original_execute)
    def execute_with_langfuse_headers(
        request: dict[str, Any],
        callback: Any,
        *,
        session_id: str,
        name: str,
        model_name: str,
        metadata: dict[str, Any] | None = None,
        defer_logical_completion: bool = False,
    ) -> Any:
        """同期Relay実行前にLangfuseヘッダーを補完する。

        Args:
            request: providerへ送信されるOpenAI互換request。
            callback: 実際のprovider呼び出し関数。
            session_id: Hermes session ID。
            name: provider名。
            model_name: model名。
            metadata: Relay呼び出しメタデータ。
            defer_logical_completion: 論理呼び出し完了を遅延するか。

        Returns:
            元のRelay実行結果を返す。
        """
        request = _inject_relay_langfuse_headers(
            request,
            session_id=session_id,
            name=name,
            model_name=model_name,
            metadata=metadata,
        )
        return original_execute(
            request,
            callback,
            session_id=session_id,
            name=name,
            model_name=model_name,
            metadata=metadata,
            defer_logical_completion=defer_logical_completion,
        )

    @functools.wraps(original_execute_current)
    def execute_current_with_langfuse_headers(
        request: dict[str, Any],
        callback: Any,
        *,
        name: str,
        model_name: str,
        metadata: dict[str, Any] | None = None,
        defer_logical_completion: bool = False,
    ) -> Any:
        """現在のRelay turnが無い補助実行にもLangfuseヘッダーを補完する。

        Args:
            request: providerへ送信されるOpenAI互換request。
            callback: 実際のprovider呼び出し関数。
            name: provider名。
            model_name: model名。
            metadata: Relay呼び出しメタデータ。
            defer_logical_completion: 論理呼び出し完了を遅延するか。

        Returns:
            元のRelay実行結果を返す。
        """
        request = _inject_relay_langfuse_headers(
            request,
            session_id=None,
            name=name,
            model_name=model_name,
            metadata=metadata,
        )
        return original_execute_current(
            request,
            callback,
            name=name,
            model_name=model_name,
            metadata=metadata,
            defer_logical_completion=defer_logical_completion,
        )

    @functools.wraps(original_execute_async)
    async def execute_async_with_langfuse_headers(
        request: dict[str, Any],
        callback: Any,
        *,
        session_id: str,
        name: str,
        model_name: str,
        metadata: dict[str, Any] | None = None,
        defer_logical_completion: bool = False,
    ) -> Any:
        """非同期Relay実行前にLangfuseヘッダーを補完する。

        Args:
            request: providerへ送信されるOpenAI互換request。
            callback: 実際のprovider呼び出し関数。
            session_id: Hermes session ID。
            name: provider名。
            model_name: model名。
            metadata: Relay呼び出しメタデータ。
            defer_logical_completion: 論理呼び出し完了を遅延するか。

        Returns:
            元のRelay実行結果を返す。
        """
        request = _inject_relay_langfuse_headers(
            request,
            session_id=session_id,
            name=name,
            model_name=model_name,
            metadata=metadata,
        )
        return await original_execute_async(
            request,
            callback,
            session_id=session_id,
            name=name,
            model_name=model_name,
            metadata=metadata,
            defer_logical_completion=defer_logical_completion,
        )

    @functools.wraps(original_execute_current_async)
    async def execute_current_async_with_langfuse_headers(
        request: dict[str, Any],
        callback: Any,
        *,
        name: str,
        model_name: str,
        metadata: dict[str, Any] | None = None,
        defer_logical_completion: bool = False,
    ) -> Any:
        """現在のRelay turnが無い非同期補助実行にもヘッダーを補完する。

        Args:
            request: providerへ送信されるOpenAI互換request。
            callback: 実際のprovider呼び出し関数。
            name: provider名。
            model_name: model名。
            metadata: Relay呼び出しメタデータ。
            defer_logical_completion: 論理呼び出し完了を遅延するか。

        Returns:
            元のRelay実行結果を返す。
        """
        request = _inject_relay_langfuse_headers(
            request,
            session_id=None,
            name=name,
            model_name=model_name,
            metadata=metadata,
        )
        return await original_execute_current_async(
            request,
            callback,
            name=name,
            model_name=model_name,
            metadata=metadata,
            defer_logical_completion=defer_logical_completion,
        )

    @functools.wraps(original_stream)
    def stream_with_langfuse_headers(
        request: dict[str, Any],
        stream_factory: Any,
        *,
        session_id: str,
        name: str,
        model_name: str,
        finalizer: Any,
        on_stream_created: Any = None,
        on_chunk: Any = None,
        chunk_adapter: Any = None,
        accept_chunk: Any = None,
        completed_response_predicate: Any = None,
        metadata: dict[str, Any] | None = None,
        defer_logical_completion: bool = False,
    ) -> Any:
        """Relay stream開始前にLangfuseヘッダーを補完する。

        Args:
            request: providerへ送信されるOpenAI互換request。
            stream_factory: 実際のprovider stream生成関数。
            session_id: Hermes session ID。
            name: provider名。
            model_name: model名。
            finalizer: stream完了時の集約関数。
            on_stream_created: stream生成時のcallback。
            on_chunk: chunk受信時のcallback。
            chunk_adapter: chunk変換関数。
            accept_chunk: chunk受理判定関数。
            completed_response_predicate: 完了済み応答判定関数。
            metadata: Relay呼び出しメタデータ。
            defer_logical_completion: 論理呼び出し完了を遅延するか。

        Returns:
            元のRelay stream実行結果を返す。
        """
        request = _inject_relay_langfuse_headers(
            request,
            session_id=session_id,
            name=name,
            model_name=model_name,
            metadata=metadata,
        )
        return original_stream(
            request,
            stream_factory,
            session_id=session_id,
            name=name,
            model_name=model_name,
            finalizer=finalizer,
            on_stream_created=on_stream_created,
            on_chunk=on_chunk,
            chunk_adapter=chunk_adapter,
            accept_chunk=accept_chunk,
            completed_response_predicate=completed_response_predicate,
            metadata=metadata,
            defer_logical_completion=defer_logical_completion,
        )

    @functools.wraps(original_stream_current)
    def stream_current_with_langfuse_headers(
        request: dict[str, Any],
        stream_factory: Any,
        *,
        name: str,
        model_name: str,
        finalizer: Any,
        metadata: dict[str, Any] | None = None,
        defer_logical_completion: bool = False,
        completed_response_predicate: Any = None,
    ) -> Any:
        """現在のRelay turnが無い補助streamにもヘッダーを補完する。

        Args:
            request: providerへ送信されるOpenAI互換request。
            stream_factory: 実際のprovider stream生成関数。
            name: provider名。
            model_name: model名。
            finalizer: stream完了時の集約関数。
            metadata: Relay呼び出しメタデータ。
            defer_logical_completion: 論理呼び出し完了を遅延するか。
            completed_response_predicate: 完了済み応答判定関数。

        Returns:
            元のRelay stream実行結果を返す。
        """
        request = _inject_relay_langfuse_headers(
            request,
            session_id=None,
            name=name,
            model_name=model_name,
            metadata=metadata,
        )
        return original_stream_current(
            request,
            stream_factory,
            name=name,
            model_name=model_name,
            finalizer=finalizer,
            metadata=metadata,
            defer_logical_completion=defer_logical_completion,
            completed_response_predicate=completed_response_predicate,
        )

    relay_llm.execute = execute_with_langfuse_headers
    relay_llm.execute_async = execute_async_with_langfuse_headers
    relay_llm.execute_current = execute_current_with_langfuse_headers
    relay_llm.execute_current_async = execute_current_async_with_langfuse_headers
    relay_llm.stream = stream_with_langfuse_headers
    relay_llm.stream_current = stream_current_with_langfuse_headers
    setattr(relay_llm, _RELAY_PATCH_MARKER, True)


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

    # 補助LLM呼び出しはconversation_loopのrequest middlewareを通らず
    # relay_llmへ直接入るため、同じ注入処理をrelay入口にも適用する。
    _patch_relay_llm()
