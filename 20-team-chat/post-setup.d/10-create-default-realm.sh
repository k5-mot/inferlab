#!/usr/bin/env bash
set -euo pipefail

# AirGap環境でもメール確認なしで使い始められるように、初期組織と管理者を直接作成する。
password_file="/data/initial-admin-password"
if [ -n "${ZULIP_AUTO_CREATE_ADMIN_PASSWORD:-}" ]; then
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
from zerver.actions.realm_settings import do_set_realm_property
from zerver.models import Realm, UserProfile

realm_id = os.environ.get("ZULIP_AUTO_CREATE_REALM_ID", "")
realm_name = os.environ.get("ZULIP_AUTO_CREATE_REALM_NAME", "InferLab")
admin_email = os.environ.get("ZULIP_AUTO_CREATE_ADMIN_EMAIL", "admin@example.com")
admin_name = os.environ.get("ZULIP_AUTO_CREATE_ADMIN_NAME", "InferLab Admin")
password_file = os.environ["ZULIP_AUTO_CREATE_ADMIN_PASSWORD_FILE"]

realm = Realm.objects.filter(string_id=realm_id).first()
if realm is None:
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
PY
