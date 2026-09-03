#!/usr/bin/env bash
# Fix the canonical decision for a running or completed speculative wave.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONTEXT_PATH=""
WAVE_STATUS_PATH=""
ACTION=""
WAVE_CONTROL_WAIT_SECONDS="${WAVE_CONTROL_WAIT_SECONDS:-1200}"
WAVE_CONTROL_STARTED_AT=$SECONDS
ABORTED_INCOMPLETE_EXIT=30

usage() {
  cat >&2 <<'USAGE'
Usage: control-review-wave.sh \
  --context <context.json> --wave-status <status.json> \
  --action <promote|converge|prior-failure>
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context) CONTEXT_PATH="${2:-}"; shift 2 ;;
    --wave-status) WAVE_STATUS_PATH="${2:-}"; shift 2 ;;
    --action) ACTION="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$CONTEXT_PATH" ] || [ -z "$WAVE_STATUS_PATH" ] || [ -z "$ACTION" ]; then
  usage
  exit 2
fi
case "$ACTION" in
  promote|converge|prior-failure) ;;
  *) echo "ERROR: invalid wave action: $ACTION" >&2; exit 2 ;;
esac
if ! [[ "$WAVE_CONTROL_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  [ "$WAVE_CONTROL_WAIT_SECONDS" -gt 1200 ]; then
  echo "ERROR: WAVE_CONTROL_WAIT_SECONDS must be an integer from 1 to 1200" >&2
  exit 2
fi
for input in "$CONTEXT_PATH" "$WAVE_STATUS_PATH"; do
  if [ ! -f "$input" ] || [ -L "$input" ]; then
    echo "ERROR: wave control input must be a regular non-symlink file: $input" >&2
    exit 2
  fi
done

SKILL_DIR=$(jq -er .skillDir "$CONTEXT_PATH")
SKILL_DIR_REAL=$(cd -P "$SKILL_DIR" 2>/dev/null && pwd -P) || {
  echo "ERROR: run-specific skill directory is unavailable" >&2
  exit 2
}
if [ "$SCRIPT_DIR" != "$SKILL_DIR_REAL/scripts" ]; then
  echo "ERROR: wave controller must execute from the context's tooling snapshot" >&2
  exit 1
fi
STATE_TOOL="$SCRIPT_DIR/review-wave-state.mjs"

node "$STATE_TOOL" decide \
  --context "$CONTEXT_PATH" \
  --status "$WAVE_STATUS_PATH" \
  --action "$ACTION" >/dev/null

CONTROL_STATE=$(node "$STATE_TOOL" control-state \
  --context "$CONTEXT_PATH" \
  --status "$WAVE_STATUS_PATH")

while [ "$(printf '%s' "$CONTROL_STATE" | jq -r .terminal)" != "true" ]; do
  if [ "$(printf '%s' "$CONTROL_STATE" | jq -r .pairFinished)" = "true" ] ||
    [ "$(printf '%s' "$CONTROL_STATE" | jq -r .finishedAt)" != "null" ]; then
    node "$STATE_TOOL" decide \
      --context "$CONTEXT_PATH" \
      --status "$WAVE_STATUS_PATH" \
      --action "$ACTION" >/dev/null
    CONTROL_STATE=$(node "$STATE_TOOL" control-state \
      --context "$CONTEXT_PATH" \
      --status "$WAVE_STATUS_PATH")
    if [ "$(printf '%s' "$CONTROL_STATE" | jq -r .terminal)" = "true" ]; then
      break
    fi
  fi
  if [ "$((SECONDS - WAVE_CONTROL_STARTED_AT))" -ge \
    "$WAVE_CONTROL_WAIT_SECONDS" ]; then
    echo "ERROR: speculative wave did not reach a reconcilable state" >&2
    exit 1
  fi
  sleep 1
  CONTROL_STATE=$(node "$STATE_TOOL" control-state \
    --context "$CONTEXT_PATH" \
    --status "$WAVE_STATUS_PATH")
done

printf 'WAVE_STATUS_PATH: %s\n' "$WAVE_STATUS_PATH"
printf 'WAVE_DECISION: %s\n' "$ACTION"
if [ "$(printf '%s' "$CONTROL_STATE" | jq -r .state)" = \
  "aborted-incomplete" ]; then
  echo "ERROR: speculative wave ended without a pair status; start a new review run" >&2
  exit "$ABORTED_INCOMPLETE_EXIT"
fi
