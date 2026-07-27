#!/usr/bin/env bash
set -euo pipefail

# このscriptはrepository rootから実行し、資材directoryを同期してserviceを起動する。
ASSETS_DIR="${ASSETS_DIR:-30-developer}"
TARGET_ASSETS_DIR="${TARGET_ASSETS_DIR:-30-developer}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-}"
HARBOR_PROJECT="${HARBOR_PROJECT:-library}"

# ASSETS_DIRが相対pathでも絶対pathでも扱えるようにする。
case "$ASSETS_DIR" in
  /*) ASSETS_PATH="$ASSETS_DIR" ;;
  *) ASSETS_PATH="$PWD/$ASSETS_DIR" ;;
esac

case "$TARGET_ASSETS_DIR" in
  /*) TARGET_ASSETS_PATH="$TARGET_ASSETS_DIR" ;;
  *) TARGET_ASSETS_PATH="$PWD/$TARGET_ASSETS_DIR" ;;
esac

# 外部assetsを使う場合だけ、composeがbind mountするdirectoryへfileを同期する。
if [ "$ASSETS_PATH" != "$TARGET_ASSETS_PATH" ]; then
  for name in pypi npm rpm deb; do
    source_dir="$ASSETS_PATH/$name"
    target_dir="$TARGET_ASSETS_PATH/$name"
    mkdir -p "$target_dir"
    if [ -d "$source_dir" ]; then
      find "$source_dir" -maxdepth 1 -type f -exec cp -f {} "$target_dir/" \;
    fi
  done
fi

# 配信serviceと自動取り込みjobを起動する。
docker compose -f "$COMPOSE_FILE" --env-file .env --profile developer up -d pypiserver verdaccio npm-importer rpm-repo deb-repo code-marketplace

# VSIXをcode-marketplaceへ登録する。
if [ -d "$ASSETS_PATH/vsix" ]; then
  if find "$ASSETS_PATH/vsix" -maxdepth 1 -name '*.vsix' | grep -q .; then
    docker compose -f "$COMPOSE_FILE" --env-file .env --profile developer run --rm --no-deps --entrypoint code-marketplace -v "$ASSETS_PATH/vsix:/imports:ro" code-marketplace-publisher add --extensions-dir=/extensions /imports
  fi
fi

# container image tarをHarborへpushする。
if [ -n "$HARBOR_REGISTRY" ] && [ -d "$ASSETS_PATH/docker" ]; then
  [ -f "$ASSETS_PATH/docker/hello-world_latest.tar" ] && crane push "$ASSETS_PATH/docker/hello-world_latest.tar" "$HARBOR_REGISTRY/$HARBOR_PROJECT/hello-world:latest"
  [ -f "$ASSETS_PATH/docker/ollama_ollama_latest.tar" ] && crane push "$ASSETS_PATH/docker/ollama_ollama_latest.tar" "$HARBOR_REGISTRY/$HARBOR_PROJECT/ollama/ollama:latest"
fi
