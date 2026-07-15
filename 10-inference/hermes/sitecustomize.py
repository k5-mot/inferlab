"""Hermes Dashboard の Basic 認証起動時パッチ。"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def _patch_hermes_basic_auth_auto_sso() -> None:
    """Basic 認証 provider だけが有効な場合に自動 SSO を抑止する。

    パラメータ:
        なし。

    戻り値:
        なし。

    副作用:
        Hermes Dashboard の認証ミドルウェア関数をプロセス内で差し替える。
        Basic 認証では OAuth 開始 URL が未実装のため、通常のログインフォームへ
        フォールバックさせる。
    """
    try:
        from hermes_cli.dashboard_auth import list_session_providers
        from hermes_cli.dashboard_auth import middleware
    except Exception as exc:
        logger.debug("Hermes Basic 認証パッチを読み込めませんでした: %s", exc)
        return

    original_auto_sso_response = middleware._auto_sso_response

    def patched_auto_sso_response(request):
        """Basic 認証のみの構成ではログインフォーム表示へ委譲する。

        パラメータ:
            request: FastAPI のリクエストオブジェクト。

        戻り値:
            Basic 認証のみの場合は None。それ以外は元の自動 SSO 応答。
        """
        providers = list_session_providers()
        if (
            len(providers) == 1
            and getattr(providers[0], "name", "") == "basic"
            and getattr(providers[0], "supports_password", False)
        ):
            return None
        return original_auto_sso_response(request)

    middleware._auto_sso_response = patched_auto_sso_response


_patch_hermes_basic_auth_auto_sso()
