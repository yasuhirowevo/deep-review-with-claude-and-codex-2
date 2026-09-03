#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RESOLVER="$(cd -P "$TEST_DIR/../scripts" && pwd -P)/resolve-reviewer-config.sh"
T=$(mktemp -d /tmp/deep-review-config.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM

pass=0
fail=0
ok() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
ng() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

echo "== C01: missing required config fails closed =="
if ! CLAUDE_REVIEW_MODEL='' CLAUDE_REVIEW_EFFORT='' \
  CODEX_REVIEW_MODEL='' CODEX_REVIEW_REASONING_EFFORT='' \
  DEEP_REVIEW_CONFIG_FILE='' HOME="$T/no-config" \
  bash "$RESOLVER" >/dev/null 2>"$T/unconfigured.err" &&
  rg -q 'CLAUDE_REVIEW_MODEL is not configured' "$T/unconfigured.err"; then
  ok "missing required reviewer config stops before resolution"
else
  ng "missing required reviewer config stops before resolution"
fi

echo "== C02: noninteractive prepare config preserves arbitrary values =="
config_file="$T/reviewer.env"
printf '%s\n' \
  '# arbitrary regression values' \
  'export CLAUDE_REVIEW_MODEL=claude-model-from-file' \
  'CLAUDE_REVIEW_EFFORT=claude-effort-from-file' \
  'export CODEX_REVIEW_MODEL=codex-model-from-file' \
  'CODEX_REVIEW_REASONING_EFFORT=codex-effort-from-file' > "$config_file"
file_json=$(CLAUDE_REVIEW_MODEL='' CLAUDE_REVIEW_EFFORT='' \
  CODEX_REVIEW_MODEL='' CODEX_REVIEW_REASONING_EFFORT='' \
  DEEP_REVIEW_CONFIG_FILE="$config_file" bash "$RESOLVER")
if printf '%s' "$file_json" | jq -e '
  .reviewerConfig == {
    claude:{model:"claude-model-from-file",effort:"claude-effort-from-file"},
    codex:{model:"codex-model-from-file",reasoningEffort:"codex-effort-from-file"}
  } and
  ([.reviewerConfigSources[][]] | all(. == "config-file"))
' >/dev/null; then
  ok "config file supplies arbitrary reviewer values without shell startup"
else
  ng "config file supplies arbitrary reviewer values without shell startup"
fi

echo "== C03: inherited environment overrides the config file =="
environment_json=$( \
  CLAUDE_REVIEW_MODEL=claude-model-from-environment \
  CLAUDE_REVIEW_EFFORT=claude-effort-from-environment \
  CODEX_REVIEW_MODEL=codex-model-from-environment \
  CODEX_REVIEW_REASONING_EFFORT=codex-effort-from-environment \
  DEEP_REVIEW_CONFIG_FILE="$config_file" bash "$RESOLVER"
)
if printf '%s' "$environment_json" | jq -e '
  .reviewerConfig == {
    claude:{model:"claude-model-from-environment",effort:"claude-effort-from-environment"},
    codex:{model:"codex-model-from-environment",reasoningEffort:"codex-effort-from-environment"}
  } and
  ([.reviewerConfigSources[][]] | all(. == "environment"))
' >/dev/null; then
  ok "inherited arbitrary values take precedence over file values"
else
  ng "inherited arbitrary values take precedence over file values"
fi

echo "== C04: invalid config fails closed without code execution =="
marker="$T/should-not-exist"
printf '%s\n' \
  'CLAUDE_REVIEW_MODEL=valid-before-invalid-line' \
  "touch $marker" > "$T/code.env"
if ! DEEP_REVIEW_CONFIG_FILE="$T/code.env" bash "$RESOLVER" \
  >/dev/null 2>"$T/code.err" && [ ! -e "$marker" ] &&
  rg -q 'expected KEY=VALUE' "$T/code.err"; then
  ok "config is parsed as data and executable text is rejected"
else
  ng "config is parsed as data and executable text is rejected"
fi
printf '%s\n' \
  'CLAUDE_REVIEW_MODEL=first' \
  'CLAUDE_REVIEW_MODEL=second' > "$T/duplicate.env"
if ! DEEP_REVIEW_CONFIG_FILE="$T/duplicate.env" bash "$RESOLVER" \
  >/dev/null 2>"$T/duplicate.err" &&
  rg -q 'duplicate key: CLAUDE_REVIEW_MODEL' "$T/duplicate.err"; then
  ok "duplicate reviewer keys fail closed"
else
  ng "duplicate reviewer keys fail closed"
fi
if ! DEEP_REVIEW_CONFIG_FILE="$T/missing.env" bash "$RESOLVER" \
  >/dev/null 2>"$T/missing.err" &&
  rg -q 'explicit config file does not exist' "$T/missing.err"; then
  ok "missing explicit config path fails closed"
else
  ng "missing explicit config path fails closed"
fi
printf 'CLAUDE_REVIEW_MODEL=\n' > "$T/empty.env"
if ! DEEP_REVIEW_CONFIG_FILE="$T/empty.env" bash "$RESOLVER" \
  >/dev/null 2>"$T/empty.err" &&
  rg -q 'CLAUDE_REVIEW_MODEL must be nonempty' "$T/empty.err"; then
  ok "empty configured reviewer values fail closed"
else
  ng "empty configured reviewer values fail closed"
fi

echo ""
printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
exit "$fail"
