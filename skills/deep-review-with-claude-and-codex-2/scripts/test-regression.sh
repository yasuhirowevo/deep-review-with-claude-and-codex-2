#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

bash "$SKILL_DIR/tests/test-reviewer-config.sh"
bash "$SKILL_DIR/tests/test-review-preflight.sh"
bash "$SKILL_DIR/tests/test-global-skill-contract.sh"
bash "$SKILL_DIR/tests/test-report-contract.sh"
bash "$SKILL_DIR/tests/test-pr-review-context.sh"
node "$SKILL_DIR/tests/test-review-finding-parser.mjs"
node "$SKILL_DIR/tests/test-adjudication-invariants.mjs"
bash "$SKILL_DIR/tests/test-final-findings.sh"
bash "$SKILL_DIR/tests/test-review-run-artifacts.sh"
bash "$SKILL_DIR/tests/test-review-pair.sh"
bash "$SKILL_DIR/tests/test-review-wave.sh"
bash "$SKILL_DIR/tests/test-claude-review-runner.sh"
bash "$SKILL_DIR/tests/test-claude-review-attestation.sh"
bash "$SKILL_DIR/tests/test-codex-runners.sh"
bash "$SKILL_DIR/tests/test-reviewer-launcher.sh"
