#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_SKILL="$(cd -P "$TEST_DIR/.." && pwd -P)"
T=$(mktemp -d /tmp/deep-review-pair-test.XXXXXX)
T=$(cd -P "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT INT TERM

pass=0
fail=0
ok() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
ng() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }
check() {
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    ng "$3 (want=[$2] got=[$1])"
  fi
}

mkdir -p "$T/tooling/scripts" "$T/project" "$T/temp"
cp "$SOURCE_SKILL/scripts/run-review-pair.sh" "$T/tooling/scripts/"
cp "$SOURCE_SKILL/scripts/review-prompt-manifest.mjs" "$T/tooling/scripts/"
cp "$SOURCE_SKILL/scripts/review-resume-provenance.mjs" "$T/tooling/scripts/"
cp "$SOURCE_SKILL/scripts/review-pair-policy.mjs" "$T/tooling/scripts/"
cp "$SOURCE_SKILL/scripts/review-output-evidence.mjs" "$T/tooling/scripts/"
cp "$SOURCE_SKILL/scripts/review-convergence.mjs" "$T/tooling/scripts/"
cp "$SOURCE_SKILL/scripts/review-wave-state.mjs" "$T/tooling/scripts/"
cp "$SOURCE_SKILL/scripts/path-interop.mjs" "$T/tooling/scripts/"
cp "$SOURCE_SKILL/scripts/run-output-evidence-bounded.mjs" "$T/tooling/scripts/"
cp "$SOURCE_SKILL/scripts/verify-claude-review-output.mjs" "$T/tooling/scripts/"

cat > "$T/tooling/scripts/verify-review-run.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ -f "$1" ]
printf 'REVIEW_RUN_OK: fixture\n'
SH

cat > "$T/tooling/scripts/run-claude-attested.sh" <<'SH'
#!/usr/bin/env bash
set -eu
trap 'exit 143' TERM
printf '%s\n' "$@" > "$PAIR_TEST_STATE/claude.args"
touch "$PAIR_TEST_STATE/claude.started"
count=0
while [ ! -f "$PAIR_TEST_STATE/codex.started" ] && [ "$count" -lt 200 ]; do
  sleep 0.01
  count=$((count + 1))
done
[ -f "$PAIR_TEST_STATE/codex.started" ] || exit 90
if [ "${PAIR_TEST_SLOW:-0}" = "1" ] ||
  [ "${PAIR_TEST_CLAUDE_SLOW:-0}" = "1" ]; then
  while :; do sleep 1; done
fi
if [ "${PAIR_TEST_CLAUDE_INFRA_FAIL:-0}" = "1" ]; then
  if [ "${PAIR_TEST_EMIT_CLAUDE_ID_ON_INFRA_FAIL:-0}" = "1" ]; then
    printf 'SESSION_ID: fixture-claude\n'
  fi
  exit 3
fi
if [ "${PAIR_TEST_CLAUDE_FAIL:-0}" = "1" ]; then
  if [ "${PAIR_TEST_EMIT_CLAUDE_ID_ON_FAIL:-0}" = "1" ]; then
    printf 'SESSION_ID: fixture-claude\nSTATUS: timed_out\n'
  fi
  exit 6
fi
if [ "${PAIR_TEST_CLAUDE_INVALID:-0}" = "1" ]; then
  printf 'INVALID_REVIEW_OUTPUT\n'
  exit 0
fi
printf 'SESSION_ID: fixture-claude\n---\nCLAUDE_RESULT\nNO_FINDINGS\nscope: fixed diff and HEAD snapshot\nreason: no actionable issue in fixture\n'
SH

cat > "$T/codex-launcher.sh" <<'SH'
#!/usr/bin/env bash
set -eu
trap 'exit 143' TERM
printf '%s\n' "$@" > "$PAIR_TEST_STATE/codex.args"
touch "$PAIR_TEST_STATE/codex.started"
count=0
while [ ! -f "$PAIR_TEST_STATE/claude.started" ] && [ "$count" -lt 200 ]; do
  sleep 0.01
  count=$((count + 1))
done
[ -f "$PAIR_TEST_STATE/claude.started" ] || exit 91
if [ "${PAIR_TEST_SLOW:-0}" = "1" ] ||
  [ "${PAIR_TEST_CODEX_SLOW:-0}" = "1" ]; then
  while :; do sleep 1; done
fi
if [ "${PAIR_TEST_CODEX_INFRA_FAIL:-0}" = "1" ]; then
  if [ "${PAIR_TEST_EMIT_CODEX_ID_ON_INFRA_FAIL:-0}" = "1" ]; then
    printf 'THREAD_ID: fixture-codex\n'
  fi
  exit 3
fi
if [ "${PAIR_TEST_CODEX_FAIL:-0}" = "1" ]; then
  if [ "${PAIR_TEST_EMIT_CODEX_ID_ON_FAIL:-0}" = "1" ]; then
    printf 'THREAD_ID: fixture-codex\nSTATUS: timed_out\n'
  fi
  exit 7
fi
printf 'THREAD_ID: fixture-codex\n---\nCODEX_RESULT\nNO_FINDINGS\nscope: fixed diff and HEAD snapshot\nreason: no actionable issue in fixture\n'
SH

chmod +x "$T/tooling/scripts/run-review-pair.sh" \
  "$T/tooling/scripts/verify-review-run.sh" \
  "$T/tooling/scripts/run-claude-attested.sh" \
  "$T/codex-launcher.sh"

printf 'diff\n' > "$T/review.diff"
mkdir "$T/snapshot"
write_context() {
  local artifact="$1"
  local context="$2"
  local skill_dir="${3:-$T/tooling}"
  local context_artifact="${4:-$artifact}"
  mkdir -p "$artifact/phase4"
  MSYS2_ARG_CONV_EXCL='*' jq -n \
    --arg skillDir "$skill_dir" \
    --arg projectRoot "$T/project" \
    --arg reviewTempRoot "$T/temp" \
    --arg reviewArtifactDir "$context_artifact" \
    --arg codexLauncherPath "$T/codex-launcher.sh" \
    --arg reviewRunId "fixture-run" \
    --arg target "branch:fixture" \
    --arg headSha "fixture-head" \
    --arg diffFile "$T/review.diff" \
    --arg diffSha256 "fixture-diff" \
    --arg reviewSnapshotDir "$T/snapshot" \
    --arg snapshotMetadataSha256 "fixture-snapshot" \
    '{
      skillDir:$skillDir,
      projectRoot:$projectRoot,
      reviewTempRoot:$reviewTempRoot,
      reviewArtifactDir:$reviewArtifactDir,
      codexLauncherPath:$codexLauncherPath,
      reviewRunId:$reviewRunId,
      target:$target,
      headSha:$headSha,
      diffFile:$diffFile,
      diffSha256:$diffSha256,
      reviewSnapshotDir:$reviewSnapshotDir,
      snapshotMetadataSha256:$snapshotMetadataSha256,
      reviewerConfig:{
        claude:{model:"fixture-claude-model",effort:"high"},
        codex:{model:"fixture-codex-model",reasoningEffort:"xhigh"}
      }
    }' > "$context"
}

write_prompt() {
  local context="$1" prompt="$2" reviewer="$3" phase="$4"
  local round="$5" purpose="$6"
  node --input-type=module - \
    "$T/tooling/scripts/review-prompt-manifest.mjs" \
    "$context" "$prompt" "$reviewer" "$phase" "$round" "$purpose" <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [modulePath, contextPath, promptPath, reviewer, phase, round, purpose] =
  process.argv.slice(2);
const { createPromptManifest } = await import(pathToFileURL(modulePath));
writeFileSync(promptPath, `${reviewer} ${phase} ${round || "primary"} ${purpose} prompt\n`);
createPromptManifest({
  context: JSON.parse(readFileSync(contextPath, "utf8")),
  promptPath,
  reviewer,
  phase,
  round: round || undefined,
  purpose,
});
JS
}

write_convergence_adjudication() {
  local artifact="$1" round="$2" stable="$3"
  local claude_new=1 final_set_changed=true
  if [ "$stable" = "true" ]; then
    claude_new=0
    final_set_changed=false
  fi
  mkdir -p "$artifact/phase4/round-$round"
  jq -n \
    --argjson round "$round" \
    --argjson claudeNew "$claude_new" \
    --argjson finalSetChanged "$final_set_changed" \
    '{
      schema:"deep-review-adjudication/v1",
      reviewRunId:"fixture-run",
      phase:"convergence",
      round:$round,
      summary:{
        claudeNew:$claudeNew,
        codexNew:0,
        withdrawn:0,
        downgraded:0,
        upgraded:0,
        finalSetChanged:$finalSetChanged
      }
    }' > "$artifact/phase4/round-$round/adjudication.json"
}

write_unconverged_adjudication_chain() {
  local artifact="$1" last_round="$2" round
  for ((round = 1; round <= last_round; round += 1)); do
    write_convergence_adjudication "$artifact" "$round" false
  done
}

run_missing_value_case() {
  local option="$1"
  local name="${option#--}"
  local output="$T/missing-$name.out"
  local pid count rc

  bash "$T/tooling/scripts/run-review-pair.sh" "$option" > "$output" 2>&1 &
  pid=$!
  count=0
  while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 100 ]; do
    sleep 0.01
    count=$((count + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null
    rc=124
  else
    wait "$pid"
    rc=$?
  fi

  check "$rc" "2" "$option without a value exits 2"
  if rg -q --fixed-strings -- "ERROR: $option requires a value" "$output"; then
    ok "$option missing value is diagnosed"
  else
    ng "$option missing value is diagnosed"
  fi
}

echo "== P00a: output evidence enumerates every accepted finding form =="
cat > "$T/mixed-review.out" <<'OUTPUT'
SESSION_ID: fixture
---
High: inline finding

## Medium
- grouped finding one
- grouped finding two

| Severity | Finding |
|---|---|
| Low | table finding |
OUTPUT
node "$T/tooling/scripts/review-output-evidence.mjs" \
  --input "$T/mixed-review.out" \
  --output "$T/mixed-review.evidence.json" \
  --reviewer claude --phase primary --attempt 1 >/dev/null
if jq -e '
  .candidateCount == 4 and
  [.candidates[].candidateId] ==
    ["claude-F001","claude-F002","claude-F003","claude-F004"] and
  [.candidates[].severity] == ["High","Medium","Medium","Low"]
' "$T/mixed-review.evidence.json" >/dev/null; then
  ok "mixed accepted formats produce one deterministic record per candidate"
else
  ng "mixed accepted formats produce one deterministic record per candidate"
fi

echo "== P00b: repeated titles at distinct source occurrences remain distinct =="
cat > "$T/repeated-title-review.out" <<'OUTPUT'
SESSION_ID: fixture
---
High: repeated finding title

High: repeated finding title
OUTPUT
node "$T/tooling/scripts/review-output-evidence.mjs" \
  --input "$T/repeated-title-review.out" \
  --output "$T/repeated-title-review.evidence.json" \
  --reviewer claude --phase primary --attempt 1 >/dev/null
if jq -e '
  .candidateCount == 2 and
  [.candidates[].candidateId] == ["claude-F001","claude-F002"] and
  [.candidates[].sourceLine] == [1,3] and
  .candidates[0].candidateSha256 != .candidates[1].candidateSha256
' "$T/repeated-title-review.evidence.json" >/dev/null; then
  ok "same title at two source lines remains two adjudicable candidates"
else
  ng "same title at two source lines remains two adjudicable candidates"
fi

echo "== P00: every value option rejects a missing trailing value =="
for option in \
  --context \
  --claude-prompt \
  --codex-prompt \
  --phase \
  --round \
  --reviewer \
  --attempt \
  --wave-status \
  --wave-role \
  --wave-supervisor-nonce \
  --claude-resume-session-id \
  --codex-thread-id; do
  run_missing_value_case "$option"
done

echo "== P01: Claude and Codex are launched concurrently with isolated outputs =="
mkdir "$T/state-primary"
write_context "$T/artifact-primary" "$T/context-primary.json"
CLAUDE_PRIMARY_PROMPT="$T/claude-primary.md"
CODEX_PRIMARY_PROMPT="$T/codex-primary.md"
CLAUDE_PRIMARY_RESUME_PROMPT="$T/claude-primary-resume.md"
write_prompt "$T/context-primary.json" "$CLAUDE_PRIMARY_PROMPT" \
  claude primary "" review
write_prompt "$T/context-primary.json" "$CODEX_PRIMARY_PROMPT" \
  codex primary "" review
write_prompt "$T/context-primary.json" "$CLAUDE_PRIMARY_RESUME_PROMPT" \
  claude primary "" resume
PAIR_TEST_STATE="$T/state-primary" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-primary.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-primary.out"
primary_rc=$?
check "$primary_rc" "0" "parallel pair succeeds"
check "$(jq -r .canonical.claude.exitCode "$T/artifact-primary/phase2/status.json")" \
  "0" "Claude exit code is recorded independently"
check "$(jq -r .canonical.codex.exitCode "$T/artifact-primary/phase2/status.json")" \
  "0" "Codex exit code is recorded independently"
if jq -e '
  .schema == "deep-review-pair/v6" and
  .reviewRunId == "fixture-run" and
  .expectedReviewers == ["claude", "codex"] and
  .attempts[0].schema == "deep-review-attempt/v4" and
  .attempts[0].claude.resumedFromAttempt == null and
  .attempts[0].codex.resumedFromAttempt == null and
  .attempts[0].claude.prompt.reviewer == "claude" and
  .attempts[0].claude.prompt.phase == "primary" and
  .attempts[0].claude.prompt.round == null and
  .attempts[0].claude.prompt.purpose == "review" and
  .attempts[0].codex.prompt.reviewer == "codex" and
  .attempts[0].claude.evidence.candidateCount == 0 and
  .attempts[0].codex.evidence.candidateCount == 0
' "$T/artifact-primary/phase2/status.json" >/dev/null; then
  ok "pair status binds the expected reviewers to the review run"
else
  ng "pair status binds the expected reviewers to the review run"
fi
if rg -q -U --fixed-strings -- $'--context\n'"$T/context-primary.json" \
  "$T/state-primary/claude.args" &&
  rg -q -U --fixed-strings -- $'--run-id\nfixture-run' "$T/state-primary/claude.args" &&
  rg -q -U --fixed-strings -- $'--result-contract\nreview' "$T/state-primary/claude.args"; then
  ok "Claude receives the fixed generation and review contract"
else
  ng "Claude receives the fixed generation and review contract"
fi
if rg -q -U --fixed-strings -- $'--context\n'"$T/context-primary.json" \
  "$T/state-primary/codex.args" &&
  rg -q -U --fixed-strings -- $'--run-id\nfixture-run' "$T/state-primary/codex.args"; then
  ok "Codex receives the fixed context and generation"
else
  ng "Codex receives the fixed context and generation"
fi
if rg -q '^CLAUDE_RESULT$' "$T/artifact-primary/phase2/attempt-1/claude.out" &&
  ! rg -q 'CODEX_RESULT' "$T/artifact-primary/phase2/attempt-1/claude.out"; then
  ok "Claude output remains isolated"
else
  ng "Claude output remains isolated"
fi
if rg -q '^CODEX_RESULT$' "$T/artifact-primary/phase2/attempt-1/codex.out" &&
  ! rg -q 'CLAUDE_RESULT' "$T/artifact-primary/phase2/attempt-1/codex.out"; then
  ok "Codex output remains isolated"
else
  ng "Codex output remains isolated"
fi
PAIR_TEST_STATE="$T/state-primary" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-primary.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --phase primary --reviewer claude --attempt 2 \
    > "$T/pair-primary-invalid-retry.out" 2>&1
successful_retry_rc=$?
check "$successful_retry_rc" "2" "a successful reviewer cannot be retried"
check "$(jq -r '.attempts | length' "$T/artifact-primary/phase2/status.json")" \
  "1" "a rejected retry does not change attempt history"

PAIR_TEST_STATE="$T/state-primary" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-primary.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase convergence --round 21 \
    > "$T/pair-round-21.out" 2>&1
round_twenty_one_rc=$?
check "$round_twenty_one_rc" "2" "convergence round twenty-one is rejected"

echo "== P01a: native Windows aliases preserve path identity across retries =="
case "$OSTYPE" in
  msys*|cygwin*)
    mkdir "$T/state-windows-paths"
    windows_skill_dir=$(cygpath -aw "$T/tooling")
    windows_artifact_dir=$(cygpath -am "$T/artifact-windows-paths")
    write_context "$T/artifact-windows-paths" \
      "$T/context-windows-paths.json" \
      "$windows_skill_dir" "$windows_artifact_dir"
    CLAUDE_WINDOWS_PROMPT="$T/claude-windows-paths.md"
    CODEX_WINDOWS_PROMPT="$T/codex-windows-paths.md"
    write_prompt "$T/context-windows-paths.json" "$CLAUDE_WINDOWS_PROMPT" \
      claude convergence 1 review
    write_prompt "$T/context-windows-paths.json" "$CODEX_WINDOWS_PROMPT" \
      codex convergence 1 review
    PAIR_TEST_STATE="$T/state-windows-paths" PAIR_TEST_CODEX_FAIL=1 \
      bash "$T/tooling/scripts/run-review-pair.sh" \
        --context "$T/context-windows-paths.json" \
        --claude-prompt "$CLAUDE_WINDOWS_PROMPT" \
        --codex-prompt "$CODEX_WINDOWS_PROMPT" \
        --phase convergence --round 1 > "$T/pair-windows-paths.out"
    windows_initial_rc=$?
    check "$windows_initial_rc" "20" \
      "Windows path aliases reach the reviewer result contract"
    PAIR_TEST_STATE="$T/state-windows-paths" \
      bash "$T/tooling/scripts/run-review-pair.sh" \
        --context "$T/context-windows-paths.json" \
        --codex-prompt "$CODEX_WINDOWS_PROMPT" \
        --phase convergence --round 1 \
        --reviewer codex --attempt 2 > "$T/pair-windows-paths-retry.out"
    windows_retry_rc=$?
    check "$windows_retry_rc" "0" \
      "Windows path aliases preserve phase identity during retry"
    ;;
  *)
    printf '  SKIP: native Windows path aliases are unavailable\n'
    ;;
esac

echo "== P01b: path normalization does not permit symlink traversal =="
mkdir "$T/artifact-symlink-target"
if ln -s "$T/artifact-symlink-target" "$T/artifact-symlink" 2>/dev/null &&
  [ -L "$T/artifact-symlink" ]; then
  write_context "$T/artifact-symlink" "$T/context-symlink.json"
  CLAUDE_SYMLINK_PROMPT="$T/claude-symlink.md"
  CODEX_SYMLINK_PROMPT="$T/codex-symlink.md"
  write_prompt "$T/context-symlink.json" "$CLAUDE_SYMLINK_PROMPT" \
    claude primary "" review
  write_prompt "$T/context-symlink.json" "$CODEX_SYMLINK_PROMPT" \
    codex primary "" review
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-symlink.json" \
    --claude-prompt "$CLAUDE_SYMLINK_PROMPT" \
    --codex-prompt "$CODEX_SYMLINK_PROMPT" \
    --phase primary > "$T/pair-symlink.out" 2>&1
  symlink_rc=$?
  check "$symlink_rc" "1" "symlinked artifact paths remain rejected"
  if rg -q --fixed-strings -- \
    'review artifact directory contains symlink traversal' \
    "$T/pair-symlink.out"; then
    ok "symlink rejection remains attributable to path safety"
  else
    ng "symlink rejection remains attributable to path safety"
  fi
else
  printf '  SKIP: native symlink creation is unavailable\n'
fi

echo "== P02: a one-sided failure is preserved for model-specific retry =="
mkdir "$T/state-partial"
write_context "$T/artifact-partial" "$T/context-partial.json"
write_unconverged_adjudication_chain "$T/artifact-partial" 19
CLAUDE_ROUND20_PROMPT="$T/claude-round-20.md"
CODEX_ROUND20_PROMPT="$T/codex-round-20.md"
write_prompt "$T/context-partial.json" "$CLAUDE_ROUND20_PROMPT" \
  claude convergence 20 review
write_prompt "$T/context-partial.json" "$CODEX_ROUND20_PROMPT" \
  codex convergence 20 review

echo "== P01c: prompt provenance mismatches stop before launch =="
write_context "$T/artifact-mismatch" "$T/context-mismatch.json"
bash "$T/tooling/scripts/run-review-pair.sh" \
  --context "$T/context-mismatch.json" \
  --claude-prompt "$CLAUDE_ROUND20_PROMPT" \
  --codex-prompt "$CODEX_ROUND20_PROMPT" \
  --phase convergence --round 19 > "$T/pair-wrong-round.out" 2>&1
wrong_round_rc=$?
check "$wrong_round_rc" "2" "a wrong-round prompt is rejected"

bash "$T/tooling/scripts/run-review-pair.sh" \
  --context "$T/context-mismatch.json" \
  --claude-prompt "$CODEX_ROUND20_PROMPT" \
  --codex-prompt "$CLAUDE_ROUND20_PROMPT" \
  --phase convergence --round 20 > "$T/pair-swapped-reviewers.out" 2>&1
swapped_reviewers_rc=$?
check "$swapped_reviewers_rc" "2" "swapped reviewer prompts are rejected"

bash "$T/tooling/scripts/run-review-pair.sh" \
  --context "$T/context-mismatch.json" \
  --claude-prompt "$CLAUDE_ROUND20_PROMPT" \
  --codex-prompt "$CODEX_ROUND20_PROMPT" \
  --phase primary > "$T/pair-wrong-phase.out" 2>&1
wrong_phase_rc=$?
check "$wrong_phase_rc" "2" "a convergence prompt cannot run as primary"

TAMPERED_ROUND20_PROMPT="$T/claude-round-20-tampered.md"
write_prompt "$T/context-mismatch.json" "$TAMPERED_ROUND20_PROMPT" \
  claude convergence 20 review
chmod u+w "$TAMPERED_ROUND20_PROMPT" 2>/dev/null || true
printf 'tampered\n' >> "$TAMPERED_ROUND20_PROMPT"
bash "$T/tooling/scripts/run-review-pair.sh" \
  --context "$T/context-mismatch.json" \
  --claude-prompt "$TAMPERED_ROUND20_PROMPT" \
  --codex-prompt "$CODEX_ROUND20_PROMPT" \
  --phase convergence --round 20 > "$T/pair-tampered-prompt.out" 2>&1
tampered_prompt_rc=$?
check "$tampered_prompt_rc" "2" "a prompt changed after manifest creation is rejected"
if [ ! -e "$T/artifact-mismatch/phase2" ] &&
  [ ! -e "$T/artifact-mismatch/phase4/round-19" ] &&
  [ ! -e "$T/artifact-mismatch/phase4/round-20" ]; then
  ok "prompt provenance failures do not create attempt artifacts"
else
  ng "prompt provenance failures do not create attempt artifacts"
fi

PAIR_TEST_STATE="$T/state-partial" PAIR_TEST_CODEX_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-partial.json" \
    --claude-prompt "$CLAUDE_ROUND20_PROMPT" \
    --codex-prompt "$CODEX_ROUND20_PROMPT" \
    --phase convergence --round 20 > "$T/pair-partial.out"
partial_rc=$?
check "$partial_rc" "20" "one-sided failure has a distinct pair exit code"
check "$(jq -r .round "$T/artifact-partial/phase4/round-20/status.json")" \
  "20" "twentieth convergence round is recorded"
check "$(jq -r .canonical.claude.exitCode "$T/artifact-partial/phase4/round-20/status.json")" \
  "0" "successful reviewer result is retained"
check "$(jq -r .canonical.codex.exitCode "$T/artifact-partial/phase4/round-20/status.json")" \
  "7" "failed reviewer result is retained for retry"

claude_args_before=$(cat "$T/state-partial/claude.args")
PAIR_TEST_STATE="$T/state-partial" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-partial.json" \
    --codex-prompt "$CODEX_ROUND20_PROMPT" \
    --phase convergence --round 20 \
    --reviewer codex --attempt 2 > "$T/pair-partial-retry.out"
partial_retry_rc=$?
check "$partial_retry_rc" "0" "one-sided retry completes the pair"
check "$(jq -r '.attempts | length' \
  "$T/artifact-partial/phase4/round-20/status.json")" \
  "2" "retry history is retained"
check "$(jq -r .canonical.claude.attempt \
  "$T/artifact-partial/phase4/round-20/status.json")" \
  "1" "the successful Claude attempt remains canonical"
check "$(jq -r .canonical.codex.attempt \
  "$T/artifact-partial/phase4/round-20/status.json")" \
  "2" "the successful Codex retry becomes canonical"
check "$(jq -r .canonical.codex.execution \
  "$T/artifact-partial/phase4/round-20/status.json")" \
  "retry" "a new full-prompt execution is recorded as retry"
check "$(cat "$T/state-partial/claude.args")" "$claude_args_before" \
  "the successful Claude reviewer is not relaunched"

echo "== P02b: retry exhaustion remains incomplete and cannot be retried again =="
mkdir "$T/state-exhausted"
write_context "$T/artifact-exhausted" "$T/context-exhausted.json"
write_unconverged_adjudication_chain "$T/artifact-exhausted" 18
CLAUDE_ROUND19_PROMPT="$T/claude-round-19.md"
CODEX_ROUND19_PROMPT="$T/codex-round-19.md"
write_prompt "$T/context-exhausted.json" "$CLAUDE_ROUND19_PROMPT" \
  claude convergence 19 review
write_prompt "$T/context-exhausted.json" "$CODEX_ROUND19_PROMPT" \
  codex convergence 19 review
PAIR_TEST_STATE="$T/state-exhausted" PAIR_TEST_CODEX_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-exhausted.json" \
    --claude-prompt "$CLAUDE_ROUND19_PROMPT" \
    --codex-prompt "$CODEX_ROUND19_PROMPT" \
    --phase convergence --round 19 > "$T/pair-exhausted-initial.out"
exhausted_initial_rc=$?
check "$exhausted_initial_rc" "20" "one-sided initial failure remains retryable"
PAIR_TEST_STATE="$T/state-exhausted" PAIR_TEST_CODEX_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-exhausted.json" \
    --codex-prompt "$CODEX_ROUND19_PROMPT" \
    --phase convergence --round 19 \
    --reviewer codex --attempt 2 > "$T/pair-exhausted-retry.out"
exhausted_retry_rc=$?
check "$exhausted_retry_rc" "20" "failed retry leaves the pair incomplete"
check "$(jq -r .complete \
  "$T/artifact-exhausted/phase4/round-19/status.json")" \
  "false" "retry exhaustion cannot become a complete pair"
PAIR_TEST_STATE="$T/state-exhausted" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-exhausted.json" \
    --codex-prompt "$CODEX_ROUND19_PROMPT" \
    --phase convergence --round 19 \
    --reviewer codex --attempt 3 > "$T/pair-exhausted-third.out" 2>&1
exhausted_third_rc=$?
check "$exhausted_third_rc" "2" "a third reviewer attempt is rejected"
check "$(jq -r '.attempts | length' \
  "$T/artifact-exhausted/phase4/round-19/status.json")" \
  "2" "retry exhaustion preserves exactly two attempts"

echo "== P02c: execution infrastructure refusal stays distinct and recoverable =="
mkdir "$T/state-dual-normal"
write_context "$T/artifact-dual-normal" "$T/context-dual-normal.json"
PAIR_TEST_STATE="$T/state-dual-normal" PAIR_TEST_CLAUDE_FAIL=1 \
  PAIR_TEST_CODEX_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-dual-normal.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-dual-normal.out"
dual_normal_rc=$?
check "$dual_normal_rc" "21" "dual normal failure keeps the no-success exit code"
PAIR_TEST_STATE="$T/state-dual-normal" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-dual-normal.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary --reviewer both --attempt 2 \
    > "$T/pair-dual-normal-retry.out"
check "$?" "0" "global dual normal retry remains available"

mkdir "$T/state-infra-partial"
write_context "$T/artifact-infra-partial" "$T/context-infra-partial.json"
CODEX_INFRA_RESUME_PROMPT="$T/codex-infra-resume.md"
write_prompt "$T/context-infra-partial.json" "$CODEX_INFRA_RESUME_PROMPT" \
  codex primary "" resume
PAIR_TEST_STATE="$T/state-infra-partial" PAIR_TEST_CODEX_INFRA_FAIL=1 \
  PAIR_TEST_EMIT_CODEX_ID_ON_INFRA_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-infra-partial.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-infra-partial.out"
infra_partial_rc=$?
check "$infra_partial_rc" "3" "one-sided infrastructure refusal exits 3"
check "$(jq -r .canonical.claude.exitCode \
  "$T/artifact-infra-partial/phase2/status.json")" \
  "0" "successful peer is retained across infrastructure recovery"
check "$(jq -r .canonical.codex.exitCode \
  "$T/artifact-infra-partial/phase2/status.json")" \
  "3" "infrastructure exit remains machine-readable"
infra_claude_args_before=$(cat "$T/state-infra-partial/claude.args")
infra_codex_args_before=$(cat "$T/state-infra-partial/codex.args")
PAIR_TEST_STATE="$T/state-infra-partial" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-infra-partial.json" \
    --codex-prompt "$CODEX_INFRA_RESUME_PROMPT" \
    --phase primary --reviewer codex --attempt 2 \
    --codex-thread-id fixture-codex \
    > "$T/pair-infra-partial-resume.out" 2>&1
check "$?" "2" "exit 3 cannot resume even when an ID is present"
check "$(jq -r '.attempts | length' \
  "$T/artifact-infra-partial/phase2/status.json")" \
  "1" "rejected infrastructure resume leaves history unchanged"
check "$(cat "$T/state-infra-partial/codex.args")" "$infra_codex_args_before" \
  "rejected infrastructure resume does not launch Codex"
PAIR_TEST_STATE="$T/state-infra-partial" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-infra-partial.json" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary --reviewer codex --attempt 2 \
    > "$T/pair-infra-partial-retry.out"
check "$?" "0" "fresh retry recovers the infrastructure refusal"
check "$(cat "$T/state-infra-partial/claude.args")" "$infra_claude_args_before" \
  "successful Claude reviewer is not relaunched"

mkdir "$T/state-infra-both"
write_context "$T/artifact-infra-both" "$T/context-infra-both.json"
PAIR_TEST_STATE="$T/state-infra-both" PAIR_TEST_CLAUDE_INFRA_FAIL=1 \
  PAIR_TEST_CODEX_INFRA_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-infra-both.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-infra-both.out"
check "$?" "3" "dual infrastructure refusal exits 3"
PAIR_TEST_STATE="$T/state-infra-both" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-infra-both.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary --reviewer both --attempt 2 \
    > "$T/pair-infra-both-retry.out"
check "$?" "0" "dual infrastructure refusal can fresh retry both reviewers"

mkdir "$T/state-infra-mixed"
write_context "$T/artifact-infra-mixed" "$T/context-infra-mixed.json"
CODEX_INFRA_MIXED_RESUME_PROMPT="$T/codex-infra-mixed-resume.md"
write_prompt "$T/context-infra-mixed.json" "$CODEX_INFRA_MIXED_RESUME_PROMPT" \
  codex primary "" resume
PAIR_TEST_STATE="$T/state-infra-mixed" PAIR_TEST_CLAUDE_INFRA_FAIL=1 \
  PAIR_TEST_CODEX_FAIL=1 PAIR_TEST_EMIT_CODEX_ID_ON_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-infra-mixed.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-infra-mixed.out"
check "$?" "3" "mixed infrastructure and normal failure prioritizes exit 3"
PAIR_TEST_STATE="$T/state-infra-mixed" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-infra-mixed.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_INFRA_MIXED_RESUME_PROMPT" \
    --phase primary --reviewer both --attempt 2 \
    --codex-thread-id fixture-codex \
    > "$T/pair-infra-mixed-retry.out"
check "$?" "0" "mixed failures keep the global both-reviewer retry contract"
if jq -e '
  .attempts[1].claude.execution == "retry" and
  .attempts[1].codex.execution == "resume" and
  .attempts[1].codex.resumedFromAttempt == 1
' "$T/artifact-infra-mixed/phase2/status.json" >/dev/null; then
  ok "mixed retry fresh-starts exit 3 and resumes the normal failure"
else
  ng "mixed retry fresh-starts exit 3 and resumes the normal failure"
fi

echo "== P03: a one-sided timeout can resume without relaunching its peer =="
mkdir "$T/state-resume"
write_context "$T/artifact-resume" "$T/context-resume.json"
PAIR_TEST_STATE="$T/state-resume" PAIR_TEST_CLAUDE_FAIL=1 \
  PAIR_TEST_EMIT_CLAUDE_ID_ON_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-resume.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-resume-initial.out"
resume_initial_rc=$?
check "$resume_initial_rc" "20" "one-sided Claude failure is retryable"
codex_args_before=$(cat "$T/state-resume/codex.args")
PAIR_TEST_STATE="$T/state-resume" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-resume.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --phase primary --reviewer claude --attempt 2 \
    --claude-resume-session-id fixture-claude \
    > "$T/pair-resume-wrong-purpose.out" 2>&1
resume_wrong_purpose_rc=$?
check "$resume_wrong_purpose_rc" "2" \
  "resume rejects a full-review prompt without resume provenance"
check "$(jq -r '.attempts | length' "$T/artifact-resume/phase2/status.json")" \
  "1" "a rejected resume leaves attempt history unchanged"
PAIR_TEST_STATE="$T/state-resume" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-resume.json" \
    --claude-prompt "$CLAUDE_PRIMARY_RESUME_PROMPT" \
    --phase primary --reviewer claude --attempt 2 \
    --claude-resume-session-id other-run-session \
    > "$T/pair-resume-wrong-id.out" 2>&1
resume_wrong_id_rc=$?
check "$resume_wrong_id_rc" "2" \
  "resume rejects a session ID from another review attempt"
check "$(jq -r '.attempts | length' "$T/artifact-resume/phase2/status.json")" \
  "1" "a mismatched resume ID does not create an attempt artifact"
PAIR_TEST_STATE="$T/state-resume" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-resume.json" \
    --claude-prompt "$CLAUDE_PRIMARY_RESUME_PROMPT" \
    --phase primary --reviewer claude --attempt 2 \
    --claude-resume-session-id fixture-claude > "$T/pair-resume.out"
resume_rc=$?
check "$resume_rc" "0" "one-sided Claude resume completes the pair"
check "$(jq -r .canonical.claude.execution \
  "$T/artifact-resume/phase2/status.json")" \
  "resume" "the canonical Claude result records resume execution"
check "$(jq -r .canonical.claude.resumeId \
  "$T/artifact-resume/phase2/status.json")" \
  "fixture-claude" "the canonical Claude result records the resumed session"
check "$(jq -r .canonical.claude.resumedFromAttempt \
  "$T/artifact-resume/phase2/status.json")" \
  "1" "the canonical Claude result records its source attempt"
check "$(jq -r .canonical.claude.attempt \
  "$T/artifact-resume/phase2/status.json")" \
  "2" "the successful Claude resume becomes canonical"
check "$(cat "$T/state-resume/codex.args")" "$codex_args_before" \
  "the successful Codex reviewer is not relaunched"
if rg -q -U --fixed-strings -- $'--resume-session-id\nfixture-claude' \
  "$T/state-resume/claude.args" &&
  rg -q -U --fixed-strings -- $'--prompt-template\n'"$CLAUDE_PRIMARY_RESUME_PROMPT" \
    "$T/state-resume/claude.args"; then
  ok "Claude receives the saved session ID and finalize-only prompt"
else
  ng "Claude receives the saved session ID and finalize-only prompt"
fi

echo "== P03b: Codex resume is bound to its failed attempt output =="
mkdir "$T/state-codex-resume"
write_context "$T/artifact-codex-resume" "$T/context-codex-resume.json"
CODEX_PRIMARY_RESUME_PROMPT="$T/codex-primary-resume.md"
write_prompt "$T/context-codex-resume.json" "$CODEX_PRIMARY_RESUME_PROMPT" \
  codex primary "" resume
PAIR_TEST_STATE="$T/state-codex-resume" PAIR_TEST_CODEX_FAIL=1 \
  PAIR_TEST_EMIT_CODEX_ID_ON_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-codex-resume.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-codex-resume-initial.out"
codex_resume_initial_rc=$?
check "$codex_resume_initial_rc" "20" "one-sided Codex failure is retryable"
PAIR_TEST_STATE="$T/state-codex-resume" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-codex-resume.json" \
    --codex-prompt "$CODEX_PRIMARY_RESUME_PROMPT" \
    --phase primary --reviewer codex --attempt 2 \
    --codex-thread-id other-run-thread \
    > "$T/pair-codex-resume-wrong-id.out" 2>&1
codex_resume_wrong_id_rc=$?
check "$codex_resume_wrong_id_rc" "2" \
  "Codex resume rejects a thread ID from another review attempt"
PAIR_TEST_STATE="$T/state-codex-resume" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-codex-resume.json" \
    --codex-prompt "$CODEX_PRIMARY_RESUME_PROMPT" \
    --phase primary --reviewer codex --attempt 2 \
    --codex-thread-id fixture-codex > "$T/pair-codex-resume.out"
codex_resume_rc=$?
check "$codex_resume_rc" "0" "one-sided Codex resume completes the pair"
check "$(jq -r .canonical.codex.resumedFromAttempt \
  "$T/artifact-codex-resume/phase2/status.json")" \
  "1" "the canonical Codex result records its source attempt"

echo "== P03c: unavailable or ambiguous resume IDs require a fresh retry =="
mkdir "$T/state-resume-unavailable"
write_context "$T/artifact-resume-unavailable" "$T/context-resume-unavailable.json"
CLAUDE_UNAVAILABLE_RESUME_PROMPT="$T/claude-unavailable-resume.md"
write_prompt "$T/context-resume-unavailable.json" \
  "$CLAUDE_UNAVAILABLE_RESUME_PROMPT" claude primary "" resume
PAIR_TEST_STATE="$T/state-resume-unavailable" PAIR_TEST_CLAUDE_FAIL=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-resume-unavailable.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-resume-unavailable-initial.out"
resume_unavailable_initial_rc=$?
check "$resume_unavailable_initial_rc" "20" \
  "a failure without a session ID remains retryable"
PAIR_TEST_STATE="$T/state-resume-unavailable" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-resume-unavailable.json" \
    --claude-prompt "$CLAUDE_UNAVAILABLE_RESUME_PROMPT" \
    --phase primary --reviewer claude --attempt 2 \
    --claude-resume-session-id fixture-claude \
    > "$T/pair-resume-missing-id.out" 2>&1
resume_missing_id_rc=$?
check "$resume_missing_id_rc" "2" \
  "resume rejects a failed output without a session ID"
printf 'SESSION_ID: fixture-claude\nSESSION_ID: duplicate-session\n' \
  >> "$T/artifact-resume-unavailable/phase2/attempt-1/claude.out"
PAIR_TEST_STATE="$T/state-resume-unavailable" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-resume-unavailable.json" \
    --claude-prompt "$CLAUDE_UNAVAILABLE_RESUME_PROMPT" \
    --phase primary --reviewer claude --attempt 2 \
    --claude-resume-session-id fixture-claude \
    > "$T/pair-resume-multiple-ids.out" 2>&1
resume_multiple_ids_rc=$?
check "$resume_multiple_ids_rc" "2" \
  "resume rejects a failed output with multiple session IDs"
PAIR_TEST_STATE="$T/state-resume-unavailable" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-resume-unavailable.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --phase primary --reviewer claude --attempt 2 \
    > "$T/pair-resume-fresh-retry.out"
resume_fresh_retry_rc=$?
check "$resume_fresh_retry_rc" "0" \
  "a fresh retry remains available when resume provenance is unusable"
check "$(jq -r .canonical.claude.execution \
  "$T/artifact-resume-unavailable/phase2/status.json")" \
  "retry" "the fallback is recorded as a fresh retry, not a resume"

echo "== P04: external termination preserves interrupted pair status =="
mkdir "$T/state-interrupted"
write_context "$T/artifact-interrupted" "$T/context-interrupted.json"
PAIR_TEST_STATE="$T/state-interrupted" PAIR_TEST_SLOW=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-interrupted.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-interrupted.out" &
pair_pid=$!
count=0
while { [ ! -f "$T/state-interrupted/claude.started" ] ||
  [ ! -f "$T/state-interrupted/codex.started" ]; } &&
  [ "$count" -lt 200 ]; do
  sleep 0.01
  count=$((count + 1))
done
kill -TERM "$pair_pid"
wait "$pair_pid"
interrupted_rc=$?
check "$interrupted_rc" "143" "external termination is propagated"
check "$(jq -r '.attempts[-1].interrupted' \
  "$T/artifact-interrupted/phase2/status.json")" \
  "true" "interrupted status is published"
check "$(jq -r '.attempts[-1].claude.launched' \
  "$T/artifact-interrupted/phase2/status.json")" \
  "true" "Claude launch state survives interruption"
check "$(jq -r '.attempts[-1].codex.launched' \
  "$T/artifact-interrupted/phase2/status.json")" \
  "true" "Codex launch state survives interruption"
if [ "$(jq -r .canonical.claude.exitCode \
  "$T/artifact-interrupted/phase2/status.json")" -ne 0 ] &&
  [ "$(jq -r .canonical.codex.exitCode \
  "$T/artifact-interrupted/phase2/status.json")" -ne 0 ]; then
  ok "model-specific interrupted exit codes are retained"
else
  ng "model-specific interrupted exit codes are retained"
fi

echo "== P04b: INT preserves interrupted pair status and exit code =="
mkdir "$T/state-interrupted-int"
write_context "$T/artifact-interrupted-int" "$T/context-interrupted-int.json"
set -m
(
  export PAIR_TEST_STATE="$T/state-interrupted-int" PAIR_TEST_SLOW=1
  trap - INT
  exec bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-interrupted-int.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary
) > "$T/pair-interrupted-int.out" &
pair_pid=$!
set +m
count=0
while { [ ! -f "$T/state-interrupted-int/claude.started" ] ||
  [ ! -f "$T/state-interrupted-int/codex.started" ]; } &&
  [ "$count" -lt 200 ]; do
  sleep 0.01
  count=$((count + 1))
done
kill -INT "$pair_pid"
wait "$pair_pid"
interrupted_int_rc=$?
check "$interrupted_int_rc" "130" "INT termination is propagated"
check "$(jq -r '.attempts[-1].interrupted' \
  "$T/artifact-interrupted-int/phase2/status.json")" \
  "true" "INT publishes interrupted pair status"

echo "== P05: a reaped reviewer PID is not reused during later termination =="
mkdir "$T/state-partial-interrupt"
write_context "$T/artifact-partial-interrupt" "$T/context-partial-interrupt.json"
PAIR_TEST_STATE="$T/state-partial-interrupt" PAIR_TEST_CODEX_SLOW=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-partial-interrupt.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-partial-interrupt.out" &
pair_pid=$!
count=0
while ! rg -q '^CLAUDE_RESULT$' \
  "$T/artifact-partial-interrupt/phase2/attempt-1/claude.out" 2>/dev/null &&
  [ "$count" -lt 200 ]; do
  sleep 0.01
  count=$((count + 1))
done
kill -TERM "$pair_pid"
wait "$pair_pid"
partial_interrupt_rc=$?
check "$partial_interrupt_rc" "143" "termination after one completion is propagated"
check "$(jq -r .canonical.claude.exitCode \
  "$T/artifact-partial-interrupt/phase2/status.json")" \
  "0" "the completed Claude result is not replaced by a stale-PID wait"
check "$(jq -r .canonical.codex.exitCode \
  "$T/artifact-partial-interrupt/phase2/status.json")" \
  "143" "the still-running Codex reviewer is terminated and recorded"
check "$(jq -r .canonical.claude.evidence.schema \
  "$T/artifact-partial-interrupt/phase2/status.json")" \
  "deep-review-output-evidence/v1" \
  "the completed Claude result retains output evidence"
if [ -f "$T/artifact-partial-interrupt/phase2/attempt-1/claude.evidence.json" ]; then
  ok "the interrupted attempt publishes completed Claude evidence"
else
  ng "the interrupted attempt publishes completed Claude evidence"
fi

echo "== P05b: a completed Codex result is retained symmetrically =="
mkdir "$T/state-codex-partial-interrupt"
write_context "$T/artifact-codex-partial-interrupt" \
  "$T/context-codex-partial-interrupt.json"
PAIR_TEST_STATE="$T/state-codex-partial-interrupt" PAIR_TEST_CLAUDE_SLOW=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-codex-partial-interrupt.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-codex-partial-interrupt.out" &
pair_pid=$!
count=0
while ! rg -q '^CODEX_RESULT$' \
  "$T/artifact-codex-partial-interrupt/phase2/attempt-1/codex.out" \
  2>/dev/null && [ "$count" -lt 200 ]; do
  sleep 0.01
  count=$((count + 1))
done
kill -TERM "$pair_pid"
wait "$pair_pid"
codex_partial_interrupt_rc=$?
check "$codex_partial_interrupt_rc" "143" \
  "termination after Codex completion is propagated"
check "$(jq -r .canonical.claude.exitCode \
  "$T/artifact-codex-partial-interrupt/phase2/status.json")" \
  "143" "the still-running Claude reviewer is terminated and recorded"
check "$(jq -r .canonical.codex.exitCode \
  "$T/artifact-codex-partial-interrupt/phase2/status.json")" \
  "0" "the completed Codex result remains successful"
check "$(jq -r .canonical.codex.evidence.schema \
  "$T/artifact-codex-partial-interrupt/phase2/status.json")" \
  "deep-review-output-evidence/v1" \
  "the completed Codex result retains output evidence"

echo "== P06: interrupted evidence failure cannot claim reviewer success =="
mkdir "$T/state-interrupted-evidence-failure"
write_context "$T/artifact-interrupted-evidence-failure" \
  "$T/context-interrupted-evidence-failure.json"
PAIR_TEST_STATE="$T/state-interrupted-evidence-failure" \
  PAIR_TEST_CLAUDE_INVALID=1 PAIR_TEST_CODEX_SLOW=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-interrupted-evidence-failure.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-interrupted-evidence-failure.out" &
pair_pid=$!
count=0
while ! rg -q '^INVALID_REVIEW_OUTPUT$' \
  "$T/artifact-interrupted-evidence-failure/phase2/attempt-1/claude.out" \
  2>/dev/null && [ "$count" -lt 200 ]; do
  sleep 0.01
  count=$((count + 1))
done
kill -TERM "$pair_pid"
wait "$pair_pid"
interrupted_evidence_failure_rc=$?
check "$interrupted_evidence_failure_rc" "143" \
  "termination is propagated after evidence generation failure"
check "$(jq -r .canonical.claude.exitCode \
  "$T/artifact-interrupted-evidence-failure/phase2/status.json")" \
  "1" "evidence generation failure downgrades the completed reviewer"
check "$(jq -r .canonical.claude.evidence \
  "$T/artifact-interrupted-evidence-failure/phase2/status.json")" \
  "null" "failed evidence generation cannot publish a success receipt"
if rg -q --fixed-strings -- "ERROR: Claude output evidence generation failed" \
  "$T/artifact-interrupted-evidence-failure/phase2/attempt-1/claude.err"; then
  ok "interrupted evidence generation failure is diagnosed"
else
  ng "interrupted evidence generation failure is diagnosed"
fi

echo "== P07: interrupted evidence generation is bounded by a watchdog =="
mv "$T/tooling/scripts/review-output-evidence.mjs" \
  "$T/tooling/scripts/review-output-evidence-real.mjs"
cat > "$T/tooling/scripts/review-output-evidence.mjs" <<'JS'
setInterval(() => {}, 1000);
JS
mkdir "$T/state-interrupted-evidence-timeout"
write_context "$T/artifact-interrupted-evidence-timeout" \
  "$T/context-interrupted-evidence-timeout.json"
OUTPUT_EVIDENCE_TIMEOUT_SECONDS=1 \
  PAIR_TEST_STATE="$T/state-interrupted-evidence-timeout" \
  PAIR_TEST_CODEX_SLOW=1 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-interrupted-evidence-timeout.json" \
    --claude-prompt "$CLAUDE_PRIMARY_PROMPT" \
    --codex-prompt "$CODEX_PRIMARY_PROMPT" \
    --phase primary > "$T/pair-interrupted-evidence-timeout.out" &
pair_pid=$!
count=0
while ! rg -q '^CLAUDE_RESULT$' \
  "$T/artifact-interrupted-evidence-timeout/phase2/attempt-1/claude.out" \
  2>/dev/null && [ "$count" -lt 200 ]; do
  sleep 0.01
  count=$((count + 1))
done
timeout_started=$(date +%s)
kill -TERM "$pair_pid"
wait "$pair_pid"
interrupted_evidence_timeout_rc=$?
timeout_elapsed=$(($(date +%s) - timeout_started))
mv "$T/tooling/scripts/review-output-evidence-real.mjs" \
  "$T/tooling/scripts/review-output-evidence.mjs"
check "$interrupted_evidence_timeout_rc" "143" \
  "termination is propagated after evidence generation timeout"
if [ "$timeout_elapsed" -le 5 ]; then
  ok "interrupted evidence generation respects its watchdog bound"
else
  ng "interrupted evidence generation respects its watchdog bound"
fi
check "$(jq -r .canonical.claude.exitCode \
  "$T/artifact-interrupted-evidence-timeout/phase2/status.json")" \
  "1" "evidence timeout downgrades the completed reviewer"
check "$(jq -r .canonical.claude.evidence \
  "$T/artifact-interrupted-evidence-timeout/phase2/status.json")" \
  "null" "evidence timeout cannot publish a success receipt"

echo "== P08: a new round is rejected only after convergence =="
mkdir "$T/state-converged"
write_context "$T/artifact-converged" "$T/context-converged.json"
write_convergence_adjudication "$T/artifact-converged" 1 true
write_convergence_adjudication "$T/artifact-converged" 2 true
CLAUDE_CONVERGED_ROUND3_PROMPT="$T/claude-converged-round-3.md"
CODEX_CONVERGED_ROUND3_PROMPT="$T/codex-converged-round-3.md"
write_prompt "$T/context-converged.json" "$CLAUDE_CONVERGED_ROUND3_PROMPT" \
  claude convergence 3 review
write_prompt "$T/context-converged.json" "$CODEX_CONVERGED_ROUND3_PROMPT" \
  codex convergence 3 review
PAIR_TEST_STATE="$T/state-converged" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-converged.json" \
    --claude-prompt "$CLAUDE_CONVERGED_ROUND3_PROMPT" \
    --codex-prompt "$CODEX_CONVERGED_ROUND3_PROMPT" \
    --phase convergence --round 3 \
    > "$T/pair-converged-round-3.out" 2>&1
converged_round_3_rc=$?
check "$converged_round_3_rc" "2" \
  "a new round is rejected after two stable rounds"
if rg -q --fixed-strings -- \
  "review already converged at round 2; round 3 cannot start" \
  "$T/pair-converged-round-3.out"; then
  ok "the rejected post-convergence round is diagnosed"
else
  ng "the rejected post-convergence round is diagnosed"
fi
if [ ! -e "$T/artifact-converged/phase4/round-3" ] &&
  [ ! -e "$T/state-converged/claude.started" ] &&
  [ ! -e "$T/state-converged/codex.started" ]; then
  ok "post-convergence rejection creates no round or reviewer process"
else
  ng "post-convergence rejection creates no round or reviewer process"
fi

mkdir "$T/state-incomplete-chain"
write_context "$T/artifact-incomplete-chain" "$T/context-incomplete-chain.json"
write_convergence_adjudication "$T/artifact-incomplete-chain" 1 true
CLAUDE_INCOMPLETE_ROUND3_PROMPT="$T/claude-incomplete-round-3.md"
CODEX_INCOMPLETE_ROUND3_PROMPT="$T/codex-incomplete-round-3.md"
write_prompt "$T/context-incomplete-chain.json" "$CLAUDE_INCOMPLETE_ROUND3_PROMPT" \
  claude convergence 3 review
write_prompt "$T/context-incomplete-chain.json" "$CODEX_INCOMPLETE_ROUND3_PROMPT" \
  codex convergence 3 review
PAIR_TEST_STATE="$T/state-incomplete-chain" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-incomplete-chain.json" \
    --claude-prompt "$CLAUDE_INCOMPLETE_ROUND3_PROMPT" \
    --codex-prompt "$CODEX_INCOMPLETE_ROUND3_PROMPT" \
    --phase convergence --round 3 \
    > "$T/pair-incomplete-round-3.out" 2>&1
incomplete_round_3_rc=$?
check "$incomplete_round_3_rc" "2" \
  "a new round is rejected while the preceding chain is incomplete"
if rg -q --fixed-strings -- "previous convergence round 2 is missing" \
  "$T/pair-incomplete-round-3.out" &&
  [ ! -e "$T/artifact-incomplete-chain/phase4/round-3" ] &&
  [ ! -e "$T/state-incomplete-chain/claude.started" ] &&
  [ ! -e "$T/state-incomplete-chain/codex.started" ]; then
  ok "an incomplete chain is diagnosed before round or reviewer creation"
else
  ng "an incomplete chain is diagnosed before round or reviewer creation"
fi

mkdir "$T/state-unconverged"
write_context "$T/artifact-unconverged" "$T/context-unconverged.json"
write_convergence_adjudication "$T/artifact-unconverged" 1 true
write_convergence_adjudication "$T/artifact-unconverged" 2 false
CLAUDE_UNCONVERGED_ROUND3_PROMPT="$T/claude-unconverged-round-3.md"
CODEX_UNCONVERGED_ROUND3_PROMPT="$T/codex-unconverged-round-3.md"
write_prompt "$T/context-unconverged.json" "$CLAUDE_UNCONVERGED_ROUND3_PROMPT" \
  claude convergence 3 review
write_prompt "$T/context-unconverged.json" "$CODEX_UNCONVERGED_ROUND3_PROMPT" \
  codex convergence 3 review
PAIR_TEST_STATE="$T/state-unconverged" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$T/context-unconverged.json" \
    --claude-prompt "$CLAUDE_UNCONVERGED_ROUND3_PROMPT" \
    --codex-prompt "$CODEX_UNCONVERGED_ROUND3_PROMPT" \
    --phase convergence --round 3 \
    > "$T/pair-unconverged-round-3.out" 2>&1
unconverged_round_3_rc=$?
check "$unconverged_round_3_rc" "0" \
  "a new round remains allowed before convergence"
check "$(jq -r .complete \
  "$T/artifact-unconverged/phase4/round-3/status.json")" \
  "true" "the allowed unconverged round completes normally"

echo ""
printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
exit "$fail"
