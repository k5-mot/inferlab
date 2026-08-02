#!/usr/bin/env bash
set -euo pipefail

# メール確認なしで使い始められるように、初期組織と管理者を直接作成する。
password_file="/data/initial-admin-password"
if [ -n "${ZULIP_AUTO_CREATE_ADMIN_PASSWORD:-}" ]; then
  # 明示passwordは永続volumeに残さず、一時file経由でZulip管理commandへ渡す。
  password_file="/tmp/zulip-initial-admin-password"
  printf "%s" "$ZULIP_AUTO_CREATE_ADMIN_PASSWORD" > "$password_file"
elif [ ! -s "$password_file" ]; then
    openssl rand -base64 32 > "$password_file"
fi
chown zulip:zulip "$password_file"
chmod 600 "$password_file"
export ZULIP_AUTO_CREATE_ADMIN_PASSWORD_FILE="$password_file"

su zulip -c "/home/zulip/deployments/current/manage.py shell" <<'PY'
import os

from django.core.management import call_command
from zerver.actions.realm_settings import (
    do_set_realm_property,
    do_set_realm_user_default_setting,
)
from zerver.models import Realm, RealmUserDefault, UserProfile

realm_id = os.environ.get("ZULIP_AUTO_CREATE_REALM_ID", "")
realm_name = os.environ.get("ZULIP_AUTO_CREATE_REALM_NAME", "InferLab")
admin_email = os.environ.get("ZULIP_AUTO_CREATE_ADMIN_EMAIL", "admin@example.com")
admin_name = os.environ.get("ZULIP_AUTO_CREATE_ADMIN_NAME", "InferLab Admin")
password_file = os.environ["ZULIP_AUTO_CREATE_ADMIN_PASSWORD_FILE"]
default_color_scheme = os.environ.get("ZULIP_DEFAULT_COLOR_SCHEME", "light").strip().lower()
apply_color_scheme_to_existing_users = os.environ.get(
    "ZULIP_APPLY_DEFAULT_COLOR_SCHEME_TO_EXISTING_USERS",
    "True",
).lower() in {"1", "true", "yes", "on"}
fluid_layout_width = os.environ.get("ZULIP_FLUID_LAYOUT_WIDTH", "True").lower() in {
    "1",
    "true",
    "yes",
    "on",
}
apply_fluid_layout_width_to_existing_users = os.environ.get(
    "ZULIP_APPLY_FLUID_LAYOUT_WIDTH_TO_EXISTING_USERS",
    "True",
).lower() in {"1", "true", "yes", "on"}

realm = Realm.objects.filter(string_id=realm_id).first()
if realm is None:
    # 初回起動ではorganizationとownerを同時に作る。
    call_command(
        "create_realm",
        realm_name,
        admin_email,
        admin_name,
        string_id=realm_id,
        password_file=password_file,
        automated=True,
    )
elif UserProfile.objects.filter(
    realm=realm,
    delivery_email__iexact=admin_email,
    is_bot=False,
).exists():
    print(f'Zulip admin user "{admin_email}" already exists. Skipping initial creation.')
else:
    # realmだけ存在する復旧・再実行時はowner userだけを補完する。
    call_command(
        "create_user",
        admin_email,
        admin_name,
        realm_id=realm_id,
        password_file=password_file,
        automated=True,
    )
    call_command(
        "change_user_role",
        admin_email,
        "owner",
        realm_id=realm_id,
        automated=True,
    )

realm = Realm.objects.get(string_id=realm_id)
if realm.invite_required:
    do_set_realm_property(realm, "invite_required", False, acting_user=None)

# 環境ごとの標準themeを、既存DBのまま再起動しても反映できるようにする。
color_scheme_by_name = {
    "auto": UserProfile.COLOR_SCHEME_AUTOMATIC,
    "automatic": UserProfile.COLOR_SCHEME_AUTOMATIC,
    "dark": UserProfile.COLOR_SCHEME_DARK,
    "light": UserProfile.COLOR_SCHEME_LIGHT,
}
if default_color_scheme.isdigit():
    color_scheme = int(default_color_scheme)
else:
    color_scheme = color_scheme_by_name.get(default_color_scheme, UserProfile.COLOR_SCHEME_LIGHT)
if color_scheme not in UserProfile.COLOR_SCHEME_CHOICES:
    print(
        f'Invalid ZULIP_DEFAULT_COLOR_SCHEME "{default_color_scheme}". Falling back to light.'
    )
    color_scheme = UserProfile.COLOR_SCHEME_LIGHT

realm_user_default = RealmUserDefault.objects.get(realm=realm)
if realm_user_default.color_scheme != color_scheme:
    do_set_realm_user_default_setting(
        realm_user_default,
        "color_scheme",
        color_scheme,
        acting_user=None,
    )

if apply_color_scheme_to_existing_users:
    UserProfile.objects.filter(realm=realm, is_bot=False).exclude(
        color_scheme=color_scheme,
    ).update(color_scheme=color_scheme)

# 折り畳み時の右余白をZulip標準のfluid layout設定で抑える。
if realm_user_default.fluid_layout_width != fluid_layout_width:
    do_set_realm_user_default_setting(
        realm_user_default,
        "fluid_layout_width",
        fluid_layout_width,
        acting_user=None,
    )

if apply_fluid_layout_width_to_existing_users:
    UserProfile.objects.filter(realm=realm, is_bot=False).exclude(
        fluid_layout_width=fluid_layout_width,
    ).update(fluid_layout_width=fluid_layout_width)
PY
