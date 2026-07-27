#!/bin/sh
set -eu

# このscriptはVerdaccio起動後に、取得済みtgzを冪等にpublishする。
IMPORTS_DIR="${IMPORTS_DIR:-/imports}"
NPM_IMPORT_INTERVAL_SECONDS="${NPM_IMPORT_INTERVAL_SECONDS:-30}"
REGISTRY_URL="${REGISTRY_URL:-http://verdaccio:4873/}"
NPM_PUBLISH_TOKEN="${NPM_PUBLISH_TOKEN:-local-publish-token}"

npm config set "//verdaccio:4873/:_authToken" "$NPM_PUBLISH_TOKEN"

while true; do
  set -- "$IMPORTS_DIR"/*.tgz
  if [ -e "$1" ]; then
    for file in "$IMPORTS_DIR"/*.tgz; do
      package="$(
        tar -xOf "$file" package/package.json |
          node -e 'let s = ""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => { const p = JSON.parse(s); console.log(p.name + "@" + p.version); });'
      )"

      if npm view "$package" version --registry "$REGISTRY_URL" >/dev/null 2>&1; then
        echo "skip npm: $package"
      else
        npm publish "$file" --registry "$REGISTRY_URL" --ignore-scripts
      fi
    done
  fi

  sleep "$NPM_IMPORT_INTERVAL_SECONDS"
done
