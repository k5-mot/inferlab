#!/bin/sh
set -eu

IMPORT_INTERVAL_SECONDS="${CODE_MARKETPLACE_IMPORT_INTERVAL_SECONDS:-300}"
STATE_FILE="/extensions/.vsix-import.sha256"

mkdir -p /extensions

while true; do
    VSIX_COUNT="$(find /imports -maxdepth 1 -type f -name '*.vsix' | wc -l | tr -d ' ')"

    if [ "$VSIX_COUNT" = "0" ]; then
        echo "No VSIX files found in /imports"
        sleep "$IMPORT_INTERVAL_SECONDS"
        continue
    fi

    FINGERPRINT="$(find /imports -maxdepth 1 -type f -name '*.vsix' -exec sha256sum {} \; | sort | sha256sum | awk '{print $1}')"
    PREVIOUS_FINGERPRINT=""
    if [ -f "$STATE_FILE" ]; then
        PREVIOUS_FINGERPRINT="$(cat "$STATE_FILE")"
    fi

    if [ "$FINGERPRINT" != "$PREVIOUS_FINGERPRINT" ]; then
        echo "Import VSIX files into Code Marketplace storage"
        code-marketplace add /imports --extensions-dir /extensions
        printf '%s\n' "$FINGERPRINT" > "$STATE_FILE"
    else
        echo "Skip VSIX import because inputs are unchanged"
    fi

    sleep "$IMPORT_INTERVAL_SECONDS"
done
