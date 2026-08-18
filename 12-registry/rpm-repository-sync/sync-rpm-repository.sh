#!/usr/bin/env bash
set -euo pipefail

# このscriptはRPM資材directoryを定期的にrepository metadataへ反映する。
REPOSITORY_SYNC_INTERVAL_SECONDS="30"

while true; do
  /usr/local/bin/publish-rpm-repository
  sleep "$REPOSITORY_SYNC_INTERVAL_SECONDS"
done
