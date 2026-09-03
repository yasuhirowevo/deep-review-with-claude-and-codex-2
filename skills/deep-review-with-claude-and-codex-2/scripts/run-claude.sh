#!/bin/bash
# run-claude.sh - Claude Code CLI leaf-reviewer wrapper
#
# Usage:
#   New session: run-claude.sh <project_dir> <prompt_file>
#   Resume:      run-claude.sh <project_dir> <prompt_file> <session_id>
#
# Output:
#   SESSION_ID: <uuid>
#   COST_USD: <usd>
#   DENIALS: <n>  # only when permission denials occurred
#   ---
#   <final answer text>
#
# This is the low-level read-only launcher. Canonical deep-review calls use
# run-claude-attested.sh, which prepares a generation-bound input bundle and
# validates the receipt before accepting this launcher's output.

set -euo pipefail

# Resolve the physical directory so compatibility symlinks still reach the
# bundled shared core.
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CORE_SCRIPT="$SCRIPT_DIR/run-claude-core.sh"

export CLAUDE_TIMEOUT_MAX=1500
export CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-900}"
export CLAUDE_OUTER_TIMEOUT="${CLAUDE_OUTER_TIMEOUT:-1050}"

if [ -z "${CLAUDE_REVIEW_MODEL:-}" ]; then
  echo "ERROR: CLAUDE_REVIEW_MODEL is not configured" >&2
  exit 2
fi
if [ -z "${CLAUDE_REVIEW_EFFORT:-}" ]; then
  echo "ERROR: CLAUDE_REVIEW_EFFORT is not configured" >&2
  exit 2
fi

export CLAUDE_MODEL="$CLAUDE_REVIEW_MODEL"
export CLAUDE_EFFORT="$CLAUDE_REVIEW_EFFORT"

exec bash "$CORE_SCRIPT" read-only "$@"
