#!/usr/bin/env bash
# Trusted fixed-path launcher for run-specific pair, wave, and Claude follow-up runners.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TRUSTED_SKILL_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
ORIGINAL_ARGS=("$@")
MODE=""
STDOUT_PATH=""
STDERR_PATH=""

usage() {
  cat >&2 <<'USAGE'
Usage:
  launch-run-reviewer.sh --context <context.json> --mode <pair|wave> -- <runner arguments>
  launch-run-reviewer.sh --context <context.json> --mode claude-followup \
    --stdout-path <claude.out> --stderr-path <claude.err> -- <runner arguments>
USAGE
}

if [ "${1:-}" != "--context" ] || [ -z "${2:-}" ] || \
  [ "${3:-}" != "--mode" ] || [ -z "${4:-}" ]; then
  usage
  exit 2
fi
MODE="$4"
shift 4

while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
  case "$1" in
    --stdout-path) STDOUT_PATH="${2:-}"; shift 2 ;;
    --stderr-path) STDERR_PATH="${2:-}"; shift 2 ;;
    *) echo "ERROR: unsupported launcher option: $1" >&2; usage; exit 2 ;;
  esac
done
if [ "${1:-}" != "--" ]; then
  usage
  exit 2
fi
shift
if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi
RUNNER_ARGS=("$@")

VERIFIED_CONTEXT=$(
  node "$SCRIPT_DIR/verify-run-reviewer-launch.mjs" "${ORIGINAL_ARGS[@]}"
)
SNAPSHOT_SKILL_DIR=$(printf '%s' "$VERIFIED_CONTEXT" | jq -er .skillDir)
TOOLING_DIGEST=$(printf '%s' "$VERIFIED_CONTEXT" | jq -er .toolingDigest)
RUNNER_PATH=$(printf '%s' "$VERIFIED_CONTEXT" | jq -er .runnerPath)
CLAUDE_REVIEW_MODEL=$(printf '%s' "$VERIFIED_CONTEXT" | \
  jq -er .reviewerConfig.claude.model)
CLAUDE_REVIEW_EFFORT=$(printf '%s' "$VERIFIED_CONTEXT" | \
  jq -er .reviewerConfig.claude.effort)
CODEX_REVIEW_MODEL=$(printf '%s' "$VERIFIED_CONTEXT" | \
  jq -er .reviewerConfig.codex.model)
CODEX_REVIEW_REASONING_EFFORT=$(printf '%s' "$VERIFIED_CONTEXT" | \
  jq -er .reviewerConfig.codex.reasoningEffort)

node "$SCRIPT_DIR/snapshot-tooling.mjs" --verify \
  --snapshot "$SNAPSHOT_SKILL_DIR" \
  --expected-digest "$TOOLING_DIGEST" \
  --source "$TRUSTED_SKILL_DIR" \
  --require-private

export CLAUDE_REVIEW_MODEL CLAUDE_REVIEW_EFFORT
export CODEX_REVIEW_MODEL CODEX_REVIEW_REASONING_EFFORT
case "$MODE" in
  pair|wave)
    exec bash "$RUNNER_PATH" "${RUNNER_ARGS[@]}"
    ;;
  claude-followup)
    set -C
    exec bash "$RUNNER_PATH" "${RUNNER_ARGS[@]}" \
      >"$STDOUT_PATH" 2>"$STDERR_PATH"
    ;;
  *)
    echo "ERROR: unsupported reviewer launch mode: $MODE" >&2
    exit 2
    ;;
esac
