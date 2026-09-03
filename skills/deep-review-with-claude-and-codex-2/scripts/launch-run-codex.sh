#!/usr/bin/env bash
# Trusted fixed-path launcher for a run-specific Codex reviewer snapshot.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TRUSTED_SKILL_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
CONTEXT_PATH=""

usage() {
  echo "Usage: $0 --context <context.json> <run-codex.sh arguments>" >&2
}

if [ "${1:-}" != "--context" ] || [ -z "${2:-}" ]; then
  usage
  exit 2
fi
CONTEXT_PATH="$2"
shift 2
if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

VERIFIED_CONTEXT=$(
  node "$SCRIPT_DIR/verify-run-codex-launch.mjs" \
    --context "$CONTEXT_PATH" -- "$@"
)
SNAPSHOT_SKILL_DIR=$(printf '%s' "$VERIFIED_CONTEXT" | jq -er .skillDir)
TOOLING_DIGEST=$(printf '%s' "$VERIFIED_CONTEXT" | jq -er .toolingDigest)
RUNNER_PATH=$(printf '%s' "$VERIFIED_CONTEXT" | jq -er .runnerPath)
CODEX_REVIEW_MODEL=$(printf '%s' "$VERIFIED_CONTEXT" | \
  jq -er .reviewerConfig.codex.model)
CODEX_REVIEW_REASONING_EFFORT=$(printf '%s' "$VERIFIED_CONTEXT" | \
  jq -er .reviewerConfig.codex.reasoningEffort)

node "$SCRIPT_DIR/snapshot-tooling.mjs" --verify \
  --snapshot "$SNAPSHOT_SKILL_DIR" \
  --expected-digest "$TOOLING_DIGEST" \
  --source "$TRUSTED_SKILL_DIR" \
  --require-private

export CODEX_REVIEW_MODEL CODEX_REVIEW_REASONING_EFFORT
exec bash "$RUNNER_PATH" "$@"
