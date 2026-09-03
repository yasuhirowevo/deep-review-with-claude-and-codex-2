#!/bin/bash
# run-codex.sh - Codex CLI leaf-reviewer wrapper for the Claude+Codex deep review
#
# Fixed policy:
#   - sandbox: read-only
#   - model and reasoning: required from the prepared review context
#   - result: foreground stdout
#
# Usage:
#   run-codex.sh \
#     --project <project_dir> --temp-root <path> \
#     --prompt-template <path> --diff <path> --snapshot <path> \
#     --run-id <id> --target <pr:N|branch:name> --head-sha <sha> \
#     --diff-sha256 <sha256> --snapshot-metadata-sha256 <sha256> \
#     --result-contract <review|followup> [--thread-id <id>]
#
# Output:
#   Success (exit 0):
#   THREAD_ID: <thread_id>
#   RUN_ID: <run_id>
#   INPUT_ATTESTATION: verified
#   TARGET: <target>
#   HEAD_SHA: <sha>
#   DIFF_SHA256: <sha256>
#   SNAPSHOT_METADATA_SHA256: <sha256>
#   ---
#   <agent message text>
#
#   Timeout (exit 124):
#   THREAD_ID: <thread_id>  # when Codex emitted or supplied one
#   STATUS: timed_out
#
# Both Codex collaboration engines (legacy and v2) are disabled by the shared
# core because this process is already the leaf reviewer for the parent flow.
# shellcheck disable=SC2329

set -euo pipefail

# Resolve the physical directory so compatibility symlinks still reach the
# bundled shared core.
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_SCRIPT="$SCRIPT_DIR/run-codex-core.sh"
PREPARER="$SCRIPT_DIR/prepare-codex-review-input.mjs"
VERIFIER="$SCRIPT_DIR/verify-codex-review-output.mjs"

if [ -z "${CODEX_REVIEW_MODEL:-}" ]; then
  echo "ERROR: CODEX_REVIEW_MODEL is not configured" >&2
  exit 2
fi
if [ -z "${CODEX_REVIEW_REASONING_EFFORT:-}" ]; then
  echo "ERROR: CODEX_REVIEW_REASONING_EFFORT is not configured" >&2
  exit 2
fi

export CODEX_MODEL="$CODEX_REVIEW_MODEL"
export CODEX_REASONING_EFFORT="$CODEX_REVIEW_REASONING_EFFORT"
export CODEX_TIMEOUT_MAX=1500
# 900s + the default 30s TERM-to-KILL grace and output verification stay below
# the workflow's 1050s outer execution timeout.
export CODEX_TIMEOUT="${CODEX_TIMEOUT:-900}"

PROJECT_DIR=""
TEMP_ROOT=""
PROMPT_TEMPLATE=""
DIFF_FILE=""
SNAPSHOT_DIR=""
RUN_ID=""
TARGET=""
HEAD_SHA=""
DIFF_SHA256=""
SNAPSHOT_METADATA_SHA256=""
RESULT_CONTRACT=""
THREAD_ID=""

usage() {
  sed -n '5,17p' "$0" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="${2:-}"; shift 2 ;;
    --temp-root) TEMP_ROOT="${2:-}"; shift 2 ;;
    --prompt-template) PROMPT_TEMPLATE="${2:-}"; shift 2 ;;
    --diff) DIFF_FILE="${2:-}"; shift 2 ;;
    --snapshot) SNAPSHOT_DIR="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --head-sha) HEAD_SHA="${2:-}"; shift 2 ;;
    --diff-sha256) DIFF_SHA256="${2:-}"; shift 2 ;;
    --snapshot-metadata-sha256)
      SNAPSHOT_METADATA_SHA256="${2:-}"
      shift 2
      ;;
    --result-contract) RESULT_CONTRACT="${2:-}"; shift 2 ;;
    --thread-id) THREAD_ID="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

for required in \
  "$PROJECT_DIR" "$TEMP_ROOT" "$PROMPT_TEMPLATE" "$DIFF_FILE" \
  "$SNAPSHOT_DIR" "$RUN_ID" "$TARGET" "$HEAD_SHA" "$DIFF_SHA256" \
  "$SNAPSHOT_METADATA_SHA256" "$RESULT_CONTRACT"; do
  if [ -z "$required" ]; then
    echo "ERROR: all required review input arguments must be nonempty" >&2
    usage
    exit 2
  fi
done

TEMP_ROOT=$(cd "$TEMP_ROOT" 2>/dev/null && pwd -P) || {
  echo "ERROR: Codex review temporary root is unavailable" >&2
  exit 2
}
if [ ! -w "$TEMP_ROOT" ]; then
  echo "ERROR: Codex review temporary root is not writable" >&2
  exit 2
fi

CODEX_INPUT_DIR=$(
  mktemp -d "$TEMP_ROOT/deep-review-codex-review-input.XXXXXX"
)
chmod 700 "$CODEX_INPUT_DIR"
ATTESTED_PROMPT="$CODEX_INPUT_DIR/prompt.txt"
CODEX_CONTROL="$CODEX_INPUT_DIR/control.json"

cleanup_codex_input() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [ -n "${CODEX_INPUT_DIR:-}" ]; then
    case "$CODEX_INPUT_DIR" in
      "$TEMP_ROOT"/deep-review-codex-review-input.*)
        if [ -d "$CODEX_INPUT_DIR" ] && [ ! -L "$CODEX_INPUT_DIR" ]; then
          chmod -R u+w "$CODEX_INPUT_DIR" 2>/dev/null || true
          rm -rf -- "$CODEX_INPUT_DIR"
        fi
        ;;
    esac
  fi
  return "$rc"
}
trap cleanup_codex_input EXIT INT TERM HUP

node "$PREPARER" \
  --diff "$DIFF_FILE" \
  --snapshot "$SNAPSHOT_DIR" \
  --prompt-template "$PROMPT_TEMPLATE" \
  --run-id "$RUN_ID" \
  --target "$TARGET" \
  --head-sha "$HEAD_SHA" \
  --expected-diff-sha256 "$DIFF_SHA256" \
  --expected-snapshot-metadata-sha256 "$SNAPSHOT_METADATA_SHA256" \
  --result-contract "$RESULT_CONTRACT" \
  --prompt-output "$ATTESTED_PROMPT" \
  --control-output "$CODEX_CONTROL"

export CODEX_REVIEW_CONTROL_FILE="$CODEX_CONTROL"
export CODEX_REVIEW_OUTPUT_VERIFIER="$VERIFIER"

CORE_ARGS=(
  read-only
  stdout
  disable-multi-agent
  "$PROJECT_DIR"
  "$ATTESTED_PROMPT"
)
if [ -n "$THREAD_ID" ]; then
  CORE_ARGS+=("$THREAD_ID")
fi

set +e
bash "$CORE_SCRIPT" "${CORE_ARGS[@]}"
rc=$?
set -e
exit "$rc"
