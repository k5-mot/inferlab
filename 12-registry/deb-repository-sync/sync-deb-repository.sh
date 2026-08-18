#!/usr/bin/env bash
set -euo pipefail

# このscriptはdeb資材directoryを定期的にAPT metadataへ反映する。
REPOSITORY_SYNC_INTERVAL_SECONDS="30"

while true; do
  /usr/local/bin/publish-deb-repository
  sleep "$REPOSITORY_SYNC_INTERVAL_SECONDS"
done
