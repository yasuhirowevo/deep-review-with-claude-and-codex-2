#!/usr/bin/env bash

set -euo pipefail

CONTEXT_PATH="${1:-}"
if [ -z "$CONTEXT_PATH" ] || [ ! -f "$CONTEXT_PATH" ]; then
  echo "Usage: $0 <context.json>" >&2
  exit 2
fi

SKILL_DIR=$(jq -er .skillDir "$CONTEXT_PATH")
SNAPSHOT_DIR=$(jq -er .reviewSnapshotDir "$CONTEXT_PATH")
TEMP_ROOT=$(jq -er .reviewTempRoot "$CONTEXT_PATH")
RUN_ROOT=$(jq -er .reviewRunRoot "$CONTEXT_PATH")

if [ -n "$SNAPSHOT_DIR" ]; then
  bash "$SKILL_DIR/scripts/cleanup-review-snapshot.sh" \
    --temp-root "$TEMP_ROOT" "$SNAPSHOT_DIR"
fi
case "$RUN_ROOT" in
  "$TEMP_ROOT"/deep-review.*)
    chmod -R u+w "$RUN_ROOT" 2>/dev/null || true
    rm -rf -- "$RUN_ROOT"
    ;;
  *)
    echo "ERROR: refusing unmanaged review run root: $RUN_ROOT" >&2
    exit 1
    ;;
esac
