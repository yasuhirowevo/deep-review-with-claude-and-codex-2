#!/bin/bash
# Create one isolated temporary and persistent artifact namespace for a review.
# shellcheck disable=SC2016

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TOOLING_ROOT=""
TARGET=""

usage() {
  echo "Usage: $0 --tooling-root <path> --target <safe-target-slug>" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tooling-root) TOOLING_ROOT="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$TOOLING_ROOT" ] || [ -z "$TARGET" ]; then
  usage
  exit 2
fi
case "$TARGET" in
  .|..)
    echo "ERROR: target cannot be . or .." >&2
    exit 2
    ;;
  *[!A-Za-z0-9._-]*)
    echo "ERROR: target contains unsupported characters" >&2
    exit 2
    ;;
esac
if [ "${#TARGET}" -gt 180 ]; then
  echo "ERROR: target is too long" >&2
  exit 2
fi

TOOLING_ROOT=$(cd "$TOOLING_ROOT" 2>/dev/null && pwd -P) || {
  echo "ERROR: tooling root is unavailable" >&2
  exit 2
}

REVIEW_TEMP_ROOT=""
for candidate in \
  "${DEEP_REVIEW_TEMP_ROOT:-}" \
  "${TMPDIR:-}" \
  /tmp \
  /c/tmp; do
  [ -n "$candidate" ] || continue
  candidate_real=$(cd "$candidate" 2>/dev/null && pwd -P) || continue
  if [ -d "$candidate_real" ] && [ -w "$candidate_real" ]; then
    REVIEW_TEMP_ROOT="$candidate_real"
    break
  fi
done
if [ -z "$REVIEW_TEMP_ROOT" ]; then
  echo "ERROR: no writable review temporary root is available" >&2
  exit 1
fi

REVIEW_RUN_ID=$(node -e 'process.stdout.write(require("node:crypto").randomUUID())')
REVIEW_RUN_ROOT=""
REVIEW_ARTIFACT_DIR=""
cleanup_on_error() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -n "$REVIEW_RUN_ROOT" ]; then
      case "$REVIEW_RUN_ROOT" in
        "$REVIEW_TEMP_ROOT"/deep-review.*) rm -rf -- "$REVIEW_RUN_ROOT" ;;
      esac
    fi
    if [ -n "$REVIEW_ARTIFACT_DIR" ] && [ -d "$REVIEW_ARTIFACT_DIR" ]; then
      rmdir "$REVIEW_ARTIFACT_DIR/phase4/waves" \
        "$REVIEW_ARTIFACT_DIR/phase5" "$REVIEW_ARTIFACT_DIR/phase4" \
        "$REVIEW_ARTIFACT_DIR" 2>/dev/null || true
    fi
  fi
  return "$rc"
}
trap cleanup_on_error EXIT

REVIEW_RUN_ROOT=$(
  mktemp -d "$REVIEW_TEMP_ROOT/deep-review.${REVIEW_RUN_ID}.XXXXXX"
)
chmod 700 "$REVIEW_RUN_ROOT"

ensure_plain_directory() {
  local directory="$1"
  # mkdir is the atomic winner for a previously absent directory. If another
  # review created the same shared parent first, accept only the resulting
  # plain directory; symlinks and non-directories remain fail-closed.
  if mkdir "$directory" 2>/dev/null; then
    return 0
  fi
  if [ -L "$directory" ]; then
    echo "ERROR: refusing symlinked review artifact directory: $directory" >&2
    return 1
  fi
  if [ -d "$directory" ] && [ ! -L "$directory" ]; then
    return 0
  fi
  if [ -e "$directory" ]; then
    echo "ERROR: review artifact path is not a directory: $directory" >&2
  else
    echo "ERROR: failed to create review artifact directory: $directory" >&2
  fi
  return 1
}

ARTIFACT_ROOT="$TOOLING_ROOT/_tmp"
ensure_plain_directory "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$ARTIFACT_ROOT/reviews"
ensure_plain_directory "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$ARTIFACT_ROOT/runs"
ensure_plain_directory "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$ARTIFACT_ROOT/$TARGET"
ensure_plain_directory "$ARTIFACT_ROOT"
REVIEW_ARTIFACT_DIR="$ARTIFACT_ROOT/$REVIEW_RUN_ID"
ensure_plain_directory "$REVIEW_ARTIFACT_DIR"
ensure_plain_directory "$REVIEW_ARTIFACT_DIR/phase4"
ensure_plain_directory "$REVIEW_ARTIFACT_DIR/phase4/waves"
ensure_plain_directory "$REVIEW_ARTIFACT_DIR/phase5"
mkdir "$REVIEW_RUN_ROOT/codex-prompts"
chmod 700 "$REVIEW_ARTIFACT_DIR" "$REVIEW_ARTIFACT_DIR/phase4" \
  "$REVIEW_ARTIFACT_DIR/phase4/waves" \
  "$REVIEW_ARTIFACT_DIR/phase5" \
  "$REVIEW_RUN_ROOT/codex-prompts" 2>/dev/null || true

node "$SCRIPT_DIR/format-review-context.mjs" \
  "$REVIEW_RUN_ID" "$REVIEW_TEMP_ROOT" "$REVIEW_RUN_ROOT" \
  "$REVIEW_ARTIFACT_DIR"
