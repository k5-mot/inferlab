#!/bin/sh
set -eu

# このscriptはVerdaccio起動後に、取得済みtgzを冪等にpublishする。
NPM_IMPORT_ENABLED="${NPM_IMPORT_ENABLED:-false}"
IMPORTS_DIR="${IMPORTS_DIR:-/imports}"
NPM_IMPORT_INTERVAL_SECONDS="${NPM_IMPORT_INTERVAL_SECONDS:-30}"
REGISTRY_URL="${REGISTRY_URL:-http://verdaccio:4873/}"
NPM_PUBLISH_TOKEN="${NPM_PUBLISH_TOKEN:-local-publish-token}"

case "$NPM_IMPORT_ENABLED" in
  true | TRUE | True | 1 | yes | YES | Yes | on | ON | On)
    ;;
  false | FALSE | False | 0 | no | NO | No | off | OFF | Off)
    echo "npm import disabled: set NPM_IMPORT_ENABLED=true to publish initial packages."
    while true; do
      sleep 86400
    done
    ;;
  *)
    echo "ERROR: NPM_IMPORT_ENABLED must be true or false." >&2
    exit 1
    ;;
esac

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
