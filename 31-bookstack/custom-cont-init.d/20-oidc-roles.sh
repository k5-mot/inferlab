#!/usr/bin/with-contenv sh
set -eu

# Keycloakユーザーがログイン直後から執筆できるように、OIDCグループと初期ロールをそろえる。
mariadb \
  -h "${DB_HOST}" \
  -P "${DB_PORT:-3306}" \
  -u "${DB_USERNAME}" \
  "-p${DB_PASSWORD}" \
  "${DB_DATABASE}" <<'SQL'
UPDATE roles
SET external_auth_id = 'admins'
WHERE system_name = 'admin'
  AND external_auth_id = '';

UPDATE roles
SET external_auth_id = 'users'
WHERE display_name = 'Editor'
  AND external_auth_id = '';

INSERT INTO settings (setting_key, value, created_at, updated_at, type)
VALUES ('registration-role', '2', NOW(), NOW(), 'string')
ON DUPLICATE KEY UPDATE
  value = VALUES(value),
  updated_at = VALUES(updated_at),
  type = VALUES(type);

INSERT IGNORE INTO role_user (user_id, role_id)
SELECT users.id, 2
FROM users
LEFT JOIN role_user ON role_user.user_id = users.id
WHERE users.system_name IS NULL
  AND users.external_auth_id <> ''
  AND role_user.user_id IS NULL;
SQL
