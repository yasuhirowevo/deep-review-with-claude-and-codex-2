#!/usr/bin/env bash

set -uo pipefail
unset CLAUDE_REVIEW_ENABLED CODEX_REVIEW_ENABLED

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
    claude:{enabled:true,model:"claude-model-from-file",effort:"claude-effort-from-file"},
    codex:{enabled:true,model:"codex-model-from-file",reasoningEffort:"codex-effort-from-file"}
  } and
  ([.reviewerConfigSources[] | .model, (.effort // .reasoningEffort)] | all(. == "config-file")) and
  ([.reviewerConfigSources[].enabled] | all(. == "default"))
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
    claude:{enabled:true,model:"claude-model-from-environment",effort:"claude-effort-from-environment"},
    codex:{enabled:true,model:"codex-model-from-environment",reasoningEffort:"codex-effort-from-environment"}
  } and
  ([.reviewerConfigSources[] | .model, (.effort // .reasoningEffort)] | all(. == "environment")) and
  ([.reviewerConfigSources[].enabled] | all(. == "default"))
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

echo "== C05: disabled reviewers may remain unconfigured =="
for enabled_reviewer in claude codex; do
  if [ "$enabled_reviewer" = claude ]; then
    printf '%s\n' 'CLAUDE_REVIEW_MODEL=single-claude' 'CLAUDE_REVIEW_EFFORT=high' \
      'CODEX_REVIEW_ENABLED=false' > "$T/single.env"
  else
    printf '%s\n' 'CODEX_REVIEW_MODEL=single-codex' 'CODEX_REVIEW_REASONING_EFFORT=xhigh' \
      'CLAUDE_REVIEW_ENABLED=false' > "$T/single.env"
  fi
  single_json=$(CLAUDE_REVIEW_MODEL='' CLAUDE_REVIEW_EFFORT='' \
    CODEX_REVIEW_MODEL='' CODEX_REVIEW_REASONING_EFFORT='' \
    DEEP_REVIEW_CONFIG_FILE="$T/single.env" bash "$RESOLVER")
  printf '%s\n' "$single_json" > "$T/single.json"
  if printf '%s' "$single_json" | jq -e --arg reviewer "$enabled_reviewer" '
    (if $reviewer == "claude" then "codex" else "claude" end) as $disabled |
    .reviewerConfig[$reviewer].enabled == true and
    .reviewerConfigSources[$reviewer].enabled == "default" and
    .reviewerConfig[$disabled].enabled == false and
    .reviewerConfig[$disabled].model == null and
    .reviewerConfigSources[$disabled].enabled == "config-file" and
    .reviewerConfigSources[$disabled].model == null and
    (if $disabled == "claude" then
      .reviewerConfig.claude.effort == null and .reviewerConfigSources.claude.effort == null
    else
      .reviewerConfig.codex.reasoningEffort == null and .reviewerConfigSources.codex.reasoningEffort == null
    end)
  ' >/dev/null && node "$TEST_DIR/../scripts/reviewer-selection.mjs" \
    --context "$T/single.json" --validate-config > "$T/enabled.json" &&
    jq -e --arg reviewer "$enabled_reviewer" '. == [$reviewer]' "$T/enabled.json" >/dev/null; then
    ok "$enabled_reviewer-only config retains disabled null values and correct sources"
  else
    ng "$enabled_reviewer-only config retains disabled null values and correct sources"
  fi
done

echo "== C06: selection overrides and configured disabled values are retained =="
printf '%s\n' 'CLAUDE_REVIEW_ENABLED=false' 'CODEX_REVIEW_ENABLED=true' \
  'CLAUDE_REVIEW_MODEL=optional-claude-model' 'CODEX_REVIEW_MODEL=file-codex' \
  'CODEX_REVIEW_REASONING_EFFORT=xhigh' > "$T/selection.env"
override_json=$(CLAUDE_REVIEW_ENABLED=true CODEX_REVIEW_ENABLED=false \
  CLAUDE_REVIEW_MODEL='' CLAUDE_REVIEW_EFFORT=high \
  CODEX_REVIEW_MODEL='' CODEX_REVIEW_REASONING_EFFORT='' \
  DEEP_REVIEW_CONFIG_FILE="$T/selection.env" bash "$RESOLVER")
if printf '%s' "$override_json" | jq -e '
  .reviewerConfig.claude == {enabled:true,model:"optional-claude-model",effort:"high"} and
  .reviewerConfig.codex == {enabled:false,model:"file-codex",reasoningEffort:"xhigh"} and
  .reviewerConfigSources.claude.enabled == "environment" and
  .reviewerConfigSources.codex.enabled == "environment" and
  .reviewerConfigSources.codex.model == "config-file"
' >/dev/null; then ok "environment selects reviewers independently of retained optional file values";
else ng "environment selects reviewers independently of retained optional file values"; fi

empty_environment_json=$(CLAUDE_REVIEW_ENABLED='' CODEX_REVIEW_ENABLED='' \
  CLAUDE_REVIEW_MODEL='' CLAUDE_REVIEW_EFFORT='' \
  CODEX_REVIEW_MODEL='' CODEX_REVIEW_REASONING_EFFORT='' \
  DEEP_REVIEW_CONFIG_FILE="$T/selection.env" bash "$RESOLVER")
if printf '%s' "$empty_environment_json" | jq -e '
  .reviewerConfig.claude.enabled == false and .reviewerConfig.codex.enabled == true and
  ([.reviewerConfigSources[].enabled] | all(. == "config-file"))
' >/dev/null; then ok "empty environment enabled values use the configured file selection";
else ng "empty environment enabled values use the configured file selection"; fi

empty_default_json=$(CLAUDE_REVIEW_ENABLED='' CODEX_REVIEW_ENABLED='' \
  CLAUDE_REVIEW_MODEL='' CLAUDE_REVIEW_EFFORT='' \
  CODEX_REVIEW_MODEL='' CODEX_REVIEW_REASONING_EFFORT='' \
  DEEP_REVIEW_CONFIG_FILE="$config_file" bash "$RESOLVER")
if printf '%s' "$empty_default_json" | jq -e '
  ([.reviewerConfig[].enabled] | all(. == true)) and
  ([.reviewerConfigSources[].enabled] | all(. == "default"))
' >/dev/null; then ok "empty environment enabled values default to true when the file omits flags";
else ng "empty environment enabled values default to true when the file omits flags"; fi

if ! CLAUDE_REVIEW_ENABLED=false CODEX_REVIEW_ENABLED=false \
  DEEP_REVIEW_CONFIG_FILE="$config_file" bash "$RESOLVER" >"$T/both-disabled.json" 2>"$T/both-disabled.err" &&
  rg -q 'at least one reviewer must be enabled' "$T/both-disabled.err"; then
  ok "both reviewers disabled fails closed"
else ng "both reviewers disabled fails closed"; fi

for invalid in False yes 0 1 ' true' 'false '; do
  if ! CLAUDE_REVIEW_ENABLED="$invalid" DEEP_REVIEW_CONFIG_FILE="$config_file" \
    bash "$RESOLVER" >/dev/null 2>"$T/invalid-enabled.err" &&
    rg -q 'CLAUDE_REVIEW_ENABLED must' "$T/invalid-enabled.err"; then
    ok "invalid environment enabled value is rejected: [$invalid]"
  else ng "invalid environment enabled value is rejected: [$invalid]"; fi
done
printf '%s\n' 'CODEX_REVIEW_ENABLED=false' 'CODEX_REVIEW_ENABLED=true' > "$T/duplicate-enabled.env"
if ! DEEP_REVIEW_CONFIG_FILE="$T/duplicate-enabled.env" bash "$RESOLVER" \
  >/dev/null 2>"$T/duplicate-enabled.err" && rg -q 'duplicate key: CODEX_REVIEW_ENABLED' "$T/duplicate-enabled.err"; then
  ok "duplicate enabled keys fail closed"
else ng "duplicate enabled keys fail closed"; fi
printf '%s\n' 'CODEX_REVIEW_ENABLED=False' > "$T/invalid-enabled.env"
if ! DEEP_REVIEW_CONFIG_FILE="$T/invalid-enabled.env" bash "$RESOLVER" \
  >/dev/null 2>"$T/invalid-enabled-file.err" && rg -q 'CODEX_REVIEW_ENABLED must be true or false' "$T/invalid-enabled-file.err"; then
  ok "invalid file enabled value fails closed"
else ng "invalid file enabled value fails closed"; fi
printf '%s\n' 'CODEX_REVIEW_ENABLED=' > "$T/empty-enabled.env"
if ! CODEX_REVIEW_ENABLED=true DEEP_REVIEW_CONFIG_FILE="$T/empty-enabled.env" bash "$RESOLVER" \
  >/dev/null 2>"$T/empty-enabled-file.err" && rg -q 'CODEX_REVIEW_ENABLED must be nonempty' "$T/empty-enabled-file.err"; then
  ok "empty file enabled value fails closed even with an environment override"
else ng "empty file enabled value fails closed even with an environment override"; fi

if node --input-type=module - "$TEST_DIR/../scripts/reviewer-selection.mjs" <<'NODE'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const {getEnabledReviewers, validateReviewerConfiguration} = await import(pathToFileURL(process.argv[2]));
assert.deepEqual(getEnabledReviewers({}), ["claude", "codex"]);
assert.deepEqual(getEnabledReviewers({reviewerConfig:{claude:{enabled:false}}}), ["codex"]);
for (const value of [null, "true", "false", 0, 1]) {
  assert.throws(() => getEnabledReviewers({reviewerConfig:{claude:{enabled:value}}}), /must be a boolean/);
}
assert.throws(() => getEnabledReviewers({reviewerConfig:{claude:{enabled:false},codex:{enabled:false}}}), /at least one/);
const fixture = {
  reviewerConfig:{claude:{enabled:true,model:"c",effort:"high"},codex:{enabled:false,model:null,reasoningEffort:null}},
  reviewerConfigSources:{claude:{enabled:"default",model:"environment",effort:"environment"},codex:{enabled:"environment",model:null,reasoningEffort:null}},
};
validateReviewerConfiguration(fixture);
fixture.reviewerConfigSources.codex.model = "environment";
assert.throws(() => validateReviewerConfiguration(fixture), /codex.model/);
fixture.reviewerConfigSources.codex.model = null;
fixture.reviewerConfigSources.codex.enabled = "default";
assert.throws(() => validateReviewerConfiguration(fixture), /default selection/);
NODE
then ok "context selection validates booleans, preserves legacy default, and binds optional sources";
else ng "context selection validates booleans, preserves legacy default, and binds optional sources"; fi

echo ""
printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
exit "$fail"
