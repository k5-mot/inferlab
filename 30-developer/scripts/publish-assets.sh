#!/usr/bin/env bash
set -euo pipefail

# このscriptはrepository rootから実行する。
ASSETS_DIR="${ASSETS_DIR:-30-developer/assets}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-}"
HARBOR_PROJECT="${HARBOR_PROJECT:-library}"
NPM_PUBLISH_TOKEN="${NPM_PUBLISH_TOKEN:-local-publish-token}"

# ASSETS_DIRが相対pathでも絶対pathでも扱えるようにする。
case "$ASSETS_DIR" in
  /*) ASSETS_PATH="$ASSETS_DIR" ;;
  *) ASSETS_PATH="$PWD/$ASSETS_DIR" ;;
esac

# 配信serviceを起動する。
docker compose -f "$COMPOSE_FILE" --env-file .env --profile developer up -d pypiserver verdaccio rpm-repo deb-repo code-marketplace

# PyPI packageをpypiserverの永続volumeへpublishする。
if [ -d "$ASSETS_PATH/pypi" ]; then
  docker compose -f "$COMPOSE_FILE" --env-file .env --profile developer run --rm --no-deps -v "$ASSETS_PATH/pypi:/imports:ro" asset-publisher sh -eu -c 'set -- /imports/*; [ -e "$1" ] || exit 0; mkdir -p /publish/pypi && cp -f "$@" /publish/pypi/'
fi

# npm packageをVerdaccioへpublishする。
if [ -d "$ASSETS_PATH/npm" ]; then
  if find "$ASSETS_PATH/npm" -maxdepth 1 -name '*.tgz' | grep -q .; then
    docker compose -f "$COMPOSE_FILE" --env-file .env --profile developer run --rm --no-deps -e NPM_PUBLISH_TOKEN -v "$ASSETS_PATH/npm:/imports:ro" npm-publisher sh -eu -c 'npm config set //verdaccio:4873/:_authToken "$NPM_PUBLISH_TOKEN"; for file in /imports/*.tgz; do package=$(tar -xOf "$file" package/package.json | node -e "let s=\"\"; process.stdin.on(\"data\", d => s += d); process.stdin.on(\"end\", () => { const p = JSON.parse(s); console.log(p.name + \"@\" + p.version); });"); if npm view "$package" version --registry http://verdaccio:4873/ >/dev/null 2>&1; then echo "skip npm: $package"; else npm publish "$file" --registry http://verdaccio:4873/ --ignore-scripts; fi; done'
  fi
fi

# RPM packageを配置してmetadataを生成する。
if [ -d "$ASSETS_PATH/rpm" ]; then
  docker compose -f "$COMPOSE_FILE" --env-file .env --profile developer run --rm --no-deps -v "$ASSETS_PATH/rpm:/imports:ro" rpm-publisher sh -eu -c 'mkdir -p /repo && rsync -a --delete /imports/ /repo/ && createrepo_c --update /repo && cat > /repo/index.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>createrepo_c</title></head>
<body>
<h1>createrepo_c</h1>
<p>RPM source repository for dnf/yum.</p>
<ul>
  <li><a href="./repodata/repomd.xml">repodata/repomd.xml</a></li>
</ul>
</body>
</html>
EOF'
fi

# deb packageをaptly local repositoryへ登録してpublishする。
if [ -d "$ASSETS_PATH/deb" ]; then
  docker compose -f "$COMPOSE_FILE" --env-file .env --profile developer run --rm --no-deps -v "$ASSETS_PATH/deb:/imports:ro" aptly-publisher sh -eu -c 'set -- /imports/*.deb; [ -e "$1" ] || exit 0; repo=deb-internal; snapshot="${repo}-$(date +%Y%m%d%H%M%S)"; aptly repo show "$repo" >/dev/null 2>&1 || aptly repo create -distribution=stable -component=main "$repo"; aptly repo add -force-replace "$repo" /imports; aptly snapshot create "$snapshot" from repo "$repo"; if aptly publish show stable filesystem:public: >/dev/null 2>&1; then aptly publish switch -skip-signing stable filesystem:public: "$snapshot"; else aptly publish snapshot -skip-signing -distribution=stable -component=main "$snapshot" filesystem:public:; fi; cat > /public/index.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>aptly</title></head>
<body>
<h1>aptly</h1>
<p>APT source repository.</p>
<ul>
  <li><a href="./dists/stable/Release">dists/stable/Release</a></li>
</ul>
</body>
</html>
EOF'
fi

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
