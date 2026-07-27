#!/usr/bin/env bash
set -euo pipefail

# このscriptはdocker save形式のarchiveをHarborへ冪等にpushする。
ARCHIVES_DIR="${ARCHIVES_DIR:-/archives}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-proxy:8080}"
HARBOR_PROJECT="${HARBOR_PROJECT:-library}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
HARBOR_TLS_VERIFY="${HARBOR_TLS_VERIFY:-false}"
IMPORT_INTERVAL_SECONDS="${DOCKER_ARCHIVE_IMPORT_INTERVAL_SECONDS:-30}"
STATE_DIR="${STATE_DIR:-/state}"

mkdir -p "$STATE_DIR"

while true; do
  shopt -s nullglob
  archive_files=("$ARCHIVES_DIR"/*.tar)

  for file in "${archive_files[@]}"; do
    checksum="$(sha256sum "$file" | awk '{print $1}')"
    manifest="$(tar -xOf "$file" manifest.json 2>/dev/null || true)"
    repo_tags="$(
      printf '%s' "$manifest" |
        tr -d '\n' |
        sed 's/},{/}\n{/g' |
        sed -n 's/.*"RepoTags":[[]\([^]]*\)[]].*/\1/p' |
        tr ',' '\n' |
        tr -d '" ' |
        sed '/^$/d;/^<none>:/d'
    )"

    if [ -z "$repo_tags" ]; then
      echo "skip docker archive without RepoTags: $file"
      continue
    fi

    while IFS= read -r source_ref; do
      target_ref="$source_ref"
      first_segment="${target_ref%%/*}"
      case "$first_segment" in
        *.* | *:* | localhost)
          target_ref="${target_ref#*/}"
          ;;
      esac

      state_name="$(printf '%s' "$target_ref" | tr '/:' '__')"
      state_file="$STATE_DIR/$state_name.sha256"
      if [ -f "$state_file" ] && [ "$(cat "$state_file")" = "$checksum" ]; then
        echo "skip docker archive: $target_ref"
        continue
      fi

      echo "push docker archive: $source_ref -> $HARBOR_REGISTRY/$HARBOR_PROJECT/$target_ref"
      skopeo copy \
        --src-tls-verify=false \
        --dest-tls-verify="$HARBOR_TLS_VERIFY" \
        --dest-creds "$HARBOR_USERNAME:$HARBOR_PASSWORD" \
        "docker-archive:$file:$source_ref" \
        "docker://$HARBOR_REGISTRY/$HARBOR_PROJECT/$target_ref"
      printf '%s' "$checksum" > "$state_file"
    done <<EOF
$repo_tags
EOF
  done

  sleep "$IMPORT_INTERVAL_SECONDS"
done
