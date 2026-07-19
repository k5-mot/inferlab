#!/usr/bin/env python3
"""OpenWebUI の Channels 応答ストリームと本文抽出のパッチを適用する。"""

from __future__ import annotations

import os
from pathlib import Path


TARGET_PATH = Path(
    os.environ.get(
        "OPEN_WEBUI_MAIN_PATH",
        "/app/backend/open_webui/main.py",
    )
)
SOCKET_PATH = Path(
    os.environ.get(
        "OPEN_WEBUI_SOCKET_PATH",
        "/app/backend/open_webui/socket/main.py",
    )
)

OLD_SNIPPET = """            ctx = await build_chat_response_context(request, form_data, user, model, metadata, tasks, events)

            return await process_chat_response(response, ctx)
"""

NEW_SNIPPET = """            ctx = await build_chat_response_context(request, form_data, user, model, metadata, tasks, events)

            processed_response = await process_chat_response(response, ctx)
            if metadata.get('chat_id', '').startswith('channel:') and isinstance(processed_response, StreamingResponse):
                # Channels は HTTP クライアントへ StreamingResponse を返さないため、ここで読み切って socket 更新を発火させる。
                async for _ in processed_response.body_iterator:
                    pass
                if processed_response.background:
                    await processed_response.background()
                return {'status': True}

            return processed_response
"""

OLD_SOCKET_SNIPPET = """    state = {'last_emit_at': 0.0}
    THROTTLE_INTERVAL = 0.15  # ~6 updates/sec

    async def _emit_channel_update(content: str, done: bool = False):
        from open_webui.models.messages import MessageForm, Messages

        msg = await Messages.get_message_by_id(message_id)
        if not msg or msg.channel_id != channel_id:
            return

        update_form = MessageForm(content=content)
        if done:
            # Merge done flag into existing meta (preserve model_id etc.)
            existing_meta = msg.meta or {}
            update_form = MessageForm(
                content=content,
                meta={**existing_meta, 'done': True},
            )

        await Messages.update_message_by_id(message_id, update_form)
        message = await Messages.get_message_by_id(message_id)
        if message:
            await sio.emit(
                'events:channel',
                {
                    'channel_id': channel_id,
                    'message_id': message_id,
                    'data': {
                        'type': 'message:update',
                        'data': message.model_dump(),
                    },
                },
                to=f'channel:{channel_id}',
            )

    async def __channel_emitter__(event_data):
        event_type = event_data.get('type')

        if event_type == 'chat:completion':
            data = event_data.get('data', {})
            content = data.get('content', '')
            done = data.get('done', False)

            if not content and not done:
                return

            now = __import__('time').time()
            if done or (now - state['last_emit_at']) >= THROTTLE_INTERVAL:
                state['last_emit_at'] = now
                await _emit_channel_update(content, done)
"""

NEW_SOCKET_SNIPPET = """    state = {'last_emit_at': 0.0}
    THROTTLE_INTERVAL = 0.15  # 更新頻度を抑えて DB と socket の負荷を避ける。

    def _extract_channel_content(data: dict) -> str:
        \"""channel 用の保存本文を OpenAI 形式と Open WebUI output 形式の両方から取り出す。

        Args:
            data: chat:completion イベントの data ペイロード。

        Returns:
            message.content に保存する文字列。本文が見つからない場合は空文字列。
        \"""
        content = data.get('content', '')
        if isinstance(content, str) and content:
            return content

        output = data.get('output')
        if not isinstance(output, list):
            return ''

        texts = []
        for item in output:
            if not isinstance(item, dict) or item.get('type') != 'message':
                continue
            for part in item.get('content', []) or []:
                if not isinstance(part, dict):
                    continue
                if part.get('type') == 'output_text' and isinstance(part.get('text'), str):
                    texts.append(part['text'])
                elif isinstance(part.get('text'), str):
                    texts.append(part['text'])

        return '\\n'.join(text for text in texts if text).strip()

    async def _emit_channel_update(content: str, done: bool = False):
        \"""Channels の返信メッセージを DB と購読中の socket に反映する。

        Args:
            content: message.content に保存する本文。
            done: 生成完了イベントとして meta.done を更新するかどうか。

        Returns:
            なし。

        Side Effects:
            OpenWebUI の message レコードを更新し、channel 購読者へ socket イベントを送信する。
        \"""
        from open_webui.models.messages import MessageForm, Messages

        msg = await Messages.get_message_by_id(message_id)
        if not msg or msg.channel_id != channel_id:
            return

        update_form = MessageForm(content=content)
        if done:
            # Channels の完了状態は meta に保持し、モデル名などの既存情報は残す。
            existing_meta = msg.meta or {}
            update_form = MessageForm(
                content=content,
                meta={**existing_meta, 'done': True},
            )

        await Messages.update_message_by_id(message_id, update_form)
        message = await Messages.get_message_by_id(message_id)
        if message:
            await sio.emit(
                'events:channel',
                {
                    'channel_id': channel_id,
                    'message_id': message_id,
                    'data': {
                        'type': 'message:update',
                        'data': message.model_dump(),
                    },
                },
                to=f'channel:{channel_id}',
            )

    async def __channel_emitter__(event_data):
        \"""chat:completion イベントを Channels 用のメッセージ更新へ変換する。

        Args:
            event_data: OpenWebUI のイベントペイロード。

        Returns:
            なし。

        Side Effects:
            本文または完了状態がある場合に Channels メッセージを更新する。
        \"""
        event_type = event_data.get('type')

        if event_type == 'chat:completion':
            data = event_data.get('data', {})
            content = _extract_channel_content(data)
            done = data.get('done', False)

            if not content and not done:
                return

            now = __import__('time').time()
            if done or (now - state['last_emit_at']) >= THROTTLE_INTERVAL:
                state['last_emit_at'] = now
                await _emit_channel_update(content, done)
"""


def replace_once(target_path: Path, old_snippet: str, new_snippet: str, marker: str) -> bool:
    """指定されたファイルで期待するコード断片を一度だけ差し替える。

    Args:
        target_path: パッチ対象のファイルパス。
        old_snippet: 差し替え前のコード断片。
        new_snippet: 差し替え後のコード断片。
        marker: 適用済み判定に使う一意な文字列。

    Returns:
        新しくパッチを適用した場合は True、既に適用済みの場合は False。

    Raises:
        FileNotFoundError: 対象ファイルが存在しない場合。
        RuntimeError: 期待する差し替え箇所が見つからない場合。
    """
    source = target_path.read_text(encoding="utf-8")

    if marker in source:
        return False

    if old_snippet not in source:
        raise RuntimeError(f"patch target snippet not found in {target_path}")

    target_path.write_text(source.replace(old_snippet, new_snippet, 1), encoding="utf-8")
    return True


def apply_patch(target_path: Path, socket_path: Path) -> bool:
    """OpenWebUI の Channels 応答に必要な複数パッチを適用する。

    Args:
        target_path: chat completion 本体の Python ファイルパス。
        socket_path: socket emitter 本体の Python ファイルパス。

    Returns:
        いずれかのファイルに新しい変更を適用した場合は True。

    Raises:
        FileNotFoundError: 対象ファイルが存在しない場合。
        RuntimeError: 期待する差し替え箇所が見つからない場合。
    """
    changed_main = replace_once(
        target_path,
        OLD_SNIPPET,
        NEW_SNIPPET,
        "Channels は HTTP クライアントへ StreamingResponse を返さないため",
    )
    changed_socket = replace_once(
        socket_path,
        OLD_SOCKET_SNIPPET,
        NEW_SOCKET_SNIPPET,
        "channel 用の保存本文を OpenAI 形式と Open WebUI output 形式の両方から取り出す",
    )
    return changed_main or changed_socket


def main() -> int:
    """コマンドライン実行時にパッチを適用し、結果を標準出力へ表示する。

    Args:
        なし。

    Returns:
        正常終了時は 0。
    """
    changed = apply_patch(TARGET_PATH, SOCKET_PATH)
    status = "applied" if changed else "already-applied"
    print(f"open-webui channel stream patch: {status}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
