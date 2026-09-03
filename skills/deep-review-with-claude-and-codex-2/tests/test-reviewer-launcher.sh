#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd -P "$TEST_DIR/.." && pwd -P)"
SCRIPTS="$SKILL_DIR/scripts"
T=$(mktemp -d /tmp/deep-review-reviewer-launcher.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM

pass=0
fail=0
ok() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
ng() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }
expect_success() {
  local label="$1"
  shift
  if "$@" >"$T/case.out" 2>"$T/case.err"; then ok "$label"; else ng "$label"; fi
}
expect_failure() {
  local label="$1"
  shift
  if "$@" >"$T/case.out" 2>"$T/case.err"; then ng "$label"; else ok "$label"; fi
}

echo "== L01: prepare one authentic fixed review namespace =="
mkdir -p "$T/repo" "$T/temp"
git -C "$T/repo" init -q
git -C "$T/repo" config user.email test@example.com
git -C "$T/repo" config user.name Test
printf 'export const value = 1;\n' > "$T/repo/value.ts"
git -C "$T/repo" add value.ts
git -C "$T/repo" commit -qm base
base_sha=$(git -C "$T/repo" rev-parse HEAD)
printf 'export const value = 2;\n' > "$T/repo/value.ts"
git -C "$T/repo" add value.ts
git -C "$T/repo" commit -qm head
head_sha=$(git -C "$T/repo" rev-parse HEAD)

context_json=$(CLAUDE_REVIEW_MODEL=fixture-claude \
  CLAUDE_REVIEW_EFFORT=high \
  CODEX_REVIEW_MODEL=fixture-codex \
  CODEX_REVIEW_REASONING_EFFORT=xhigh \
  DEEP_REVIEW_TEMP_ROOT="$T/temp" \
  bash "$SCRIPTS/prepare-review-run.sh" \
    --project "$T/repo" --branch "$head_sha" --base "$base_sha")
context_path=$(printf '%s' "$context_json" | jq -r '.reviewArtifactDir + "/context.json"')
run_root=$(printf '%s' "$context_json" | jq -r .reviewRunRoot)
artifact_dir=$(printf '%s' "$context_json" | jq -r .reviewArtifactDir)
snapshot_skill=$(printf '%s' "$context_json" | jq -r .skillDir)
verifier="$SCRIPTS/verify-run-reviewer-launch.mjs"

threat_model="$run_root/threat-model.md"
printf '%s\n' \
  '- プロジェクトの性質・利用者: fixture' \
  '- 現実的な攻撃者・誤操作・障害: normal input' \
  '- データの機密性・完全性: internal' \
  '- 防御・検知・復旧: validation' \
  '- 不明点・保守的仮定: none' > "$threat_model"
chmod 400 "$threat_model"

build_prompt() {
  local reviewer="$1" phase="$2" round="$3" output="$4"
  local -a args
  args=(--context "$context_path" --phase "$phase" --reviewer "$reviewer"
    --threat-model "$threat_model" --output "$output")
  if [ -n "$round" ]; then args+=(--round "$round"); fi
  node "$snapshot_skill/scripts/build-review-prompt.mjs" "${args[@]}" >/dev/null
}

claude_primary="$run_root/claude-primary.md"
codex_primary="$run_root/codex-primary.md"
build_prompt claude primary "" "$claude_primary"
build_prompt codex primary "" "$codex_primary"

pair_args=(
  --context "$context_path"
  --claude-prompt "$claude_primary"
  --codex-prompt "$codex_primary"
  --phase primary
  --reviewer both
  --attempt 1
)
expect_success "verified launcher accepts the canonical initial pair" \
  node "$verifier" --context "$context_path" --mode pair -- "${pair_args[@]}"

echo "== L02: retry and resume shapes remain accepted =="
claude_resume="$run_root/claude-primary-resume.md"
node "$snapshot_skill/scripts/build-review-prompt.mjs" \
  --context "$context_path" --phase primary --reviewer claude --purpose resume \
  --output "$claude_resume" >/dev/null
expect_success "verified launcher accepts a Claude-only resume attempt" \
  node "$verifier" --context "$context_path" --mode pair -- \
    --context "$context_path" --claude-prompt "$claude_resume" \
    --phase primary --reviewer claude --attempt 2 \
    --claude-resume-session-id fixture-session
expect_success "verified launcher accepts a Codex-only fresh retry" \
  node "$verifier" --context "$context_path" --mode pair -- \
    --context "$context_path" --codex-prompt "$codex_primary" \
    --phase primary --reviewer codex --attempt 2
if bash "$SCRIPTS/launch-run-reviewer.sh" \
  --context "$context_path" --mode pair -- \
  --context "$context_path" --codex-prompt "$codex_primary" \
  --phase primary --reviewer codex --attempt 2 \
  >"$T/dispatch.out" 2>"$T/dispatch.err"; then
  ng "fixed launcher dispatches only after snapshot verification"
elif rg -qF "pair phase directory is unavailable for retry" "$T/dispatch.err"; then
  ok "fixed launcher verifies the snapshot and delegates to the existing pair policy"
else
  ng "fixed launcher verifies the snapshot and delegates to the existing pair policy"
fi

echo "== L03: convergence wave and retry shapes remain accepted =="
claude_round_1="$run_root/claude-round-1.md"
codex_round_1="$run_root/codex-round-1.md"
claude_round_2="$run_root/claude-round-2.md"
codex_round_2="$run_root/codex-round-2.md"
build_prompt claude convergence 1 "$claude_round_1"
build_prompt codex convergence 1 "$codex_round_1"
build_prompt claude convergence 2 "$claude_round_2"
build_prompt codex convergence 2 "$codex_round_2"
expect_success "verified launcher accepts a complete convergence wave" \
  node "$verifier" --context "$context_path" --mode wave -- \
    --context "$context_path" --first-round 1 \
    --claude-lead-prompt "$claude_round_1" \
    --codex-lead-prompt "$codex_round_1" \
    --claude-speculative-prompt "$claude_round_2" \
    --codex-speculative-prompt "$codex_round_2"

echo "== L04: Claude follow-up is bounded to one fresh artifact directory =="
followup_prompt="$run_root/claude-followup-1.md"
printf 'Clarify only the disputed point.\n' > "$followup_prompt"
chmod 400 "$followup_prompt"
mkdir -p "$artifact_dir/phase3/followup-1"
chmod 700 "$artifact_dir/phase3/followup-1"
followup_args=(
  --context "$context_path"
  --project "$(printf '%s' "$context_json" | jq -r .projectRoot)"
  --prompt-template "$followup_prompt"
  --diff "$(printf '%s' "$context_json" | jq -r .diffFile)"
  --snapshot "$(printf '%s' "$context_json" | jq -r .reviewSnapshotDir)"
  --run-id "$(printf '%s' "$context_json" | jq -r .reviewRunId)"
  --target "$(printf '%s' "$context_json" | jq -r .target)"
  --head-sha "$(printf '%s' "$context_json" | jq -r .headSha)"
  --diff-sha256 "$(printf '%s' "$context_json" | jq -r .diffSha256)"
  --snapshot-metadata-sha256 \
    "$(printf '%s' "$context_json" | jq -r .snapshotMetadataSha256)"
  --result-contract followup
  --resume-session-id fixture-session
)
expect_success "verified launcher accepts the canonical Claude follow-up" \
  node "$verifier" --context "$context_path" --mode claude-followup \
    --stdout-path "$artifact_dir/phase3/followup-1/claude.out" \
    --stderr-path "$artifact_dir/phase3/followup-1/claude.err" -- \
    "${followup_args[@]}"

echo "== L05: the fixed allow entrypoint fails closed =="
expect_failure "pair mode rejects an arbitrary runner option" \
  node "$verifier" --context "$context_path" --mode pair -- \
    "${pair_args[@]}" --project "$T/repo"
outside_prompt="$T/outside-prompt.md"
printf 'outside\n' > "$outside_prompt"
chmod 400 "$outside_prompt"
expect_failure "pair mode rejects a prompt outside the fixed run" \
  node "$verifier" --context "$context_path" --mode pair -- \
    --context "$context_path" --claude-prompt "$outside_prompt" \
    --codex-prompt "$codex_primary" --phase primary --reviewer both --attempt 1
expect_failure "pair mode rejects a reviewer selection without its exact prompts" \
  node "$verifier" --context "$context_path" --mode pair -- \
    --context "$context_path" --claude-prompt "$claude_primary" \
    --codex-prompt "$codex_primary" --phase primary --reviewer claude --attempt 2
expect_failure "follow-up rejects output outside phase3/followup-N" \
  node "$verifier" --context "$context_path" --mode claude-followup \
    --stdout-path "$T/claude.out" --stderr-path "$T/claude.err" -- \
    "${followup_args[@]}"
expect_failure "launcher shell rejects before dispatching an invalid mode" \
  bash "$SCRIPTS/launch-run-reviewer.sh" \
    --context "$context_path" --mode arbitrary -- "${pair_args[@]}"

echo ""
printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
exit "$fail"
