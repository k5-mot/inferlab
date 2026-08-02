#!/bin/sh
set -eu

# plugin daemonは専用DB `dify_plugin` を要求するが、Dify本体のmigration対象外。
# PostgreSQL起動後に存在確認して、未作成の場合だけ追加する。
if psql -h dify-postgres -U dify_user -d dify_db -tAc "SELECT 1 FROM pg_database WHERE datname = 'dify_plugin'" | grep -q '^1$'; then
  echo "dify_plugin database already exists."
  exit 0
fi

psql -h dify-postgres -U dify_user -d dify_db -c "CREATE DATABASE dify_plugin OWNER dify_user;"
