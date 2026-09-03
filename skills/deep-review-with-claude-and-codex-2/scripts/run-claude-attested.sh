#!/bin/bash
# run-claude-attested.sh - generation-bound Claude Code CLI review wrapper
#
# Usage:
#   run-claude-attested.sh \
#     --context <context_json> \
#     --project <project_dir> \
#     --prompt-template <prompt_template_file> \
#     --diff <fixed_diff_file> \
#     --snapshot <fixed_head_snapshot_dir> \
#     --run-id <unique_run_id> \
#     --target <pr:N|branch:name> \
#     --head-sha <sha> \
#     --diff-sha256 <sha256> \
#     --snapshot-metadata-sha256 <sha256> \
#     --result-contract <review|followup> \
#     [--resume-session-id <session_id>]
#
# A successful result contains INPUT_ATTESTATION: verified and has the
# generation-specific receipt removed from the review body.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PREPARER="$SCRIPT_DIR/prepare-claude-review-input.mjs"
VERIFIER="$SCRIPT_DIR/verify-claude-review-output.mjs"
CLAUDE_RUNNER="$SCRIPT_DIR/run-claude.sh"

CONTEXT_PATH=""
PROJECT_DIR=""
PROMPT_TEMPLATE=""
DIFF_FILE=""
SNAPSHOT_DIR=""
RUN_ID=""
TARGET=""
HEAD_SHA=""
DIFF_SHA256=""
SNAPSHOT_METADATA_SHA256=""
RESULT_CONTRACT=""
RESUME_SESSION_ID=""
WORK_DIR=""
CONTROL_FILE=""
TEMP_ROOT=""
INPUT_DIR=""

usage() {
  sed -n '4,18p' "$0" >&2
}

select_temp_root() {
  local candidate root_real
  for candidate in \
    "${CLAUDE_REVIEW_TEMP_ROOT:-}" \
    "${TMPDIR:-}" \
    /tmp \
    /c/tmp; do
    [ -n "$candidate" ] || continue
    root_real=$(cd "$candidate" 2>/dev/null && pwd -P) || continue
    if [ -d "$root_real" ] && [ -w "$root_real" ]; then
      printf '%s\n' "$root_real"
      return 0
    fi
  done
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context) CONTEXT_PATH="${2:-}"; shift 2 ;;
    --project) PROJECT_DIR="${2:-}"; shift 2 ;;
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
    --resume-session-id) RESUME_SESSION_ID="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

for required in \
  CONTEXT_PATH PROJECT_DIR PROMPT_TEMPLATE DIFF_FILE SNAPSHOT_DIR RUN_ID TARGET HEAD_SHA \
  DIFF_SHA256 SNAPSHOT_METADATA_SHA256 RESULT_CONTRACT; do
  value="${!required}"
  if [ -z "$value" ]; then
    echo "ERROR: missing required argument: $required" >&2
    usage
    exit 2
  fi
done
if [ ! -f "$CONTEXT_PATH" ] || [ -L "$CONTEXT_PATH" ]; then
  echo "ERROR: context must be a regular non-symlink file: $CONTEXT_PATH" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  exit 2
fi
CLAUDE_REVIEW_MODEL_FIXED=$(jq -er \
  '.reviewerConfig.claude.model | select(type == "string" and length > 0)' \
  "$CONTEXT_PATH") || {
  echo "ERROR: context Claude review model is missing or invalid" >&2
  exit 2
}
CLAUDE_REVIEW_EFFORT_FIXED=$(jq -er \
  '.reviewerConfig.claude.effort | select(type == "string" and length > 0)' \
  "$CONTEXT_PATH") || {
  echo "ERROR: context Claude review effort is missing or invalid" >&2
  exit 2
}

cleanup() {
  local cleanup_rc=0
  trap - EXIT INT TERM
  set +e
  if [ -n "$CONTROL_FILE" ] && [ -f "$CONTROL_FILE" ]; then
    node "$PREPARER" --cleanup-control "$CONTROL_FILE" >/dev/null 2>&1
    cleanup_rc=$?
  fi
  if [ -n "$WORK_DIR" ]; then
    case "$WORK_DIR" in
      "$TEMP_ROOT"/claude-review-run.*) rm -rf "$WORK_DIR" ;;
    esac
  fi
  return "$cleanup_rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! TEMP_ROOT=$(select_temp_root); then
  echo "ERROR: no writable Claude review temporary root is available" >&2
  exit 2
fi
export CLAUDE_REVIEW_TEMP_ROOT="$TEMP_ROOT"

if ! WORK_DIR=$(mktemp -d "$TEMP_ROOT/claude-review-run.XXXXXX"); then
  echo "ERROR: failed to create Claude review wrapper directory" >&2
  exit 2
fi
chmod 700 "$WORK_DIR"
CONTROL_FILE="$WORK_DIR/control.json"
RAW_OUTPUT="$WORK_DIR/raw-output.txt"
VERIFIED_OUTPUT="$WORK_DIR/verified-output.txt"
if ! INPUT_DIR=$(mktemp -d "$TEMP_ROOT/claude-review-input.XXXXXX"); then
  echo "ERROR: failed to create Claude review input directory" >&2
  exit 2
fi
chmod 700 "$INPUT_DIR"

if ! node "$PREPARER" \
  --temp-root "$TEMP_ROOT" \
  --input-dir "$INPUT_DIR" \
  --diff "$DIFF_FILE" \
  --snapshot "$SNAPSHOT_DIR" \
  --prompt-template "$PROMPT_TEMPLATE" \
  --run-id "$RUN_ID" \
  --target "$TARGET" \
  --head-sha "$HEAD_SHA" \
  --expected-diff-sha256 "$DIFF_SHA256" \
  --expected-snapshot-metadata-sha256 "$SNAPSHOT_METADATA_SHA256" \
  --result-contract "$RESULT_CONTRACT" \
  --control "$CONTROL_FILE" >/dev/null; then
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  exit 2
fi

CONTROL_INPUT_DIR=$(jq -r '.inputDir // empty' "$CONTROL_FILE")
OWNER_TOKEN=$(jq -r '.ownerToken // empty' "$CONTROL_FILE")
if [ -z "$CONTROL_INPUT_DIR" ] || [ -z "$OWNER_TOKEN" ]; then
  echo "ERROR: prepared Claude review control is incomplete" >&2
  exit 1
fi
INPUT_DIR_REAL=$(cd "$INPUT_DIR" 2>/dev/null && pwd -P) || {
  echo "ERROR: prepared Claude review input directory is unavailable" >&2
  exit 1
}
INPUT_DIR="$INPUT_DIR_REAL"
PROMPT_FILE="$INPUT_DIR/claude-prompt-attested.txt"
if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: prepared Claude review prompt is unavailable" >&2
  exit 1
fi

if [ -n "$RESUME_SESSION_ID" ]; then
  CLAUDE_REVIEW_MODEL="$CLAUDE_REVIEW_MODEL_FIXED" \
  CLAUDE_REVIEW_EFFORT="$CLAUDE_REVIEW_EFFORT_FIXED" \
  CLAUDE_REVIEW_TEMP_ROOT="$TEMP_ROOT" \
  CLAUDE_EXPECTED_INPUT_DIR="$INPUT_DIR" \
  CLAUDE_INPUT_OWNER_TOKEN="$OWNER_TOKEN" \
    bash "$CLAUDE_RUNNER" \
      "$PROJECT_DIR" "$PROMPT_FILE" "$RESUME_SESSION_ID" >"$RAW_OUTPUT"
  runner_rc=$?
else
  CLAUDE_REVIEW_MODEL="$CLAUDE_REVIEW_MODEL_FIXED" \
  CLAUDE_REVIEW_EFFORT="$CLAUDE_REVIEW_EFFORT_FIXED" \
  CLAUDE_REVIEW_TEMP_ROOT="$TEMP_ROOT" \
  CLAUDE_EXPECTED_INPUT_DIR="$INPUT_DIR" \
  CLAUDE_INPUT_OWNER_TOKEN="$OWNER_TOKEN" \
    bash "$CLAUDE_RUNNER" "$PROJECT_DIR" "$PROMPT_FILE" >"$RAW_OUTPUT"
  runner_rc=$?
fi

if [ "$runner_rc" -ne 0 ]; then
  cat "$RAW_OUTPUT"
  exit "$runner_rc"
fi

if ! node "$VERIFIER" \
  --control "$CONTROL_FILE" \
  --input "$RAW_OUTPUT" \
  --output "$VERIFIED_OUTPUT"; then
  sed -n '/^SESSION_ID: /p' "$RAW_OUTPUT" | sed -n '1p'
  printf 'STATUS: input_attestation_failed\n'
  exit 1
fi

cat "$VERIFIED_OUTPUT"
