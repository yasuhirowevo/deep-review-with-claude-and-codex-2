#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_SKILL="$(cd -P "$TEST_DIR/.." && pwd -P)"
T=$(mktemp -d /tmp/deep-review-wave-test.XXXXXX)
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

WAVE_TEST_SUPERVISOR_PID=$$
case "$OSTYPE" in
  msys*|cygwin*)
    WAVE_TEST_SUPERVISOR_PID=$(sed -n '1p' "/proc/$$/winpid" 2>/dev/null) ||
      WAVE_TEST_SUPERVISOR_PID=""
    ;;
esac
if ! [[ "$WAVE_TEST_SUPERVISOR_PID" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: native test supervisor PID is unavailable" >&2
  exit 2
fi

mkdir -p "$T/tooling/scripts" "$T/project" "$T/temp" "$T/state"
for script in \
  run-review-pair.sh run-review-wave.sh control-review-wave.sh \
  review-wave-state.mjs review-convergence.mjs review-prompt-manifest.mjs \
  path-interop.mjs \
  review-resume-provenance.mjs review-pair-policy.mjs review-output-evidence.mjs \
  run-output-evidence-bounded.mjs verify-claude-review-output.mjs; do
  cp "$SOURCE_SKILL/scripts/$script" "$T/tooling/scripts/$script"
done

cat > "$T/tooling/scripts/verify-review-run.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ -f "$1" ]
sleep "${WAVE_TEST_VERIFY_DELAY:-0}"
printf 'REVIEW_RUN_OK: fixture\n'
SH

cat > "$T/tooling/scripts/run-claude-attested.sh" <<'SH'
#!/usr/bin/env bash
set -eu
prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prompt-template) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
round=$(printf '%s' "$prompt" | sed -E 's/.*round-([0-9]+).*/\1/')
on_term() {
  sleep "${WAVE_TEST_TERM_CLEANUP_DELAY:-0}"
  exit 143
}
trap on_term TERM
node -e 'process.stdout.write(String(Date.now()))' \
  > "$WAVE_TEST_STATE/round-$round-claude.started"
printf '%s\n' "$$" > "$WAVE_TEST_STATE/round-$round-claude.pid"
case "$round" in
  1) delay="${WAVE_TEST_DELAY_1:-0.1}" ;;
  2) delay="${WAVE_TEST_DELAY_2:-0.1}" ;;
  3) delay="${WAVE_TEST_DELAY_3:-0.1}" ;;
  4) delay="${WAVE_TEST_DELAY_4:-0.1}" ;;
  *) delay="0.1" ;;
esac
sleep "$delay"
if [ "${WAVE_TEST_CLAUDE_INFRA_FAIL_ROUND:-}" = "$round" ]; then
  exit 3
fi
if [ "${WAVE_TEST_CLAUDE_FAIL_ROUND:-}" = "$round" ]; then
  printf 'SESSION_ID: fixture-claude-%s\n' "$round"
  exit 6
fi
printf 'SESSION_ID: fixture-claude-%s\n---\nNO_FINDINGS\nscope: fixture\nreason: clean\n' "$round"
SH

cat > "$T/codex-launcher.sh" <<'SH'
#!/usr/bin/env bash
set -eu
prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prompt-template) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
round=$(printf '%s' "$prompt" | sed -E 's/.*round-([0-9]+).*/\1/')
on_term() {
  sleep "${WAVE_TEST_TERM_CLEANUP_DELAY:-0}"
  exit 143
}
trap on_term TERM
node -e 'process.stdout.write(String(Date.now()))' \
  > "$WAVE_TEST_STATE/round-$round-codex.started"
printf '%s\n' "$$" > "$WAVE_TEST_STATE/round-$round-codex.pid"
case "$round" in
  1) delay="${WAVE_TEST_DELAY_1:-0.1}" ;;
  2) delay="${WAVE_TEST_DELAY_2:-0.1}" ;;
  3) delay="${WAVE_TEST_DELAY_3:-0.1}" ;;
  4) delay="${WAVE_TEST_DELAY_4:-0.1}" ;;
  *) delay="0.1" ;;
esac
sleep "$delay"
if [ "${WAVE_TEST_CODEX_INFRA_FAIL_ROUND:-}" = "$round" ]; then
  exit 3
fi
if [ "${WAVE_TEST_CODEX_FAIL_ROUND:-}" = "$round" ]; then
  printf 'THREAD_ID: fixture-codex-%s\n' "$round"
  exit 7
fi
printf 'THREAD_ID: fixture-codex-%s\n---\nNO_FINDINGS\nscope: fixture\nreason: clean\n' "$round"
SH

chmod +x "$T/tooling/scripts/"*.sh "$T/tooling/scripts/"*.mjs \
  "$T/codex-launcher.sh"
printf 'diff\n' > "$T/review.diff"
mkdir "$T/snapshot"

write_context() {
  local artifact="$1" context="$2" run_id="$3"
  mkdir -p "$artifact/phase4/waves"
  jq -n \
    --arg skillDir "$T/tooling" \
    --arg projectRoot "$T/project" \
    --arg reviewTempRoot "$T/temp" \
    --arg reviewArtifactDir "$artifact" \
    --arg codexLauncherPath "$T/codex-launcher.sh" \
    --arg reviewRunId "$run_id" \
    --arg target "branch:fixture" \
    --arg headSha "fixture-head" \
    --arg diffFile "$T/review.diff" \
    --arg diffSha256 "fixture-diff" \
    --arg reviewSnapshotDir "$T/snapshot" \
    --arg snapshotMetadataSha256 "fixture-snapshot" \
    '{skillDir:$skillDir,projectRoot:$projectRoot,
      reviewTempRoot:$reviewTempRoot,reviewArtifactDir:$reviewArtifactDir,
      codexLauncherPath:$codexLauncherPath,reviewRunId:$reviewRunId,
      target:$target,headSha:$headSha,diffFile:$diffFile,
      diffSha256:$diffSha256,reviewSnapshotDir:$reviewSnapshotDir,
      snapshotMetadataSha256:$snapshotMetadataSha256}' > "$context"
}

write_prompt() {
  local context="$1" prompt="$2" reviewer="$3" round="$4"
  printf '%s convergence round %s review prompt\n' "$reviewer" "$round" > "$prompt"
  node --input-type=module - \
    "$T/tooling/scripts/review-prompt-manifest.mjs" \
    "$context" "$prompt" "$reviewer" "$round" <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [modulePath, contextPath, promptPath, reviewer, round] = process.argv.slice(2);
const { createPromptManifest } = await import(pathToFileURL(modulePath));
createPromptManifest({
  context: JSON.parse(readFileSync(contextPath, "utf8")),
  promptPath,
  reviewer,
  phase: "convergence",
  round: Number(round),
  purpose: "review",
});
JS
}

write_resume_prompt() {
  local context="$1" prompt="$2" reviewer="$3" round="$4"
  printf '%s convergence round %s finalize-only prompt\n' \
    "$reviewer" "$round" > "$prompt"
  node --input-type=module - \
    "$T/tooling/scripts/review-prompt-manifest.mjs" \
    "$context" "$prompt" "$reviewer" "$round" <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [modulePath, contextPath, promptPath, reviewer, round] = process.argv.slice(2);
const { createPromptManifest } = await import(pathToFileURL(modulePath));
createPromptManifest({
  context: JSON.parse(readFileSync(contextPath, "utf8")),
  promptPath,
  reviewer,
  phase: "convergence",
  round: Number(round),
  purpose: "resume",
});
JS
}

write_adjudication() {
  local artifact="$1" run_id="$2" round="$3" stable="$4"
  local claude_new=1 changed=true
  if [ "$stable" = "true" ]; then
    claude_new=0
    changed=false
  fi
  mkdir -p "$artifact/phase4/round-$round"
  jq -n \
    --arg reviewRunId "$run_id" \
    --argjson round "$round" \
    --argjson claudeNew "$claude_new" \
    --argjson finalSetChanged "$changed" \
    '{schema:"deep-review-adjudication/v1",reviewRunId:$reviewRunId,
      phase:"convergence",round:$round,
      summary:{reviewersSucceeded:true,claudeNew:$claudeNew,codexNew:0,
        duplicates:0,withdrawn:0,downgraded:0,upgraded:0,unchanged:0,
        finalSetChanged:$finalSetChanged}}' \
    > "$artifact/phase4/round-$round/adjudication.json"
}

wait_for_file() {
  local file="$1" count=0
  while [ ! -f "$file" ] && [ "$count" -lt 1000 ]; do
    sleep 0.01
    count=$((count + 1))
  done
  [ -f "$file" ]
}

wait_for_text() {
  local file="$1" text="$2" count=0
  while { [ ! -f "$file" ] || ! grep -Fq -- "$text" "$file"; } &&
    [ "$count" -lt 1000 ]; do
    sleep 0.01
    count=$((count + 1))
  done
  [ -f "$file" ] && grep -Fq -- "$text" "$file"
}

wait_for_json() {
  local file="$1" expression="$2" count=0
  while { [ ! -f "$file" ] || ! jq -e "$expression" "$file" >/dev/null 2>&1; } &&
    [ "$count" -lt 1000 ]; do
    sleep 0.01
    count=$((count + 1))
  done
  [ -f "$file" ] && jq -e "$expression" "$file" >/dev/null 2>&1
}

prepare_prompts() {
  local context="$1" prefix="$2" first="$3" second="$4"
  write_prompt "$context" "$T/$prefix-claude-round-$first.md" claude "$first"
  write_prompt "$context" "$T/$prefix-codex-round-$first.md" codex "$first"
  write_prompt "$context" "$T/$prefix-claude-round-$second.md" claude "$second"
  write_prompt "$context" "$T/$prefix-codex-round-$second.md" codex "$second"
}

start_wave() {
  local context="$1" prefix="$2" first="$3" output="$4"
  DEEP_REVIEW_TEST_PAIR_POST_FORK_DELAY_SECONDS="${DEEP_REVIEW_TEST_PAIR_POST_FORK_DELAY_SECONDS:-}" \
  DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_ROLE="${DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_ROLE:-}" \
  DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_MARKER_PREFIX="${DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_MARKER_PREFIX:-}" \
  DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_DELAY_SECONDS="${DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_DELAY_SECONDS:-}" \
  DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_ROLE="${DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_ROLE:-}" \
  DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_MARKER_PREFIX="${DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_MARKER_PREFIX:-}" \
  DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_DELAY_SECONDS="${DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_DELAY_SECONDS:-}" \
  DEEP_REVIEW_TEST_WATCHER_PID_PREFIX="${DEEP_REVIEW_TEST_WATCHER_PID_PREFIX:-}" \
  WAVE_TEST_STATE="$T/state" \
    bash "$T/tooling/scripts/run-review-wave.sh" \
      --context "$context" \
      --first-round "$first" \
      --claude-lead-prompt "$T/$prefix-claude-round-$first.md" \
      --codex-lead-prompt "$T/$prefix-codex-round-$first.md" \
      --claude-speculative-prompt "$T/$prefix-claude-round-$((first + 1)).md" \
      --codex-speculative-prompt "$T/$prefix-codex-round-$((first + 1)).md" \
      > "$output" 2>&1 &
  STARTED_WAVE_PID=$!
}

promote_first_wave() {
  local artifact="$1" context="$2" prefix="$3" run_id="$4"
  local wave_pid wave_status
  prepare_prompts "$context" "$prefix" 1 2
  WAVE_TEST_DELAY_1=0.1 WAVE_TEST_DELAY_2=0.1
  unset WAVE_TEST_CLAUDE_FAIL_ROUND WAVE_TEST_CODEX_FAIL_ROUND
  export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
  start_wave "$context" "$prefix" 1 "$T/$prefix-first-wave.out"
  wave_pid=$STARTED_WAVE_PID
  wave_status="$artifact/phase4/waves/wave-1-2/status.json"
  wait_for_json "$wave_status" '.lead.process.finishedAt != null' || return 1
  write_adjudication "$artifact" "$run_id" 1 false
  bash "$T/tooling/scripts/control-review-wave.sh" \
    --context "$context" --wave-status "$wave_status" \
    --action promote > "$T/$prefix-first-control.out" || return 1
  wait "$wave_pid"
}

inspect_waves() {
  local context="$1" artifact="$2"
  node --input-type=module - \
    "$T/tooling/scripts/review-wave-state.mjs" "$context" "$artifact" <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [modulePath, contextPath, artifactDirectory] = process.argv.slice(2);
const { inspectReviewWaves } = await import(pathToFileURL(modulePath));
const result = inspectReviewWaves({
  context: JSON.parse(readFileSync(contextPath, "utf8")),
  artifactDirectory,
});
process.stdout.write(`${JSON.stringify(result.canonicalRounds)}\n`);
JS
}

echo "== W00: only a reserved wave can start a new convergence round =="
ARTIFACT_GATE="$T/artifact-gate"
CONTEXT_GATE="$T/context-gate.json"
write_context "$ARTIFACT_GATE" "$CONTEXT_GATE" wave-gate
prepare_prompts "$CONTEXT_GATE" gate 1 2
node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_GATE" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/gate-claude-round-1.md" \
  --codex-lead-prompt "$T/gate-codex-round-1.md" \
  --claude-speculative-prompt "$T/gate-claude-round-2.md" \
  --codex-speculative-prompt "$T/gate-codex-round-2.md" \
  > "$T/gate-reservation.json"
node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_GATE" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/gate-claude-round-1.md" \
  --codex-lead-prompt "$T/gate-codex-round-1.md" \
  --claude-speculative-prompt "$T/gate-claude-round-2.md" \
  --codex-speculative-prompt "$T/gate-codex-round-2.md" \
  > "$T/gate-duplicate-reservation.out" 2>&1
check "$?" "1" "an active supervisor prevents duplicate wave attachment"
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_GATE" \
    --claude-prompt "$T/gate-claude-round-1.md" \
    --codex-prompt "$T/gate-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    > "$T/unreserved-wave.out" 2>&1
check "$?" "2" "wave-enabled run rejects an unreserved canonical attempt"
printf '{}\n' > "$ARTIFACT_GATE/phase4/waves/untrusted-status.json"
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_GATE" \
    --claude-prompt "$T/gate-claude-round-2.md" \
    --codex-prompt "$T/gate-codex-round-2.md" \
    --phase convergence --round 2 --reviewer both --attempt 1 \
    --wave-status "$ARTIFACT_GATE/phase4/waves/untrusted-status.json" \
    --wave-role speculative > "$T/untrusted-wave.out" 2>&1
check "$?" "2" "untrusted status cannot authorize speculative execution"
if [ ! -e "$ARTIFACT_GATE/phase4/round-1" ] &&
  [ ! -e "$ARTIFACT_GATE/phase4/round-2" ]; then
  ok "rejected wave bypasses create no canonical artifact"
else
  ng "rejected wave bypasses create no canonical artifact"
fi

echo "== W00b: an empty wave directory preserves sequential compatibility =="
ARTIFACT_SEQUENTIAL="$T/artifact-sequential"
CONTEXT_SEQUENTIAL="$T/context-sequential.json"
write_context "$ARTIFACT_SEQUENTIAL" "$CONTEXT_SEQUENTIAL" wave-sequential
prepare_prompts "$CONTEXT_SEQUENTIAL" sequential 1 2
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_SEQUENTIAL" \
    --claude-prompt "$T/sequential-claude-round-1.md" \
    --codex-prompt "$T/sequential-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    > "$T/sequential-wave.out" 2>&1
check "$?" "0" "initialized runs retain the existing sequential Round 1 path"
check "$(jq -r .mode "$ARTIFACT_SEQUENTIAL/phase4/execution-mode.json")" \
  "sequential" "sequential execution fixes its Phase 4 mode"

echo "== W00c: sequential start and wave reservation share one atomic mode =="
MODE_RACE_OK=true
for race in 1 2 3 4 5 6 7 8; do
  artifact_race="$T/artifact-mode-race-$race"
  context_race="$T/context-mode-race-$race.json"
  prefix_race="mode-race-$race"
  write_context "$artifact_race" "$context_race" "wave-mode-race-$race"
  prepare_prompts "$context_race" "$prefix_race" 1 2
  node "$T/tooling/scripts/review-wave-state.mjs" claim-sequential \
    --context "$context_race" > "$T/$prefix_race-sequential.out" 2>&1 &
  sequential_pid=$!
  node "$T/tooling/scripts/review-wave-state.mjs" reserve \
    --context "$context_race" --first-round 1 \
    --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
    --claude-lead-prompt "$T/$prefix_race-claude-round-1.md" \
    --codex-lead-prompt "$T/$prefix_race-codex-round-1.md" \
    --claude-speculative-prompt "$T/$prefix_race-claude-round-2.md" \
    --codex-speculative-prompt "$T/$prefix_race-codex-round-2.md" \
    > "$T/$prefix_race-wave.out" 2>&1 &
  reserve_pid=$!
  wait "$sequential_pid"; sequential_rc=$?
  wait "$reserve_pid"; reserve_rc=$?
  success_count=0
  if [ "$sequential_rc" -eq 0 ]; then success_count=$((success_count + 1)); fi
  if [ "$reserve_rc" -eq 0 ]; then success_count=$((success_count + 1)); fi
  if [ "$success_count" -eq 1 ]; then
    mode=$(jq -r .mode "$artifact_race/phase4/execution-mode.json")
    if { [ "$sequential_rc" -eq 0 ] && [ "$mode" != "sequential" ]; } ||
      { [ "$reserve_rc" -eq 0 ] && [ "$mode" != "wave" ]; }; then
      MODE_RACE_OK=false
    fi
  else
    MODE_RACE_OK=false
  fi
done
if $MODE_RACE_OK; then
  ok "concurrent sequential and wave claims produce exactly one execution mode"
else
  ng "concurrent sequential and wave claims produce exactly one execution mode"
fi

echo "== W00d: concurrent contenders recover one abandoned lock safely =="
ARTIFACT_LOCK_RACE="$T/artifact-lock-race"
CONTEXT_LOCK_RACE="$T/context-lock-race.json"
write_context "$ARTIFACT_LOCK_RACE" "$CONTEXT_LOCK_RACE" wave-lock-race
prepare_prompts "$CONTEXT_LOCK_RACE" lock-race 1 2
LOCK_RESERVATION=$(node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_LOCK_RACE" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/lock-race-claude-round-1.md" \
  --codex-lead-prompt "$T/lock-race-codex-round-1.md" \
  --claude-speculative-prompt "$T/lock-race-claude-round-2.md" \
  --codex-speculative-prompt "$T/lock-race-codex-round-2.md")
LOCK_RACE_STATUS=$(printf '%s' "$LOCK_RESERVATION" | jq -r .statusPath)
jq -n \
  --arg nonce "abandoned-lock" \
  '{schema:"deep-review-wave-lock/v1",pid:99999999,
    nonce:$nonce,createdAt:"2026-08-10T00:00:00.000Z"}' \
  > "$LOCK_RACE_STATUS.lock"
lock_race_pids=()
for contender in 1 2 3 4 5 6 7 8; do
  node "$T/tooling/scripts/review-wave-state.mjs" record-start \
    --context "$CONTEXT_LOCK_RACE" --status "$LOCK_RACE_STATUS" \
    --role lead --pid "$((5000 + contender))" \
    > "$T/lock-race-$contender.out" 2>&1 &
  lock_race_pids+=("$!")
done
lock_race_success=0
for contender_pid in "${lock_race_pids[@]}"; do
  if wait "$contender_pid"; then
    lock_race_success=$((lock_race_success + 1))
  fi
done
if [ "$lock_race_success" -eq 1 ] &&
  [ "$(jq -r .revision "$LOCK_RACE_STATUS")" = "2" ] &&
  [ ! -e "$LOCK_RACE_STATUS.lock" ] &&
  [ ! -e "$LOCK_RACE_STATUS.lock.recovery" ]; then
  ok "one contender updates state after dead lock and reaper recovery"
else
  ng "one contender updates state after dead lock and reaper recovery"
fi

echo "== W00e: abandoned recovery ownership fails closed =="
ARTIFACT_STALE_REAPER="$T/artifact-stale-reaper"
CONTEXT_STALE_REAPER="$T/context-stale-reaper.json"
write_context "$ARTIFACT_STALE_REAPER" "$CONTEXT_STALE_REAPER" wave-stale-reaper
prepare_prompts "$CONTEXT_STALE_REAPER" stale-reaper 1 2
STALE_REAPER_RESERVATION=$(node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_STALE_REAPER" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/stale-reaper-claude-round-1.md" \
  --codex-lead-prompt "$T/stale-reaper-codex-round-1.md" \
  --claude-speculative-prompt "$T/stale-reaper-claude-round-2.md" \
  --codex-speculative-prompt "$T/stale-reaper-codex-round-2.md")
STALE_REAPER_STATUS=$(printf '%s' "$STALE_REAPER_RESERVATION" | jq -r .statusPath)
jq -n \
  --arg nonce "abandoned-reaper" \
  '{schema:"deep-review-wave-lock/v1",pid:99999999,
    nonce:$nonce,createdAt:"2026-08-10T00:00:00.000Z"}' \
  > "$STALE_REAPER_STATUS.lock.recovery"
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_STALE_REAPER" --status "$STALE_REAPER_STATUS" \
  --role lead --pid 6001 > "$T/stale-reaper.out" 2>&1
STALE_REAPER_RC=$?
check "$STALE_REAPER_RC" "1" \
  "a dead recovery owner is not reclaimed recursively"
if [ "$(jq -r .revision "$STALE_REAPER_STATUS")" = "1" ] &&
  [ "$(jq -r .lead.process.startedAt "$STALE_REAPER_STATUS")" = "null" ] &&
  [[ $(< "$T/stale-reaper.out") == *"requires manual verification"* ]]; then
  ok "stale recovery ownership preserves state and requests manual verification"
else
  ng "stale recovery ownership preserves state and requests manual verification"
fi
rm "$STALE_REAPER_STATUS.lock.recovery"
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_STALE_REAPER" --status "$STALE_REAPER_STATUS" \
  --role lead --pid 6001 > "$T/stale-reaper-after-cleanup.out" 2>&1
check "$?" "0" "verified manual recovery permits the state update"

echo "== W00f: incomplete reservations remain hidden and final reservation is atomic =="
ARTIFACT_RESERVE_RACE="$T/artifact-reserve-race"
CONTEXT_RESERVE_RACE="$T/context-reserve-race.json"
write_context "$ARTIFACT_RESERVE_RACE" "$CONTEXT_RESERVE_RACE" wave-reserve-race
prepare_prompts "$CONTEXT_RESERVE_RACE" reserve-race 1 2
mkdir "$ARTIFACT_RESERVE_RACE/phase4/waves/.wave-1-2.reserving-99999999-deadbeef"
reserve_race_pids=()
for contender in 1 2 3 4 5 6 7 8; do
  node "$T/tooling/scripts/review-wave-state.mjs" reserve \
    --context "$CONTEXT_RESERVE_RACE" --first-round 1 \
    --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
    --claude-lead-prompt "$T/reserve-race-claude-round-1.md" \
    --codex-lead-prompt "$T/reserve-race-codex-round-1.md" \
    --claude-speculative-prompt "$T/reserve-race-claude-round-2.md" \
    --codex-speculative-prompt "$T/reserve-race-codex-round-2.md" \
    > "$T/reserve-race-$contender.out" 2>&1 &
  reserve_race_pids+=("$!")
done
reserve_race_success=0
for contender_pid in "${reserve_race_pids[@]}"; do
  if wait "$contender_pid"; then
    reserve_race_success=$((reserve_race_success + 1))
  fi
done
RESERVE_RACE_STATUS="$ARTIFACT_RESERVE_RACE/phase4/waves/wave-1-2/status.json"
if [ "$reserve_race_success" -eq 1 ] &&
  jq -e '
    .schema == "deep-review-wave/v1" and
    .revision == 1 and
    .firstRound == 1 and
    .speculativeRound == 2
  ' "$RESERVE_RACE_STATUS" >/dev/null; then
  ok "concurrent reservation publishes exactly one complete wave atomically"
else
  ng "concurrent reservation publishes exactly one complete wave atomically"
fi

echo "== W00g: a rejected sequential round does not poison execution mode =="
ARTIFACT_INVALID_SEQUENTIAL="$T/artifact-invalid-sequential"
CONTEXT_INVALID_SEQUENTIAL="$T/context-invalid-sequential.json"
write_context \
  "$ARTIFACT_INVALID_SEQUENTIAL" "$CONTEXT_INVALID_SEQUENTIAL" \
  wave-invalid-sequential
prepare_prompts "$CONTEXT_INVALID_SEQUENTIAL" invalid-sequential 1 2
node "$T/tooling/scripts/review-wave-state.mjs" authorize-sequential \
  --context "$CONTEXT_INVALID_SEQUENTIAL" --round 2 \
  > "$T/invalid-sequential.out" 2>&1
check "$?" "1" "a non-next sequential round is rejected"
if [ ! -e "$ARTIFACT_INVALID_SEQUENTIAL/phase4/execution-mode.json" ]; then
  ok "a rejected sequential round leaves Phase 4 execution mode unclaimed"
else
  ng "a rejected sequential round leaves Phase 4 execution mode unclaimed"
fi
node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_INVALID_SEQUENTIAL" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/invalid-sequential-claude-round-1.md" \
  --codex-lead-prompt "$T/invalid-sequential-codex-round-1.md" \
  --claude-speculative-prompt "$T/invalid-sequential-claude-round-2.md" \
  --codex-speculative-prompt "$T/invalid-sequential-codex-round-2.md" \
  > "$T/invalid-sequential-wave.out" 2>&1
check "$?" "0" "wave execution remains selectable after the rejected round"

echo "== W00h: an unstarted reservation can attach to a replacement supervisor =="
ARTIFACT_REATTACH="$T/artifact-reattach"
CONTEXT_REATTACH="$T/context-reattach.json"
write_context "$ARTIFACT_REATTACH" "$CONTEXT_REATTACH" wave-reattach
prepare_prompts "$CONTEXT_REATTACH" reattach 1 2
node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_REATTACH" --first-round 1 \
  --claude-lead-prompt "$T/reattach-claude-round-1.md" \
  --codex-lead-prompt "$T/reattach-codex-round-1.md" \
  --claude-speculative-prompt "$T/reattach-claude-round-2.md" \
  --codex-speculative-prompt "$T/reattach-codex-round-2.md" \
  --supervisor-pid 99999999 > "$T/reattach-abandoned-reservation.json"
REATTACH_STATUS="$ARTIFACT_REATTACH/phase4/waves/wave-1-2/status.json"
if jq -e '
  .revision == 1 and
  .lead.state == "reserved" and
  .speculative.state == "reserved"
' "$REATTACH_STATUS" >/dev/null; then
  ok "abandoned reservation remains complete and unstarted"
else
  ng "abandoned reservation remains complete and unstarted"
fi
WAVE_TEST_DELAY_1=0.1 WAVE_TEST_DELAY_2=0.1
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
start_wave "$CONTEXT_REATTACH" reattach 1 "$T/wave-reattach.out"
WAVE_PID=$STARTED_WAVE_PID
wait_for_json "$REATTACH_STATUS" '.lead.process.finishedAt != null' || true
write_adjudication "$ARTIFACT_REATTACH" wave-reattach 1 false
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_REATTACH" --wave-status "$REATTACH_STATUS" \
  --action promote > "$T/control-reattach.out"
wait "$WAVE_PID"
check "$?" "0" "replacement supervisor completes the abandoned wave"
check "$(jq -r .speculative.state "$REATTACH_STATUS")" "promoted" \
  "replacement supervisor preserves normal promotion semantics"

echo "== W00i: completed pair artifacts recover after supervisor loss =="
ARTIFACT_RECONCILE="$T/artifact-reconcile"
CONTEXT_RECONCILE="$T/context-reconcile.json"
write_context "$ARTIFACT_RECONCILE" "$CONTEXT_RECONCILE" wave-reconcile
prepare_prompts "$CONTEXT_RECONCILE" reconcile 1 2
RECONCILE_RESERVATION=$(node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_RECONCILE" --first-round 1 \
  --supervisor-pid 99999999 \
  --claude-lead-prompt "$T/reconcile-claude-round-1.md" \
  --codex-lead-prompt "$T/reconcile-codex-round-1.md" \
  --claude-speculative-prompt "$T/reconcile-claude-round-2.md" \
  --codex-speculative-prompt "$T/reconcile-codex-round-2.md")
RECONCILE_STATUS=$(printf '%s' "$RECONCILE_RESERVATION" | jq -r .statusPath)
RECONCILE_NONCE=$(printf '%s' "$RECONCILE_RESERVATION" |
  jq -r .status.supervisor.nonce)
unset WAVE_TEST_CLAUDE_FAIL_ROUND WAVE_TEST_CODEX_FAIL_ROUND
WAVE_TEST_DELAY_1=0.1 WAVE_TEST_DELAY_2=0.1
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_RECONCILE" \
    --claude-prompt "$T/reconcile-claude-round-1.md" \
    --codex-prompt "$T/reconcile-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    --wave-status "$RECONCILE_STATUS" --wave-role lead \
    --wave-supervisor-nonce "$RECONCILE_NONCE" \
    > "$T/reconcile-lead.out" 2>&1 &
RECONCILE_LEAD_PID=$!
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_RECONCILE" \
    --claude-prompt "$T/reconcile-claude-round-2.md" \
    --codex-prompt "$T/reconcile-codex-round-2.md" \
    --phase convergence --round 2 --reviewer both --attempt 1 \
    --wave-status "$RECONCILE_STATUS" --wave-role speculative \
    --wave-supervisor-nonce "$RECONCILE_NONCE" \
    > "$T/reconcile-speculative.out" 2>&1 &
RECONCILE_SPECULATIVE_PID=$!
wait_for_json "$RECONCILE_STATUS" '
  .lead.process.startedAt != null and
  .speculative.process.startedAt != null
' || true
node "$T/tooling/scripts/review-wave-state.mjs" mark-reviewers-ready \
  --context "$CONTEXT_RECONCILE" --status "$RECONCILE_STATUS" \
  --supervisor-nonce "$RECONCILE_NONCE" \
  > "$T/reconcile-reviewers-ready.out"
wait "$RECONCILE_LEAD_PID"
check "$?" "0" "lead pair completes without its original supervisor"
wait "$RECONCILE_SPECULATIVE_PID"
check "$?" "0" "speculative pair completes without its original supervisor"
write_adjudication "$ARTIFACT_RECONCILE" wave-reconcile 1 false
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_RECONCILE" --wave-status "$RECONCILE_STATUS" \
  --action promote > "$T/control-reconcile.out"
if jq -e '
  .lead.process.finishedAt != null and
  .lead.process.exitCode == 0 and
  .lead.process.exitCodeSource == "process" and
  .lead.executionEvidence.complete == true and
  .speculative.process.finishedAt != null and
  .speculative.process.exitCode == 0 and
  .speculative.process.exitCodeSource == "process" and
  .speculative.executionEvidence.complete == true and
  .speculative.state == "promoted"
' "$RECONCILE_STATUS" >/dev/null; then
  ok "pair children preserve complete wave evidence after supervisor loss"
else
  ng "pair children preserve complete wave evidence after supervisor loss"
fi
check "$(inspect_waves "$CONTEXT_RECONCILE" "$ARTIFACT_RECONCILE")" \
  "[1,2]" "supervisor-loss recovery preserves canonical round order"
jq 'del(.revision, .updatedAt)' "$RECONCILE_STATUS" \
  > "$T/reconcile-before-repeat.json"
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_RECONCILE" --wave-status "$RECONCILE_STATUS" \
  --action promote > "$T/control-reconcile-repeat.out"
jq 'del(.revision, .updatedAt)' "$RECONCILE_STATUS" \
  > "$T/reconcile-after-repeat.json"
if cmp -s "$T/reconcile-before-repeat.json" "$T/reconcile-after-repeat.json"; then
  ok "repeating the same decision is semantically idempotent"
else
  ng "repeating the same decision is semantically idempotent"
fi
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_RECONCILE" --wave-status "$RECONCILE_STATUS" \
  --action converge > "$T/control-reconcile-conflict.out" 2>&1
check "$?" "1" "a different action cannot replace the fixed decision"
cp "$RECONCILE_STATUS" "$T/reconcile-before-late-result.json"
node "$T/tooling/scripts/review-wave-state.mjs" record-result \
  --context "$CONTEXT_RECONCILE" --status "$RECONCILE_STATUS" \
  --role speculative --exit-code 1 \
  > "$T/reconcile-late-result.out" 2>&1
check "$?" "1" "recovered process result rejects a delayed writer"
if cmp -s "$T/reconcile-before-late-result.json" "$RECONCILE_STATUS"; then
  ok "recovered terminal evidence remains immutable"
else
  ng "recovered terminal evidence remains immutable"
fi

echo "== W00ia: supervisor-loss reconstruction preserves exit 3 =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_INFRA_RECONSTRUCT="$T/artifact-infra-reconstruct"
CONTEXT_INFRA_RECONSTRUCT="$T/context-infra-reconstruct.json"
write_context \
  "$ARTIFACT_INFRA_RECONSTRUCT" "$CONTEXT_INFRA_RECONSTRUCT" \
  wave-infra-reconstruct
prepare_prompts "$CONTEXT_INFRA_RECONSTRUCT" infra-reconstruct 1 2
INFRA_RECONSTRUCT_RESERVATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_INFRA_RECONSTRUCT" --first-round 1 \
  --supervisor-pid 99999999 \
  --claude-lead-prompt "$T/infra-reconstruct-claude-round-1.md" \
  --codex-lead-prompt "$T/infra-reconstruct-codex-round-1.md" \
  --claude-speculative-prompt "$T/infra-reconstruct-claude-round-2.md" \
  --codex-speculative-prompt "$T/infra-reconstruct-codex-round-2.md")
INFRA_RECONSTRUCT_STATUS=$(printf '%s' "$INFRA_RECONSTRUCT_RESERVATION" |
  jq -r .statusPath)
INFRA_RECONSTRUCT_OLD_NONCE=$(printf '%s' "$INFRA_RECONSTRUCT_RESERVATION" |
  jq -r .status.supervisor.nonce)
mkdir -p "$T/policy-node-bin"
cat > "$T/policy-node-bin/node" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = "$WAVE_TEST_PAIR_POLICY_PATH" ] &&
  [ "${2:-}" = "exit-code" ]; then
  : > "$WAVE_TEST_POLICY_MARKER"
  sleep 5
fi
exec "$WAVE_TEST_REAL_NODE" "$@"
SH
chmod +x "$T/policy-node-bin/node"
WAVE_TEST_CLAUDE_INFRA_FAIL_ROUND=1
export WAVE_TEST_CLAUDE_INFRA_FAIL_ROUND
WAVE_TEST_REAL_NODE="$(command -v node)" \
WAVE_TEST_PAIR_POLICY_PATH="$T/tooling/scripts/review-pair-policy.mjs" \
WAVE_TEST_POLICY_MARKER="$T/infra-reconstruct-policy.ready" \
PATH="$T/policy-node-bin:$PATH" WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_INFRA_RECONSTRUCT" \
    --claude-prompt "$T/infra-reconstruct-claude-round-1.md" \
    --codex-prompt "$T/infra-reconstruct-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    --wave-status "$INFRA_RECONSTRUCT_STATUS" --wave-role lead \
    --wave-supervisor-nonce "$INFRA_RECONSTRUCT_OLD_NONCE" \
    > "$T/infra-reconstruct-lead.out" 2>&1 &
INFRA_RECONSTRUCT_LEAD_PID=$!
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_INFRA_RECONSTRUCT" \
    --claude-prompt "$T/infra-reconstruct-claude-round-2.md" \
    --codex-prompt "$T/infra-reconstruct-codex-round-2.md" \
    --phase convergence --round 2 --reviewer both --attempt 1 \
    --wave-status "$INFRA_RECONSTRUCT_STATUS" --wave-role speculative \
    --wave-supervisor-nonce "$INFRA_RECONSTRUCT_OLD_NONCE" \
    > "$T/infra-reconstruct-speculative.out" 2>&1 &
INFRA_RECONSTRUCT_SPECULATIVE_PID=$!
wait_for_json "$INFRA_RECONSTRUCT_STATUS" '
  .lead.process.startedAt != null and
  .speculative.process.startedAt != null
' || true
node "$T/tooling/scripts/review-wave-state.mjs" mark-reviewers-ready \
  --context "$CONTEXT_INFRA_RECONSTRUCT" \
  --status "$INFRA_RECONSTRUCT_STATUS" \
  --supervisor-nonce "$INFRA_RECONSTRUCT_OLD_NONCE" \
  > "$T/infra-reconstruct-reviewers-ready.out"
wait_for_file "$T/infra-reconstruct-policy.ready" || true
kill -KILL "$INFRA_RECONSTRUCT_LEAD_PID" 2>/dev/null || true
wait "$INFRA_RECONSTRUCT_LEAD_PID" 2>/dev/null
check "$?" "137" "fixture loses the lead wrapper after pair status publication"
unset WAVE_TEST_CLAUDE_INFRA_FAIL_ROUND
wait "$INFRA_RECONSTRUCT_SPECULATIVE_PID"
check "$?" "0" "speculative peer completes before reconstruction"
INFRA_RECONSTRUCT_REATTACH=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_INFRA_RECONSTRUCT" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/infra-reconstruct-claude-round-1.md" \
  --codex-lead-prompt "$T/infra-reconstruct-codex-round-1.md" \
  --claude-speculative-prompt "$T/infra-reconstruct-claude-round-2.md" \
  --codex-speculative-prompt "$T/infra-reconstruct-codex-round-2.md")
INFRA_RECONSTRUCT_NEW_NONCE=$(printf '%s' "$INFRA_RECONSTRUCT_REATTACH" |
  jq -r .status.supervisor.nonce)
node "$T/tooling/scripts/review-wave-state.mjs" recover-role \
  --context "$CONTEXT_INFRA_RECONSTRUCT" \
  --status "$INFRA_RECONSTRUCT_STATUS" --role lead \
  --supervisor-nonce "$INFRA_RECONSTRUCT_NEW_NONCE" \
  > "$T/infra-reconstruct-recovered.out"
if jq -e '
  .lead.process.exitCode == 3 and
  .lead.process.exitCodeSource == "reconstructed" and
  .lead.executionEvidence.complete == true
' "$INFRA_RECONSTRUCT_STATUS" >/dev/null; then
  ok "supervisor-loss reconstruction retains infrastructure exit 3"
else
  ng "supervisor-loss reconstruction retains infrastructure exit 3"
fi

echo "== W00j: a superseded child loses the atomic role launch claim =="
ARTIFACT_CLAIM="$T/artifact-claim"
CONTEXT_CLAIM="$T/context-claim.json"
write_context "$ARTIFACT_CLAIM" "$CONTEXT_CLAIM" wave-claim
prepare_prompts "$CONTEXT_CLAIM" claim 1 2
CLAIM_OLD=$(node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_CLAIM" --first-round 1 \
  --supervisor-pid 99999999 \
  --claude-lead-prompt "$T/claim-claude-round-1.md" \
  --codex-lead-prompt "$T/claim-codex-round-1.md" \
  --claude-speculative-prompt "$T/claim-claude-round-2.md" \
  --codex-speculative-prompt "$T/claim-codex-round-2.md")
CLAIM_STATUS=$(printf '%s' "$CLAIM_OLD" | jq -r .statusPath)
CLAIM_OLD_NONCE=$(printf '%s' "$CLAIM_OLD" | jq -r .status.supervisor.nonce)
CLAIM_NEW=$(node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_CLAIM" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/claim-claude-round-1.md" \
  --codex-lead-prompt "$T/claim-codex-round-1.md" \
  --claude-speculative-prompt "$T/claim-claude-round-2.md" \
  --codex-speculative-prompt "$T/claim-codex-round-2.md")
CLAIM_NEW_NONCE=$(printf '%s' "$CLAIM_NEW" | jq -r .status.supervisor.nonce)
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_CLAIM" \
    --claude-prompt "$T/claim-claude-round-1.md" \
    --codex-prompt "$T/claim-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    --wave-status "$CLAIM_STATUS" --wave-role lead \
    --wave-supervisor-nonce "$CLAIM_OLD_NONCE" \
    > "$T/claim-stale.out" 2>&1
check "$?" "2" "a delayed child from the old supervisor is rejected before launch"
if [ ! -e "$ARTIFACT_CLAIM/phase4/round-1" ]; then
  ok "the rejected stale child creates no role artifact"
else
  ng "the rejected stale child creates no role artifact"
fi
WAVE_TEST_DELAY_1=0.1 WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_CLAIM" \
    --claude-prompt "$T/claim-claude-round-1.md" \
    --codex-prompt "$T/claim-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    --wave-status "$CLAIM_STATUS" --wave-role lead \
    --wave-supervisor-nonce "$CLAIM_NEW_NONCE" \
    > "$T/claim-current.out" 2>&1 &
CLAIM_CURRENT_PID=$!
wait_for_json "$CLAIM_STATUS" '.lead.process.startedAt != null' || true
write_adjudication "$ARTIFACT_CLAIM" wave-claim 1 false
node "$T/tooling/scripts/review-wave-state.mjs" decide \
  --context "$CONTEXT_CLAIM" --status "$CLAIM_STATUS" \
  --action promote > "$T/claim-early-decision.out" 2>&1
check "$?" "1" "a decision is rejected until every role claim is durable"
check "$(jq -r .decision "$CLAIM_STATUS")" "null" \
  "a rejected early decision leaves the wave attachable"
node "$T/tooling/scripts/review-wave-state.mjs" authorize \
  --context "$CONTEXT_CLAIM" --status "$CLAIM_STATUS" \
  --role speculative --round 2 --attempt 1 --reviewer both \
  --supervisor-nonce "$CLAIM_NEW_NONCE" \
  --process-pid "$WAVE_TEST_SUPERVISOR_PID" --signal-pid "$$" \
  --claude-prompt "$T/claim-claude-round-2.md" \
  --claude-prompt-purpose review \
  --codex-prompt "$T/claim-codex-round-2.md" \
  --codex-prompt-purpose review > "$T/claim-speculative-authorize.out"
node "$T/tooling/scripts/review-wave-state.mjs" mark-reviewers-ready \
  --context "$CONTEXT_CLAIM" --status "$CLAIM_STATUS" \
  --supervisor-nonce "$CLAIM_NEW_NONCE" \
  > "$T/claim-reviewers-ready.out"
wait "$CLAIM_CURRENT_PID"
check "$?" "0" "the replacement supervisor claims and launches the role once"
node "$T/tooling/scripts/review-wave-state.mjs" request-termination \
  --context "$CONTEXT_CLAIM" --status "$CLAIM_STATUS" \
  --signal TERM --supervisor-nonce "$CLAIM_NEW_NONCE" \
  > "$T/claim-termination.out"
CLAIM_LAUNCH_AUTHORIZATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" authorize-reviewers \
  --context "$CONTEXT_CLAIM" --status "$CLAIM_STATUS" \
  --role speculative --supervisor-nonce "$CLAIM_NEW_NONCE" \
  --process-pid "$WAVE_TEST_SUPERVISOR_PID")
check "$(printf '%s' "$CLAIM_LAUNCH_AUTHORIZATION" | jq -r .authorized)" \
  "false" "termination intent wins atomically before external reviewer launch"
check "$(jq -r '.speculative.process.reviewersAuthorizedAt' "$CLAIM_STATUS")" \
  "null" "cancelled pre-launch role never receives reviewer authorization"

echo "== W00ja: pre-launch termination finalizes without external CLI startup =="
rm -f "$T/state/round-2-"*.started
ARTIFACT_PRELAUNCH="$T/artifact-prelaunch"
CONTEXT_PRELAUNCH="$T/context-prelaunch.json"
write_context "$ARTIFACT_PRELAUNCH" "$CONTEXT_PRELAUNCH" wave-prelaunch
prepare_prompts "$CONTEXT_PRELAUNCH" prelaunch 1 2
PRELAUNCH_RESERVATION=$(node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_PRELAUNCH" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/prelaunch-claude-round-1.md" \
  --codex-lead-prompt "$T/prelaunch-codex-round-1.md" \
  --claude-speculative-prompt "$T/prelaunch-claude-round-2.md" \
  --codex-speculative-prompt "$T/prelaunch-codex-round-2.md")
PRELAUNCH_STATUS=$(printf '%s' "$PRELAUNCH_RESERVATION" | jq -r .statusPath)
PRELAUNCH_NONCE=$(printf '%s' "$PRELAUNCH_RESERVATION" |
  jq -r .status.supervisor.nonce)
WAVE_TEST_VERIFY_DELAY=1 WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_PRELAUNCH" \
    --claude-prompt "$T/prelaunch-claude-round-2.md" \
    --codex-prompt "$T/prelaunch-codex-round-2.md" \
    --phase convergence --round 2 --reviewer both --attempt 1 \
    --wave-status "$PRELAUNCH_STATUS" --wave-role speculative \
    --wave-supervisor-nonce "$PRELAUNCH_NONCE" \
    > "$T/prelaunch-pair.out" 2>&1 &
PRELAUNCH_PAIR_PID=$!
wait_for_json "$PRELAUNCH_STATUS" \
  '.speculative.process.startedAt != null' || true
node "$T/tooling/scripts/review-wave-state.mjs" request-termination \
  --context "$CONTEXT_PRELAUNCH" --status "$PRELAUNCH_STATUS" \
  --signal TERM --supervisor-nonce "$PRELAUNCH_NONCE" \
  > "$T/prelaunch-termination.out"
wait "$PRELAUNCH_PAIR_PID"
check "$?" "143" "pre-launch termination propagates through the pair owner"
if [ ! -e "$T/state/round-2-claude.started" ] &&
  [ ! -e "$T/state/round-2-codex.started" ]; then
  ok "fixed pre-launch cancellation starts neither external reviewer"
else
  ng "fixed pre-launch cancellation starts neither external reviewer"
fi
if jq -e '
  .speculative.process.reviewersAuthorizedAt == null and
  .speculative.process.finishedAt != null and
  .speculative.process.exitCode == 143 and
  .speculative.process.exitCodeSource == "process" and
  .speculative.process.signal == "TERM" and
  .speculative.executionEvidence.complete == true
' "$PRELAUNCH_STATUS" >/dev/null &&
  jq -e '
    .attempts[0].interrupted == true and
    .attempts[0].claude.launched == false and
    .attempts[0].codex.launched == false
  ' "$ARTIFACT_PRELAUNCH/phase4/waves/wave-1-2/speculative-round-2/status.json" \
  >/dev/null; then
  ok "pre-launch cancellation publishes complete interrupted evidence"
else
  ng "pre-launch cancellation publishes complete interrupted evidence"
fi

echo "== W00k: a partial wave attaches and starts only its missing role =="
ARTIFACT_PARTIAL="$T/artifact-partial"
CONTEXT_PARTIAL="$T/context-partial.json"
write_context "$ARTIFACT_PARTIAL" "$CONTEXT_PARTIAL" wave-partial
prepare_prompts "$CONTEXT_PARTIAL" partial 1 2
sleep 30 &
PARTIAL_OLD_SUPERVISOR=$!
PARTIAL_OLD_NATIVE_PID=$PARTIAL_OLD_SUPERVISOR
case "$OSTYPE" in
  msys*|cygwin*)
    PARTIAL_OLD_NATIVE_PID=$(sed -n '1p' \
      "/proc/$PARTIAL_OLD_SUPERVISOR/winpid" 2>/dev/null) ||
      PARTIAL_OLD_NATIVE_PID=""
    ;;
esac
PARTIAL_RESERVATION=$(node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_PARTIAL" --first-round 1 \
  --supervisor-pid "$PARTIAL_OLD_NATIVE_PID" \
  --claude-lead-prompt "$T/partial-claude-round-1.md" \
  --codex-lead-prompt "$T/partial-codex-round-1.md" \
  --claude-speculative-prompt "$T/partial-claude-round-2.md" \
  --codex-speculative-prompt "$T/partial-codex-round-2.md")
PARTIAL_STATUS=$(printf '%s' "$PARTIAL_RESERVATION" | jq -r .statusPath)
PARTIAL_OLD_NONCE=$(printf '%s' "$PARTIAL_RESERVATION" |
  jq -r .status.supervisor.nonce)
WAVE_TEST_DELAY_1=0.6 WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_PARTIAL" \
    --claude-prompt "$T/partial-claude-round-1.md" \
    --codex-prompt "$T/partial-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    --wave-status "$PARTIAL_STATUS" --wave-role lead \
    --wave-supervisor-nonce "$PARTIAL_OLD_NONCE" \
    > "$T/partial-existing-lead.out" 2>&1 &
PARTIAL_LEAD_PID=$!
wait_for_json "$PARTIAL_STATUS" '.lead.state == "running"' || true
kill "$PARTIAL_OLD_SUPERVISOR" 2>/dev/null || true
wait "$PARTIAL_OLD_SUPERVISOR" 2>/dev/null || true
WAVE_TEST_DELAY_2=0.1
export WAVE_TEST_DELAY_2
start_wave "$CONTEXT_PARTIAL" partial 1 "$T/wave-partial.out"
PARTIAL_WAVE_PID=$STARTED_WAVE_PID
wait_for_json "$PARTIAL_STATUS" '.lead.process.finishedAt != null' || true
write_adjudication "$ARTIFACT_PARTIAL" wave-partial 1 false
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_PARTIAL" --wave-status "$PARTIAL_STATUS" \
  --action promote > "$T/control-partial.out"
wait "$PARTIAL_WAVE_PID"
check "$?" "0" "replacement supervisor finishes a partially launched wave"
wait "$PARTIAL_LEAD_PID" 2>/dev/null || true
if jq -e --arg old "$PARTIAL_OLD_NONCE" '
  .lead.process.supervisorNonce == $old and
  .speculative.process.supervisorNonce != $old and
  .lead.process.exitCodeSource == "process" and
  .speculative.state == "promoted"
' "$PARTIAL_STATUS" >/dev/null; then
  ok "partial attachment preserves the existing lead and launches only speculative"
else
  ng "partial attachment preserves the existing lead and launches only speculative"
fi

echo "== W00l: replacement termination never signals an attached stored PID =="
ARTIFACT_ATTACHED_TERM="$T/artifact-attached-term"
CONTEXT_ATTACHED_TERM="$T/context-attached-term.json"
write_context "$ARTIFACT_ATTACHED_TERM" "$CONTEXT_ATTACHED_TERM" wave-attached-term
prepare_prompts "$CONTEXT_ATTACHED_TERM" attached-term 1 2
sleep 30 &
ATTACHED_OLD_SUPERVISOR=$!
ATTACHED_OLD_NATIVE_PID=$ATTACHED_OLD_SUPERVISOR
case "$OSTYPE" in
  msys*|cygwin*)
    ATTACHED_OLD_NATIVE_PID=$(sed -n '1p' \
      "/proc/$ATTACHED_OLD_SUPERVISOR/winpid" 2>/dev/null) ||
      ATTACHED_OLD_NATIVE_PID=""
    ;;
esac
ATTACHED_RESERVATION=$(node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_ATTACHED_TERM" --first-round 1 \
  --supervisor-pid "$ATTACHED_OLD_NATIVE_PID" \
  --claude-lead-prompt "$T/attached-term-claude-round-1.md" \
  --codex-lead-prompt "$T/attached-term-codex-round-1.md" \
  --claude-speculative-prompt "$T/attached-term-claude-round-2.md" \
  --codex-speculative-prompt "$T/attached-term-codex-round-2.md")
ATTACHED_STATUS=$(printf '%s' "$ATTACHED_RESERVATION" | jq -r .statusPath)
ATTACHED_OLD_NONCE=$(printf '%s' "$ATTACHED_RESERVATION" |
  jq -r .status.supervisor.nonce)
WAVE_TEST_DELAY_1=3 WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_ATTACHED_TERM" \
    --claude-prompt "$T/attached-term-claude-round-1.md" \
    --codex-prompt "$T/attached-term-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    --wave-status "$ATTACHED_STATUS" --wave-role lead \
    --wave-supervisor-nonce "$ATTACHED_OLD_NONCE" \
    > "$T/attached-term-lead.out" 2>&1 &
ATTACHED_LEAD_PID=$!
WAVE_TEST_DELAY_2=3 WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_ATTACHED_TERM" \
    --claude-prompt "$T/attached-term-claude-round-2.md" \
    --codex-prompt "$T/attached-term-codex-round-2.md" \
    --phase convergence --round 2 --reviewer both --attempt 1 \
    --wave-status "$ATTACHED_STATUS" --wave-role speculative \
    --wave-supervisor-nonce "$ATTACHED_OLD_NONCE" \
    > "$T/attached-term-speculative.out" 2>&1 &
ATTACHED_SPECULATIVE_PID=$!
wait_for_json "$ATTACHED_STATUS" '
  .lead.state == "running" and .speculative.state == "running"
' || true
kill "$ATTACHED_OLD_SUPERVISOR" 2>/dev/null || true
wait "$ATTACHED_OLD_SUPERVISOR" 2>/dev/null || true
sleep 30 &
ATTACHED_SENTINEL_PID=$!
jq --argjson sentinel "$ATTACHED_SENTINEL_PID" \
  '.speculative.process.signalPid = $sentinel' "$ATTACHED_STATUS" \
  > "$T/attached-term-status.json"
mv "$T/attached-term-status.json" "$ATTACHED_STATUS"
start_wave "$CONTEXT_ATTACHED_TERM" attached-term 1 "$T/wave-attached-term.out"
ATTACHED_WAVE_PID=$STARTED_WAVE_PID
wait_for_text "$T/wave-attached-term.out" "WAVE_SPECULATIVE_ROUND: 2" || true
kill -TERM "$ATTACHED_WAVE_PID" 2>/dev/null || true
wait "$ATTACHED_WAVE_PID"
check "$?" "143" "replacement supervisor propagates TERM without stored-PID signalling"
if kill -0 "$ATTACHED_SENTINEL_PID" 2>/dev/null; then
  ok "replacement termination leaves a reused stored signal PID untouched"
else
  ng "replacement termination leaves a reused stored signal PID untouched"
fi
wait "$ATTACHED_LEAD_PID" 2>/dev/null || true
wait "$ATTACHED_SPECULATIVE_PID" 2>/dev/null || true
if wait_for_json "$ATTACHED_STATUS" '
  .termination.signal == "TERM" and
  .lead.process.finishedAt != null and
  .lead.process.signal == "TERM" and
  .lead.process.exitCodeSource == "process" and
  .speculative.process.finishedAt != null and
  .speculative.process.signal == "TERM" and
  .speculative.process.exitCodeSource == "process"
' && jq -e '.attempts[0].interrupted == true' \
  "$ARTIFACT_ATTACHED_TERM/phase4/round-1/status.json" >/dev/null &&
  jq -e '.attempts[0].interrupted == true' \
  "$ARTIFACT_ATTACHED_TERM/phase4/waves/wave-1-2/speculative-round-2/status.json" \
  >/dev/null; then
  ok "authenticated termination makes attached pair owners stop and finalize"
else
  ng "authenticated termination makes attached pair owners stop and finalize"
fi
kill "$ATTACHED_SENTINEL_PID" 2>/dev/null || true
wait "$ATTACHED_SENTINEL_PID" 2>/dev/null || true

echo "== W00m: a signal during fork bookkeeping is applied after PID capture =="
ARTIFACT_FORK_SIGNAL="$T/artifact-fork-signal"
CONTEXT_FORK_SIGNAL="$T/context-fork-signal.json"
write_context "$ARTIFACT_FORK_SIGNAL" "$CONTEXT_FORK_SIGNAL" wave-fork-signal
prepare_prompts "$CONTEXT_FORK_SIGNAL" fork-signal 1 2
WAVE_TEST_DELAY_1=10 WAVE_TEST_DELAY_2=10
DEEP_REVIEW_TEST_POST_FORK_DELAY_SECONDS=2
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
export DEEP_REVIEW_TEST_POST_FORK_DELAY_SECONDS
start_wave "$CONTEXT_FORK_SIGNAL" fork-signal 1 "$T/wave-fork-signal.out"
FORK_SIGNAL_WAVE_PID=$STARTED_WAVE_PID
FORK_SIGNAL_STATUS="$ARTIFACT_FORK_SIGNAL/phase4/waves/wave-1-2/status.json"
wait_for_json "$FORK_SIGNAL_STATUS" '.lead.process.startedAt != null' || true
FORK_SIGNAL_PAIR_PID=$(jq -r .lead.process.signalPid "$FORK_SIGNAL_STATUS")
kill -TERM "$FORK_SIGNAL_WAVE_PID" 2>/dev/null || true
wait "$FORK_SIGNAL_WAVE_PID"
check "$?" "143" "pending TERM is propagated after the forked PID is captured"
unset DEEP_REVIEW_TEST_POST_FORK_DELAY_SECONDS
if ! kill -0 "$FORK_SIGNAL_PAIR_PID" 2>/dev/null &&
  jq -e '
    .termination.signal == "TERM" and
    .lead.process.finishedAt != null and
    .lead.process.signal == "TERM"
  ' "$FORK_SIGNAL_STATUS" >/dev/null; then
  ok "fork bookkeeping cannot lose the just-created pair process"
else
  ng "fork bookkeeping cannot lose the just-created pair process"
fi

echo "== W00n: a signal before role claims leaves no reserved role behind =="
rm -f "$T/state/"*.started
ARTIFACT_PRECLAIM_SIGNAL="$T/artifact-preclaim-signal"
CONTEXT_PRECLAIM_SIGNAL="$T/context-preclaim-signal.json"
write_context \
  "$ARTIFACT_PRECLAIM_SIGNAL" "$CONTEXT_PRECLAIM_SIGNAL" \
  wave-preclaim-signal
prepare_prompts "$CONTEXT_PRECLAIM_SIGNAL" preclaim-signal 1 2
WAVE_TEST_DELAY_1=10 WAVE_TEST_DELAY_2=10
DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_DELAY_SECONDS=2
DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX="$T/preclaim-signal"
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
export DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_DELAY_SECONDS
export DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX
start_wave \
  "$CONTEXT_PRECLAIM_SIGNAL" preclaim-signal 1 \
  "$T/wave-preclaim-signal.out"
PRECLAIM_SIGNAL_WAVE_PID=$STARTED_WAVE_PID
PRECLAIM_SIGNAL_STATUS="$ARTIFACT_PRECLAIM_SIGNAL/phase4/waves/wave-1-2/status.json"
wait_for_file "$DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX.lead.ready" || true
wait_for_file \
  "$DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX.speculative.ready" || true
kill -TERM "$PRECLAIM_SIGNAL_WAVE_PID" 2>/dev/null || true
wait "$PRECLAIM_SIGNAL_WAVE_PID"
check "$?" "143" "pre-claim TERM is propagated after both claims are durable"
unset DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_DELAY_SECONDS
unset DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX
if jq -e '
  .termination.signal == "TERM" and
  .lead.process.startedAt != null and
  .lead.process.finishedAt != null and
  .lead.process.signal == "TERM" and
  .lead.executionEvidence.complete == true and
  .speculative.process.startedAt != null and
  .speculative.process.finishedAt != null and
  .speculative.process.signal == "TERM" and
  .speculative.executionEvidence.complete == true
' "$PRECLAIM_SIGNAL_STATUS" >/dev/null &&
  jq -e '.attempts[0].interrupted == true' \
    "$ARTIFACT_PRECLAIM_SIGNAL/phase4/round-1/status.json" >/dev/null &&
  jq -e '.attempts[0].interrupted == true' \
    "$ARTIFACT_PRECLAIM_SIGNAL/phase4/waves/wave-1-2/speculative-round-2/status.json" \
    >/dev/null; then
  ok "pre-claim termination leaves both roles terminal"
else
  ng "pre-claim termination leaves both roles terminal"
fi
if [ ! -e "$T/state/round-1-claude.started" ] &&
  [ ! -e "$T/state/round-1-codex.started" ] &&
  [ ! -e "$T/state/round-2-claude.started" ] &&
  [ ! -e "$T/state/round-2-codex.started" ]; then
  ok "pre-claim termination starts no external reviewer"
else
  ng "pre-claim termination starts no external reviewer"
fi

echo "== W00na: pre-authorization supervisor replacement preserves recovery =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_PREAUTH_REPLACE="$T/artifact-preauth-replace"
CONTEXT_PREAUTH_REPLACE="$T/context-preauth-replace.json"
write_context \
  "$ARTIFACT_PREAUTH_REPLACE" "$CONTEXT_PREAUTH_REPLACE" \
  wave-preauth-replace
prepare_prompts "$CONTEXT_PREAUTH_REPLACE" preauth-replace 1 2
WAVE_TEST_DELAY_1=0.1 WAVE_TEST_DELAY_2=0.1
WAVE_RECOVERY_WAIT_SECONDS=5
DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER="$T/preauth-replace.ready"
DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS=6
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2 WAVE_RECOVERY_WAIT_SECONDS
export DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER
export DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS
start_wave \
  "$CONTEXT_PREAUTH_REPLACE" preauth-replace 1 \
  "$T/wave-preauth-replace.out"
PREAUTH_REPLACE_OLD_WAVE_PID=$STARTED_WAVE_PID
PREAUTH_REPLACE_STATUS="$ARTIFACT_PREAUTH_REPLACE/phase4/waves/wave-1-2/status.json"
wait_for_file "$DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER" || true
sleep 3
kill -KILL "$PREAUTH_REPLACE_OLD_WAVE_PID" 2>/dev/null || true
wait "$PREAUTH_REPLACE_OLD_WAVE_PID" 2>/dev/null || true
DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS=3
export DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS
start_wave \
  "$CONTEXT_PREAUTH_REPLACE" preauth-replace 1 \
  "$T/wave-preauth-replace-recovered.out"
PREAUTH_REPLACE_WAVE_PID=$STARTED_WAVE_PID
unset DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER
unset DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS
wait_for_json "$PREAUTH_REPLACE_STATUS" \
  '.lead.process.finishedAt != null' || true
write_adjudication "$ARTIFACT_PREAUTH_REPLACE" wave-preauth-replace 1 false
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_PREAUTH_REPLACE" \
  --wave-status "$PREAUTH_REPLACE_STATUS" \
  --action promote > "$T/control-preauth-replace.out"
wait "$PREAUTH_REPLACE_WAVE_PID"
check "$?" "0" \
  "replacement supervisor resets the authorization deadline and authorizes both pairs"
unset WAVE_RECOVERY_WAIT_SECONDS
if jq -e '
  .termination == null and
  .reviewersReadyAt != null and
  .lead.process.reviewersAuthorizedAt != null and
  .lead.process.exitCode == 0 and
  .speculative.process.reviewersAuthorizedAt != null and
  .speculative.process.exitCode == 0 and
  .speculative.state == "promoted"
' "$PREAUTH_REPLACE_STATUS" >/dev/null &&
  [ -e "$T/state/round-1-claude.started" ] &&
  [ -e "$T/state/round-1-codex.started" ] &&
  [ -e "$T/state/round-2-claude.started" ] &&
  [ -e "$T/state/round-2-codex.started" ]; then
  ok "pre-launch replacement keeps same-run reviewer recovery"
else
  ng "pre-launch replacement keeps same-run reviewer recovery"
fi

echo "== W00nb: orphaned pre-authorization pairs stop at the recovery bound =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_PREAUTH_TIMEOUT="$T/artifact-preauth-timeout"
CONTEXT_PREAUTH_TIMEOUT="$T/context-preauth-timeout.json"
write_context \
  "$ARTIFACT_PREAUTH_TIMEOUT" "$CONTEXT_PREAUTH_TIMEOUT" \
  wave-preauth-timeout
prepare_prompts "$CONTEXT_PREAUTH_TIMEOUT" preauth-timeout 1 2
WAVE_TEST_DELAY_1=10 WAVE_TEST_DELAY_2=10
WAVE_RECOVERY_WAIT_SECONDS=1
DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER="$T/preauth-timeout.ready"
DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS=2
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2 WAVE_RECOVERY_WAIT_SECONDS
export DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER
export DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS
start_wave \
  "$CONTEXT_PREAUTH_TIMEOUT" preauth-timeout 1 \
  "$T/wave-preauth-timeout.out"
PREAUTH_TIMEOUT_WAVE_PID=$STARTED_WAVE_PID
PREAUTH_TIMEOUT_STATUS="$ARTIFACT_PREAUTH_TIMEOUT/phase4/waves/wave-1-2/status.json"
wait_for_file "$DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER" || true
PREAUTH_TIMEOUT_LEAD_GROUP=$(jq -r .lead.process.signalPid \
  "$PREAUTH_TIMEOUT_STATUS")
PREAUTH_TIMEOUT_SPECULATIVE_GROUP=$(jq -r .speculative.process.signalPid \
  "$PREAUTH_TIMEOUT_STATUS")
PREAUTH_TIMEOUT_STARTED_AT=$SECONDS
kill -KILL "$PREAUTH_TIMEOUT_WAVE_PID" 2>/dev/null || true
wait "$PREAUTH_TIMEOUT_WAVE_PID" 2>/dev/null || true
wait_for_json "$PREAUTH_TIMEOUT_STATUS" '
  .lead.process.finishedAt != null and
  .speculative.process.finishedAt != null
' || true
PREAUTH_TIMEOUT_ELAPSED=$((SECONDS - PREAUTH_TIMEOUT_STARTED_AT))
unset WAVE_RECOVERY_WAIT_SECONDS
unset DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER
unset DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS
if [ "$PREAUTH_TIMEOUT_ELAPSED" -le 5 ]; then
  ok "pre-launch authorization timeout is bounded"
else
  ng "pre-launch authorization timeout is bounded"
fi
if jq -e '
  .termination.signal == "TERM" and
  .reviewersReadyAt == null and
  .lead.process.reviewersAuthorizedAt == null and
  .lead.process.exitCode == 143 and
  .lead.process.signal == "TERM" and
  .lead.executionEvidence.complete == true and
  .speculative.process.reviewersAuthorizedAt == null and
  .speculative.process.exitCode == 143 and
  .speculative.process.signal == "TERM" and
  .speculative.executionEvidence.complete == true
' "$PREAUTH_TIMEOUT_STATUS" >/dev/null &&
  jq -e '
    .attempts[0].interrupted == true and
    .attempts[0].claude.launched == false and
    .attempts[0].codex.launched == false
  ' "$ARTIFACT_PREAUTH_TIMEOUT/phase4/round-1/status.json" >/dev/null &&
  jq -e '
    .attempts[0].interrupted == true and
    .attempts[0].claude.launched == false and
    .attempts[0].codex.launched == false
  ' "$ARTIFACT_PREAUTH_TIMEOUT/phase4/waves/wave-1-2/speculative-round-2/status.json" \
    >/dev/null; then
  ok "authorization timeout terminalizes both unlaunched reviewer pairs"
else
  ng "authorization timeout terminalizes both unlaunched reviewer pairs"
fi
if ! kill -0 -- "-$PREAUTH_TIMEOUT_LEAD_GROUP" 2>/dev/null &&
  ! kill -0 -- "-$PREAUTH_TIMEOUT_SPECULATIVE_GROUP" 2>/dev/null &&
  [ ! -e "$T/state/round-1-claude.started" ] &&
  [ ! -e "$T/state/round-1-codex.started" ] &&
  [ ! -e "$T/state/round-2-claude.started" ] &&
  [ ! -e "$T/state/round-2-codex.started" ]; then
  ok "authorization timeout leaves no pair or reviewer process running"
else
  ng "authorization timeout leaves no pair or reviewer process running"
fi
node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_PREAUTH_TIMEOUT" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/preauth-timeout-claude-round-1.md" \
  --codex-lead-prompt "$T/preauth-timeout-codex-round-1.md" \
  --claude-speculative-prompt "$T/preauth-timeout-claude-round-2.md" \
  --codex-speculative-prompt "$T/preauth-timeout-codex-round-2.md" \
  > "$T/preauth-timeout-reattach.out" 2>&1
check "$?" "1" "authorization timeout makes the wave non-attachable"
inspect_waves "$CONTEXT_PREAUTH_TIMEOUT" "$ARTIFACT_PREAUTH_TIMEOUT" \
  > "$T/preauth-timeout-inspection.out" 2>&1
check "$?" "1" \
  "report validation rejects a timed-out wave despite complete pair evidence"

echo "== W00nc: authorization expiry cannot overtake reviewer readiness =="
ARTIFACT_READY_RACE="$T/artifact-ready-race"
CONTEXT_READY_RACE="$T/context-ready-race.json"
write_context "$ARTIFACT_READY_RACE" "$CONTEXT_READY_RACE" wave-ready-race
prepare_prompts "$CONTEXT_READY_RACE" ready-race 1 2
READY_RACE_RESERVATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_READY_RACE" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/ready-race-claude-round-1.md" \
  --codex-lead-prompt "$T/ready-race-codex-round-1.md" \
  --claude-speculative-prompt "$T/ready-race-claude-round-2.md" \
  --codex-speculative-prompt "$T/ready-race-codex-round-2.md")
READY_RACE_STATUS=$(printf '%s' "$READY_RACE_RESERVATION" | jq -r .statusPath)
READY_RACE_NONCE=$(printf '%s' "$READY_RACE_RESERVATION" |
  jq -r .status.supervisor.nonce)
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_READY_RACE" --status "$READY_RACE_STATUS" \
  --role lead --pid "$WAVE_TEST_SUPERVISOR_PID" \
  > "$T/ready-race-lead-start.out"
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_READY_RACE" --status "$READY_RACE_STATUS" \
  --role speculative --pid "$WAVE_TEST_SUPERVISOR_PID" \
  > "$T/ready-race-speculative-start.out"
node "$T/tooling/scripts/review-wave-state.mjs" mark-reviewers-ready \
  --context "$CONTEXT_READY_RACE" --status "$READY_RACE_STATUS" \
  --supervisor-nonce "$READY_RACE_NONCE" \
  > "$T/ready-race-ready.out"
READY_RACE_EXPIRATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" \
  expire-reviewer-authorization \
  --context "$CONTEXT_READY_RACE" --status "$READY_RACE_STATUS" \
  --role lead --supervisor-nonce "$READY_RACE_NONCE" \
  --process-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --active-supervisor-nonce "$READY_RACE_NONCE")
if [ "$(printf '%s' "$READY_RACE_EXPIRATION" | jq -r .expired)" = "false" ] &&
  jq -e '.reviewersReadyAt != null and .termination == null' \
    "$READY_RACE_STATUS" >/dev/null; then
  ok "reviewer readiness wins atomically over timeout expiry"
else
  ng "reviewer readiness wins atomically over timeout expiry"
fi

echo "== W00nd: legacy pending status remains bounded =="
ARTIFACT_LEGACY_PREAUTH="$T/artifact-legacy-preauth"
CONTEXT_LEGACY_PREAUTH="$T/context-legacy-preauth.json"
write_context \
  "$ARTIFACT_LEGACY_PREAUTH" "$CONTEXT_LEGACY_PREAUTH" \
  wave-legacy-preauth
prepare_prompts "$CONTEXT_LEGACY_PREAUTH" legacy-preauth 1 2
LEGACY_PREAUTH_RESERVATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_LEGACY_PREAUTH" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/legacy-preauth-claude-round-1.md" \
  --codex-lead-prompt "$T/legacy-preauth-codex-round-1.md" \
  --claude-speculative-prompt "$T/legacy-preauth-claude-round-2.md" \
  --codex-speculative-prompt "$T/legacy-preauth-codex-round-2.md")
LEGACY_PREAUTH_STATUS=$(printf '%s' "$LEGACY_PREAUTH_RESERVATION" |
  jq -r .statusPath)
LEGACY_PREAUTH_NONCE=$(printf '%s' "$LEGACY_PREAUTH_RESERVATION" |
  jq -r .status.supervisor.nonce)
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_LEGACY_PREAUTH" --status "$LEGACY_PREAUTH_STATUS" \
  --role lead --pid "$WAVE_TEST_SUPERVISOR_PID" \
  > "$T/legacy-preauth-lead-start.out"
jq 'del(.reviewersReadyAt)' "$LEGACY_PREAUTH_STATUS" \
  > "$T/legacy-preauth-status.json"
mv "$T/legacy-preauth-status.json" "$LEGACY_PREAUTH_STATUS"
LEGACY_PREAUTH_EXPIRATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" \
  expire-reviewer-authorization \
  --context "$CONTEXT_LEGACY_PREAUTH" --status "$LEGACY_PREAUTH_STATUS" \
  --role lead --supervisor-nonce "$LEGACY_PREAUTH_NONCE" \
  --process-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --active-supervisor-nonce "$LEGACY_PREAUTH_NONCE")
if [ "$(printf '%s' "$LEGACY_PREAUTH_EXPIRATION" | jq -r .expired)" = "true" ] &&
  jq -e '.termination.signal == "TERM"' "$LEGACY_PREAUTH_STATUS" >/dev/null; then
  ok "missing legacy readiness field cannot restore an unbounded wait"
else
  ng "missing legacy readiness field cannot restore an unbounded wait"
fi

echo "== W00o: a hung pre-claim child is bounded and terminalized =="
rm -f "$T/state/"*.started
ARTIFACT_HUNG_PRECLAIM="$T/artifact-hung-preclaim"
CONTEXT_HUNG_PRECLAIM="$T/context-hung-preclaim.json"
write_context \
  "$ARTIFACT_HUNG_PRECLAIM" "$CONTEXT_HUNG_PRECLAIM" \
  wave-hung-preclaim
prepare_prompts "$CONTEXT_HUNG_PRECLAIM" hung-preclaim 1 2
WAVE_TEST_DELAY_1=10 WAVE_TEST_DELAY_2=10
DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_DELAY_SECONDS=30
DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX="$T/hung-preclaim"
DEEP_REVIEW_TEST_ROLE_CLAIM_TERMINATION_GRACE_SECONDS=1
DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_IGNORE_SIGNALS=1
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
export DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_DELAY_SECONDS
export DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX
export DEEP_REVIEW_TEST_ROLE_CLAIM_TERMINATION_GRACE_SECONDS
export DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_IGNORE_SIGNALS
start_wave \
  "$CONTEXT_HUNG_PRECLAIM" hung-preclaim 1 \
  "$T/wave-hung-preclaim.out"
HUNG_PRECLAIM_WAVE_PID=$STARTED_WAVE_PID
HUNG_PRECLAIM_STATUS="$ARTIFACT_HUNG_PRECLAIM/phase4/waves/wave-1-2/status.json"
wait_for_file "$DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX.lead.ready" || true
wait_for_file "$DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX.speculative.ready" || true
HUNG_PRECLAIM_STARTED_AT=$SECONDS
kill -TERM "$HUNG_PRECLAIM_WAVE_PID" 2>/dev/null || true
wait "$HUNG_PRECLAIM_WAVE_PID"
HUNG_PRECLAIM_RC=$?
HUNG_PRECLAIM_ELAPSED=$((SECONDS - HUNG_PRECLAIM_STARTED_AT))
unset DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_DELAY_SECONDS
unset DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX
unset DEEP_REVIEW_TEST_ROLE_CLAIM_TERMINATION_GRACE_SECONDS
unset DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_IGNORE_SIGNALS
check "$HUNG_PRECLAIM_RC" "143" \
  "hung pre-claim termination propagates the outer signal"
if [ "$HUNG_PRECLAIM_ELAPSED" -le 5 ]; then
  ok "hung pre-claim termination stays within its grace bound"
else
  ng "hung pre-claim termination stays within its grace bound"
fi
HUNG_PRECLAIM_LEAD_GROUP=$(jq -r .lead.process.signalPid \
  "$HUNG_PRECLAIM_STATUS")
HUNG_PRECLAIM_SPECULATIVE_GROUP=$(jq -r .speculative.process.signalPid \
  "$HUNG_PRECLAIM_STATUS")
if jq -e '
  .termination.signal == "TERM" and
  .lead.process.finishedAt != null and
  .lead.process.exitCode == 137 and
  .lead.process.signal == "TERM" and
  .lead.executionEvidence.complete == false and
  .speculative.process.finishedAt != null and
  .speculative.process.exitCode == 137 and
  .speculative.process.signal == "TERM" and
  .speculative.executionEvidence.complete == false
' "$HUNG_PRECLAIM_STATUS" >/dev/null; then
  ok "hung unclaimed roles retain explicit incomplete evidence"
else
  ng "hung unclaimed roles retain explicit incomplete evidence"
fi
if ! kill -0 -- "-$HUNG_PRECLAIM_LEAD_GROUP" 2>/dev/null &&
  ! kill -0 -- "-$HUNG_PRECLAIM_SPECULATIVE_GROUP" 2>/dev/null; then
  ok "hung pre-claim pair groups are fully reaped"
else
  ng "hung pre-claim pair groups are fully reaped"
fi

echo "== W00p: child-reported native PID survives a pre-claim exit =="
ARTIFACT_PID_HANDOFF="$T/artifact-pid-handoff"
CONTEXT_PID_HANDOFF="$T/context-pid-handoff.json"
write_context "$ARTIFACT_PID_HANDOFF" "$CONTEXT_PID_HANDOFF" wave-pid-handoff
prepare_prompts "$CONTEXT_PID_HANDOFF" pid-handoff 1 2
DEEP_REVIEW_TEST_EXIT_AFTER_NATIVE_PID_HANDOFF=1
export DEEP_REVIEW_TEST_EXIT_AFTER_NATIVE_PID_HANDOFF
bash "$T/tooling/scripts/run-review-wave.sh" \
  --context "$CONTEXT_PID_HANDOFF" \
  --first-round 1 \
  --claude-lead-prompt "$T/pid-handoff-claude-round-1.md" \
  --codex-lead-prompt "$T/pid-handoff-codex-round-1.md" \
  --claude-speculative-prompt "$T/pid-handoff-claude-round-2.md" \
  --codex-speculative-prompt "$T/pid-handoff-codex-round-2.md" \
  > "$T/wave-pid-handoff.out" 2>&1
PID_HANDOFF_RC=$?
unset DEEP_REVIEW_TEST_EXIT_AFTER_NATIVE_PID_HANDOFF
check "$PID_HANDOFF_RC" "1" \
  "pre-claim child exit remains a bounded wave failure"
PID_HANDOFF_STATUS="$ARTIFACT_PID_HANDOFF/phase4/waves/wave-1-2/status.json"
if jq -e '
  .termination.signal == "TERM" and
  .lead.process.pid != null and
  .lead.process.finishedAt != null and
  .lead.process.exitCode == 86 and
  .lead.executionEvidence.complete == false and
  .speculative.process.pid != null and
  .speculative.process.finishedAt != null and
  .speculative.process.exitCode == 86 and
  .speculative.executionEvidence.complete == false
' "$PID_HANDOFF_STATUS" >/dev/null; then
  ok "pre-claim child exit retains both native identities and terminal evidence"
else
  ng "pre-claim child exit retains both native identities and terminal evidence"
fi
if ! find "$T/temp" -name 'wave-*-native-pid.*' -print -quit | grep -q .; then
  ok "native PID handoff files are removed after capture"
else
  ng "native PID handoff files are removed after capture"
fi

echo "== W00q: a transient native PID handoff failure retries once =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_PID_HANDOFF_RETRY="$T/artifact-pid-handoff-retry"
CONTEXT_PID_HANDOFF_RETRY="$T/context-pid-handoff-retry.json"
write_context \
  "$ARTIFACT_PID_HANDOFF_RETRY" "$CONTEXT_PID_HANDOFF_RETRY" \
  wave-pid-handoff-retry
prepare_prompts "$CONTEXT_PID_HANDOFF_RETRY" pid-handoff-retry 1 2
DEEP_REVIEW_TEST_FAIL_FIRST_NATIVE_PID_HANDOFF_MARKER="$T/pid-handoff-first-failure"
export DEEP_REVIEW_TEST_FAIL_FIRST_NATIVE_PID_HANDOFF_MARKER
start_wave \
  "$CONTEXT_PID_HANDOFF_RETRY" pid-handoff-retry 1 \
  "$T/wave-pid-handoff-retry.out"
PID_HANDOFF_RETRY_PID=$STARTED_WAVE_PID
unset DEEP_REVIEW_TEST_FAIL_FIRST_NATIVE_PID_HANDOFF_MARKER
PID_HANDOFF_RETRY_STATUS="$ARTIFACT_PID_HANDOFF_RETRY/phase4/waves/wave-1-2/status.json"
wait_for_json \
  "$PID_HANDOFF_RETRY_STATUS" '.lead.process.finishedAt != null' || true
write_adjudication \
  "$ARTIFACT_PID_HANDOFF_RETRY" wave-pid-handoff-retry 1 false
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_PID_HANDOFF_RETRY" \
  --wave-status "$PID_HANDOFF_RETRY_STATUS" \
  --action promote > "$T/control-pid-handoff-retry.out"
wait "$PID_HANDOFF_RETRY_PID"
check "$?" "0" "a transient PID handoff failure completes after one retry"
check "$(grep -c 'retrying pair startup once' \
  "$T/wave-pid-handoff-retry.out")" "1" \
  "a transient PID handoff failure performs exactly one retry"
if jq -e '
  .termination == null and
  .lead.process.pid != null and
  .lead.process.nativePidUnavailableReason == null and
  .lead.executionEvidence.complete == true and
  .speculative.process.pid != null and
  .speculative.executionEvidence.complete == true
' "$PID_HANDOFF_RETRY_STATUS" >/dev/null; then
  ok "successful retry retains normal native identities and evidence"
else
  ng "successful retry retains normal native identities and evidence"
fi
if [ -e "$T/state/round-1-claude.started" ] &&
  [ -e "$T/state/round-1-codex.started" ] &&
  [ -e "$T/state/round-2-claude.started" ] &&
  [ -e "$T/state/round-2-codex.started" ]; then
  ok "reviewers start only after the replacement pair claims both roles"
else
  ng "reviewers start only after the replacement pair claims both roles"
fi

echo "== W00r: repeated native PID handoff failure terminates incomplete =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_PID_HANDOFF_FAILED="$T/artifact-pid-handoff-failed"
CONTEXT_PID_HANDOFF_FAILED="$T/context-pid-handoff-failed.json"
write_context \
  "$ARTIFACT_PID_HANDOFF_FAILED" "$CONTEXT_PID_HANDOFF_FAILED" \
  wave-pid-handoff-failed
prepare_prompts "$CONTEXT_PID_HANDOFF_FAILED" pid-handoff-failed 1 2
DEEP_REVIEW_TEST_FAIL_NATIVE_PID_HANDOFF_ALWAYS=1 WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-wave.sh" \
    --context "$CONTEXT_PID_HANDOFF_FAILED" \
    --first-round 1 \
    --claude-lead-prompt "$T/pid-handoff-failed-claude-round-1.md" \
    --codex-lead-prompt "$T/pid-handoff-failed-codex-round-1.md" \
    --claude-speculative-prompt \
      "$T/pid-handoff-failed-claude-round-2.md" \
    --codex-speculative-prompt \
      "$T/pid-handoff-failed-codex-round-2.md" \
    > "$T/wave-pid-handoff-failed.out" 2>&1
PID_HANDOFF_FAILED_RC=$?
check "$PID_HANDOFF_FAILED_RC" "1" \
  "repeated PID handoff failure stops the wave"
PID_HANDOFF_FAILED_STATUS="$ARTIFACT_PID_HANDOFF_FAILED/phase4/waves/wave-1-2/status.json"
if jq -e '
  .termination.signal == "TERM" and
  .lead.state == "attempt-finished" and
  .lead.process.pid == null and
  .lead.process.signalPid > 0 and
  .lead.process.nativePidUnavailableReason ==
    "native-pid-handoff-failed" and
  .lead.process.reviewersAuthorizedAt == null and
  .lead.process.finishedAt != null and
  .lead.process.exitCode == 87 and
  .lead.executionEvidence.complete == false and
  .speculative.state == "reserved" and
  .speculative.process.startedAt == null
' "$PID_HANDOFF_FAILED_STATUS" >/dev/null; then
  ok "repeated handoff failure records an unidentified incomplete launch"
else
  ng "repeated handoff failure records an unidentified incomplete launch"
fi
check "$(grep -c 'retrying pair startup once' \
  "$T/wave-pid-handoff-failed.out")" "1" \
  "permanent handoff failure remains bounded to one retry"
if [ ! -e "$T/state/round-1-claude.started" ] &&
  [ ! -e "$T/state/round-1-codex.started" ] &&
  [ ! -e "$T/state/round-2-claude.started" ] &&
  [ ! -e "$T/state/round-2-codex.started" ]; then
  ok "repeated handoff failure never starts a reviewer"
else
  ng "repeated handoff failure never starts a reviewer"
fi
node "$T/tooling/scripts/review-wave-state.mjs" role-state \
  --context "$CONTEXT_PID_HANDOFF_FAILED" \
  --status "$PID_HANDOFF_FAILED_STATUS" \
  --role lead > "$T/pid-handoff-failed-role.out"
check "$?" "0" "wave state accepts the explicit missing native PID record"
inspect_waves \
  "$CONTEXT_PID_HANDOFF_FAILED" "$ARTIFACT_PID_HANDOFF_FAILED" \
  > "$T/pid-handoff-failed-inspection.out" 2>&1
check "$?" "1" "report validation rejects the incomplete handoff run"
PID_HANDOFF_FAILED_GROUP=$(jq -r .lead.process.signalPid \
  "$PID_HANDOFF_FAILED_STATUS")
if ! kill -0 -- "-$PID_HANDOFF_FAILED_GROUP" 2>/dev/null; then
  ok "failed handoff child group is fully reaped before terminal recording"
else
  ng "failed handoff child group is fully reaped before terminal recording"
fi
if ! find "$T/temp" -name 'wave-*-native-pid.*' -print -quit | grep -q .; then
  ok "retry and failure paths remove every PID handoff file"
else
  ng "retry and failure paths remove every PID handoff file"
fi

echo "== W00s: speculative handoff failure gates all reviewer launches =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_SPECULATIVE_HANDOFF_FAILED="$T/artifact-speculative-handoff-failed"
CONTEXT_SPECULATIVE_HANDOFF_FAILED="$T/context-speculative-handoff-failed.json"
write_context \
  "$ARTIFACT_SPECULATIVE_HANDOFF_FAILED" \
  "$CONTEXT_SPECULATIVE_HANDOFF_FAILED" \
  wave-speculative-handoff-failed
prepare_prompts \
  "$CONTEXT_SPECULATIVE_HANDOFF_FAILED" speculative-handoff-failed 1 2
DEEP_REVIEW_TEST_FAIL_SPECULATIVE_NATIVE_PID_HANDOFF_ALWAYS=1 \
  WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-wave.sh" \
    --context "$CONTEXT_SPECULATIVE_HANDOFF_FAILED" \
    --first-round 1 \
    --claude-lead-prompt "$T/speculative-handoff-failed-claude-round-1.md" \
    --codex-lead-prompt "$T/speculative-handoff-failed-codex-round-1.md" \
    --claude-speculative-prompt \
      "$T/speculative-handoff-failed-claude-round-2.md" \
    --codex-speculative-prompt \
      "$T/speculative-handoff-failed-codex-round-2.md" \
    > "$T/wave-speculative-handoff-failed.out" 2>&1
SPECULATIVE_HANDOFF_FAILED_RC=$?
check "$SPECULATIVE_HANDOFF_FAILED_RC" "1" \
  "repeated speculative handoff failure stops the wave"
SPECULATIVE_HANDOFF_FAILED_STATUS="$ARTIFACT_SPECULATIVE_HANDOFF_FAILED/phase4/waves/wave-1-2/status.json"
if jq -e '
  .reviewersReadyAt == null and
  .termination.signal == "TERM" and
  .lead.process.pid != null and
  .lead.process.reviewersAuthorizedAt == null and
  .lead.process.finishedAt != null and
  .speculative.process.pid == null and
  .speculative.process.nativePidUnavailableReason ==
    "native-pid-handoff-failed" and
  .speculative.process.reviewersAuthorizedAt == null and
  .speculative.process.finishedAt != null and
  .speculative.executionEvidence.complete == false
' "$SPECULATIVE_HANDOFF_FAILED_STATUS" >/dev/null; then
  ok "speculative handoff failure preserves the reviewer launch barrier"
else
  ng "speculative handoff failure preserves the reviewer launch barrier"
fi
if [ ! -e "$T/state/round-1-claude.started" ] &&
  [ ! -e "$T/state/round-1-codex.started" ] &&
  [ ! -e "$T/state/round-2-claude.started" ] &&
  [ ! -e "$T/state/round-2-codex.started" ]; then
  ok "speculative handoff failure starts neither lead nor speculative reviewer"
else
  ng "speculative handoff failure starts neither lead nor speculative reviewer"
fi

echo "== W00t: a signal during failed-handoff cleanup keeps its identity =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_HANDOFF_SIGNAL="$T/artifact-handoff-signal"
CONTEXT_HANDOFF_SIGNAL="$T/context-handoff-signal.json"
HANDOFF_SIGNAL_MARKER="$T/handoff-signal-cleanup"
write_context \
  "$ARTIFACT_HANDOFF_SIGNAL" "$CONTEXT_HANDOFF_SIGNAL" wave-handoff-signal
prepare_prompts "$CONTEXT_HANDOFF_SIGNAL" handoff-signal 1 2
DEEP_REVIEW_TEST_FAIL_NATIVE_PID_HANDOFF_ALWAYS=1 \
  DEEP_REVIEW_TEST_PID_HANDOFF_CLEANUP_MARKER="$HANDOFF_SIGNAL_MARKER" \
  DEEP_REVIEW_TEST_PID_HANDOFF_CLEANUP_DELAY_SECONDS=1 \
  WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-wave.sh" \
    --context "$CONTEXT_HANDOFF_SIGNAL" \
    --first-round 1 \
    --claude-lead-prompt "$T/handoff-signal-claude-round-1.md" \
    --codex-lead-prompt "$T/handoff-signal-codex-round-1.md" \
    --claude-speculative-prompt "$T/handoff-signal-claude-round-2.md" \
    --codex-speculative-prompt "$T/handoff-signal-codex-round-2.md" \
    > "$T/wave-handoff-signal.out" 2>&1 &
HANDOFF_SIGNAL_WAVE_PID=$!
wait_for_file "$HANDOFF_SIGNAL_MARKER.lead" || true
kill -HUP "$HANDOFF_SIGNAL_WAVE_PID"
wait "$HANDOFF_SIGNAL_WAVE_PID"
HANDOFF_SIGNAL_RC=$?
check "$HANDOFF_SIGNAL_RC" "129" \
  "HUP during handoff cleanup preserves the wave exit semantics"
HANDOFF_SIGNAL_STATUS="$ARTIFACT_HANDOFF_SIGNAL/phase4/waves/wave-1-2/status.json"
if jq -e '
  .termination.signal == "HUP" and
  .lead.process.pid == null and
  .lead.process.nativePidUnavailableReason ==
    "native-pid-handoff-failed" and
  .lead.process.signal == "HUP" and
  .lead.process.finishedAt != null and
  .lead.executionEvidence.complete == false
' "$HANDOFF_SIGNAL_STATUS" >/dev/null; then
  ok "cleanup-time HUP records the explicit incomplete role result"
else
  ng "cleanup-time HUP records the explicit incomplete role result"
fi
check "$(grep -c 'retrying pair startup once' \
  "$T/wave-handoff-signal.out")" "0" \
  "an outer signal prevents a replacement pair from starting"
if [ ! -e "$T/state/round-1-claude.started" ] &&
  [ ! -e "$T/state/round-1-codex.started" ]; then
  ok "cleanup-time HUP starts no reviewer"
else
  ng "cleanup-time HUP starts no reviewer"
fi

echo "== W00u: a signal after retry selection prevents a replacement fork =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_HANDOFF_RETRY_SIGNAL="$T/artifact-handoff-retry-signal"
CONTEXT_HANDOFF_RETRY_SIGNAL="$T/context-handoff-retry-signal.json"
HANDOFF_RETRY_SIGNAL_MARKER="$T/handoff-retry-signal"
HANDOFF_RETRY_SIGNAL_ATTEMPTS="$T/handoff-retry-signal-attempts"
write_context \
  "$ARTIFACT_HANDOFF_RETRY_SIGNAL" "$CONTEXT_HANDOFF_RETRY_SIGNAL" \
  wave-handoff-retry-signal
prepare_prompts \
  "$CONTEXT_HANDOFF_RETRY_SIGNAL" handoff-retry-signal 1 2
DEEP_REVIEW_TEST_FAIL_NATIVE_PID_HANDOFF_ALWAYS=1 \
  DEEP_REVIEW_TEST_PID_HANDOFF_RETRY_MARKER="$HANDOFF_RETRY_SIGNAL_MARKER" \
  DEEP_REVIEW_TEST_PID_HANDOFF_RETRY_DELAY_SECONDS=1 \
  DEEP_REVIEW_TEST_NATIVE_PID_HANDOFF_ATTEMPT_LOG="$HANDOFF_RETRY_SIGNAL_ATTEMPTS" \
  WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-wave.sh" \
    --context "$CONTEXT_HANDOFF_RETRY_SIGNAL" \
    --first-round 1 \
    --claude-lead-prompt \
      "$T/handoff-retry-signal-claude-round-1.md" \
    --codex-lead-prompt "$T/handoff-retry-signal-codex-round-1.md" \
    --claude-speculative-prompt \
      "$T/handoff-retry-signal-claude-round-2.md" \
    --codex-speculative-prompt \
      "$T/handoff-retry-signal-codex-round-2.md" \
    > "$T/wave-handoff-retry-signal.out" 2>&1 &
HANDOFF_RETRY_SIGNAL_WAVE_PID=$!
wait_for_file "$HANDOFF_RETRY_SIGNAL_MARKER.lead" || true
kill -HUP "$HANDOFF_RETRY_SIGNAL_WAVE_PID"
wait "$HANDOFF_RETRY_SIGNAL_WAVE_PID"
HANDOFF_RETRY_SIGNAL_RC=$?
check "$HANDOFF_RETRY_SIGNAL_RC" "129" \
  "HUP after retry selection preserves the wave exit semantics"
check "$(grep -c . "$HANDOFF_RETRY_SIGNAL_ATTEMPTS")" "1" \
  "a pending outer signal prevents the replacement pair fork"
HANDOFF_RETRY_SIGNAL_STATUS="$ARTIFACT_HANDOFF_RETRY_SIGNAL/phase4/waves/wave-1-2/status.json"
if jq -e '
  .reviewersReadyAt == null and
  .termination.signal == "HUP" and
  .lead.state == "reserved" and
  .lead.process.startedAt == null and
  .speculative.state == "reserved" and
  .speculative.process.startedAt == null
' "$HANDOFF_RETRY_SIGNAL_STATUS" >/dev/null &&
  [ ! -e "$T/state/round-1-claude.started" ] &&
  [ ! -e "$T/state/round-1-codex.started" ]; then
  ok "retry-selection cancellation leaves no claimed role or reviewer"
else
  ng "retry-selection cancellation leaves no claimed role or reviewer"
fi

exercise_pair_fork_signal() {
  local stage="$1" run_id="wave-pair-fork-$1"
  local artifact="$T/artifact-pair-fork-$stage"
  local context="$T/context-pair-fork-$stage.json"
  local output="$T/wave-pair-fork-$stage.out"
  local status wave_pid wave_rc lead_group speculative_group
  local claude_1_group="" codex_1_group="" claude_2_group="" codex_2_group=""
  local lead_watcher_group="" speculative_watcher_group=""
  rm -f "$T/state/round-1-"*.started "$T/state/round-2-"*.started \
    "$T/state/round-1-"*.pid "$T/state/round-2-"*.pid
  write_context "$artifact" "$context" "$run_id"
  prepare_prompts "$context" "pair-fork-$stage" 1 2
  WAVE_TEST_DELAY_1=10 WAVE_TEST_DELAY_2=10
  DEEP_REVIEW_TEST_PAIR_POST_FORK_DELAY_SECONDS=1
  DEEP_REVIEW_TEST_WATCHER_PID_PREFIX="$T/pair-fork-$stage-watcher"
  export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
  export DEEP_REVIEW_TEST_PAIR_POST_FORK_DELAY_SECONDS
  export DEEP_REVIEW_TEST_WATCHER_PID_PREFIX
  start_wave "$context" "pair-fork-$stage" 1 "$output"
  wave_pid=$STARTED_WAVE_PID
  status="$artifact/phase4/waves/wave-1-2/status.json"
  if [ "$stage" = "watcher" ]; then
    wait_for_json "$status" '
      .lead.process.reviewersAuthorizedAt != null and
      .speculative.process.reviewersAuthorizedAt != null
    ' || true
    wait_for_file "$DEEP_REVIEW_TEST_WATCHER_PID_PREFIX.lead.forked" || true
    wait_for_file \
      "$DEEP_REVIEW_TEST_WATCHER_PID_PREFIX.speculative.forked" || true
  else
    wait_for_file "$T/state/round-1-codex.started" || true
    wait_for_file "$T/state/round-2-codex.started" || true
    wait_for_file "$T/state/round-1-claude.pid" || true
    wait_for_file "$T/state/round-1-codex.pid" || true
    wait_for_file "$T/state/round-2-claude.pid" || true
    wait_for_file "$T/state/round-2-codex.pid" || true
    claude_1_group=$(cat "$T/state/round-1-claude.pid")
    codex_1_group=$(cat "$T/state/round-1-codex.pid")
    claude_2_group=$(cat "$T/state/round-2-claude.pid")
    codex_2_group=$(cat "$T/state/round-2-codex.pid")
  fi
  lead_group=$(jq -r .lead.process.signalPid "$status")
  speculative_group=$(jq -r .speculative.process.signalPid "$status")
  kill -TERM "$wave_pid" 2>/dev/null || true
  wait "$wave_pid"
  wave_rc=$?
  if [ "$stage" = "watcher" ]; then
    wait_for_file "$DEEP_REVIEW_TEST_WATCHER_PID_PREFIX.lead.pid" || true
    wait_for_file \
      "$DEEP_REVIEW_TEST_WATCHER_PID_PREFIX.speculative.pid" || true
    lead_watcher_group=$(cat \
      "$DEEP_REVIEW_TEST_WATCHER_PID_PREFIX.lead.pid")
    speculative_watcher_group=$(cat \
      "$DEEP_REVIEW_TEST_WATCHER_PID_PREFIX.speculative.pid")
  fi
  unset DEEP_REVIEW_TEST_PAIR_POST_FORK_DELAY_SECONDS
  unset DEEP_REVIEW_TEST_WATCHER_PID_PREFIX
  check "$wave_rc" "143" \
    "pair $stage fork bookkeeping preserves the outer TERM"
  if ! kill -0 -- "-$lead_group" 2>/dev/null &&
    ! kill -0 -- "-$speculative_group" 2>/dev/null &&
    jq -e '
      .lead.process.finishedAt != null and
      .lead.process.signal == "TERM" and
      .speculative.process.finishedAt != null and
      .speculative.process.signal == "TERM"
    ' "$status" >/dev/null; then
    ok "pair $stage fork bookkeeping reaps every captured process group"
  else
    ng "pair $stage fork bookkeeping reaps every captured process group"
  fi
  if [ "$stage" = "watcher" ]; then
    if [[ "$lead_watcher_group" =~ ^[1-9][0-9]*$ ]] &&
      [[ "$speculative_watcher_group" =~ ^[1-9][0-9]*$ ]] &&
      ! kill -0 -- "-$lead_watcher_group" 2>/dev/null &&
      ! kill -0 -- "-$speculative_watcher_group" 2>/dev/null; then
      ok "pair watcher bookkeeping reaps both long-lived watcher groups"
    else
      ng "pair watcher bookkeeping reaps both long-lived watcher groups"
    fi
  fi
  if [ "$stage" = "reviewer" ]; then
    if [[ "$claude_1_group" =~ ^[1-9][0-9]*$ ]] &&
      [[ "$codex_1_group" =~ ^[1-9][0-9]*$ ]] &&
      [[ "$claude_2_group" =~ ^[1-9][0-9]*$ ]] &&
      [[ "$codex_2_group" =~ ^[1-9][0-9]*$ ]] &&
      ! kill -0 -- "-$claude_1_group" 2>/dev/null &&
      ! kill -0 -- "-$codex_1_group" 2>/dev/null &&
      ! kill -0 -- "-$claude_2_group" 2>/dev/null &&
      ! kill -0 -- "-$codex_2_group" 2>/dev/null; then
      ok "pair reviewer bookkeeping reaps all four external reviewer groups"
    else
      ng "pair reviewer bookkeeping reaps all four external reviewer groups"
    fi
  fi
}

echo "== W00ma: pair fork bookkeeping cannot lose watcher or reviewer groups =="
exercise_pair_fork_signal watcher
exercise_pair_fork_signal reviewer

echo "== W00mb: recovered wrapper death releases its long-lived watcher =="
ARTIFACT_WATCHER_RECOVERY="$T/artifact-watcher-recovery"
CONTEXT_WATCHER_RECOVERY="$T/context-watcher-recovery.json"
write_context \
  "$ARTIFACT_WATCHER_RECOVERY" "$CONTEXT_WATCHER_RECOVERY" \
  wave-watcher-recovery
prepare_prompts "$CONTEXT_WATCHER_RECOVERY" watcher-recovery 1 2
WATCHER_RECOVERY_RESERVATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_WATCHER_RECOVERY" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/watcher-recovery-claude-round-1.md" \
  --codex-lead-prompt "$T/watcher-recovery-codex-round-1.md" \
  --claude-speculative-prompt "$T/watcher-recovery-claude-round-2.md" \
  --codex-speculative-prompt "$T/watcher-recovery-codex-round-2.md")
WATCHER_RECOVERY_STATUS=$(printf '%s' "$WATCHER_RECOVERY_RESERVATION" |
  jq -r .statusPath)
WATCHER_RECOVERY_NONCE=$(printf '%s' "$WATCHER_RECOVERY_RESERVATION" |
  jq -r .status.supervisor.nonce)
WATCHER_RECOVERY_PREFIX="$T/watcher-recovery"
DEEP_REVIEW_TEST_PAIR_POST_CAPTURE_DELAY_SECONDS=5 \
DEEP_REVIEW_TEST_WATCHER_PID_PREFIX="$WATCHER_RECOVERY_PREFIX" \
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_WATCHER_RECOVERY" \
    --claude-prompt "$T/watcher-recovery-claude-round-1.md" \
    --codex-prompt "$T/watcher-recovery-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    --wave-status "$WATCHER_RECOVERY_STATUS" --wave-role lead \
    --wave-supervisor-nonce "$WATCHER_RECOVERY_NONCE" \
    > "$T/watcher-recovery-pair.out" 2>&1 &
WATCHER_RECOVERY_PAIR_PID=$!
wait_for_json "$WATCHER_RECOVERY_STATUS" \
  '.lead.process.startedAt != null' || true
node "$T/tooling/scripts/review-wave-state.mjs" authorize \
  --context "$CONTEXT_WATCHER_RECOVERY" \
  --status "$WATCHER_RECOVERY_STATUS" \
  --role speculative --round 2 --attempt 1 --reviewer both \
  --supervisor-nonce "$WATCHER_RECOVERY_NONCE" \
  --process-pid "$WAVE_TEST_SUPERVISOR_PID" --signal-pid "$$" \
  --claude-prompt "$T/watcher-recovery-claude-round-2.md" \
  --claude-prompt-purpose review \
  --codex-prompt "$T/watcher-recovery-codex-round-2.md" \
  --codex-prompt-purpose review > "$T/watcher-recovery-speculative.out"
node "$T/tooling/scripts/review-wave-state.mjs" mark-reviewers-ready \
  --context "$CONTEXT_WATCHER_RECOVERY" \
  --status "$WATCHER_RECOVERY_STATUS" \
  --supervisor-nonce "$WATCHER_RECOVERY_NONCE" \
  > "$T/watcher-recovery-reviewers-ready.out"
wait_for_file "$WATCHER_RECOVERY_PREFIX.lead.pid" || true
WATCHER_RECOVERY_GROUP=$(cat "$WATCHER_RECOVERY_PREFIX.lead.pid")
kill -KILL "$WATCHER_RECOVERY_PAIR_PID" 2>/dev/null || true
wait "$WATCHER_RECOVERY_PAIR_PID" 2>/dev/null || true
node "$T/tooling/scripts/review-wave-state.mjs" record-result \
  --context "$CONTEXT_WATCHER_RECOVERY" \
  --status "$WATCHER_RECOVERY_STATUS" \
  --role lead --exit-code 137 > "$T/watcher-recovery-result.out"
WATCHER_RECOVERY_POLLS=0
while kill -0 -- "-$WATCHER_RECOVERY_GROUP" 2>/dev/null &&
  [ "$WATCHER_RECOVERY_POLLS" -lt 1000 ]; do
  sleep 0.01
  WATCHER_RECOVERY_POLLS=$((WATCHER_RECOVERY_POLLS + 1))
done
if [[ "$WATCHER_RECOVERY_GROUP" =~ ^[1-9][0-9]*$ ]] &&
  ! kill -0 -- "-$WATCHER_RECOVERY_GROUP" 2>/dev/null; then
  ok "terminal process recovery releases the orphaned cancellation watcher"
else
  ng "terminal process recovery releases the orphaned cancellation watcher"
fi
check "$(jq -r '.lead.process.exitCodeSource' "$WATCHER_RECOVERY_STATUS")" \
  "process" "wrapper death retains the supervisor-measured exit result"

echo "== W01: both rounds start concurrently and promotion preserves evidence =="
ARTIFACT_PROMOTE="$T/artifact-promote"
CONTEXT_PROMOTE="$T/context-promote.json"
write_context "$ARTIFACT_PROMOTE" "$CONTEXT_PROMOTE" wave-promote
prepare_prompts "$CONTEXT_PROMOTE" promote 1 2
WAVE_TEST_DELAY_1=0.2 WAVE_TEST_DELAY_2=0.5
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
start_wave "$CONTEXT_PROMOTE" promote 1 "$T/wave-promote.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_PROMOTE/phase4/waves/wave-1-2/status.json"
wait_for_json "$WAVE_STATUS" \
  '.lead.process.startedAt != null and .speculative.process.startedAt != null' || true
EXPECTED_WAVE_SUPERVISOR_PID=$WAVE_PID
case "$OSTYPE" in
  msys*|cygwin*)
    EXPECTED_WAVE_SUPERVISOR_PID=$(sed -n '1p' \
      "/proc/$WAVE_PID/winpid" 2>/dev/null) ||
      EXPECTED_WAVE_SUPERVISOR_PID=""
    ;;
esac
check "$(jq -r .supervisor.pid "$WAVE_STATUS")" \
  "$EXPECTED_WAVE_SUPERVISOR_PID" \
  "reservation ownership records the actual wave supervisor PID"
wait_for_json "$WAVE_STATUS" '.lead.process.finishedAt != null' || true
write_adjudication "$ARTIFACT_PROMOTE" wave-promote 1 false
cp "$WAVE_STATUS" "$T/wave-promote-before-decision.json"
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_PROMOTE" --wave-status "$WAVE_STATUS" \
  --action promote > "$T/control-promote.out"
wait "$WAVE_PID"
PROMOTE_WAVE_RC=$?
if [ "$PROMOTE_WAVE_RC" -ne 0 ]; then
  sed 's/^/    wave: /' "$T/wave-promote.out"
fi
check "$PROMOTE_WAVE_RC" "0" "promoted wave exits with the lead result"
check "$(jq -r .speculative.state "$WAVE_STATUS")" "promoted" \
  "speculative round is promoted only after the decision"
if [ -d "$ARTIFACT_PROMOTE/phase4/round-2" ] &&
  [ -d "$ARTIFACT_PROMOTE/phase4/waves/wave-1-2/speculative-round-2" ]; then
  ok "promotion retains source evidence and creates the canonical artifact"
else
  ng "promotion retains source evidence and creates the canonical artifact"
fi
SOURCE_PREFIX=$(jq -r '.attempts[0].claude.stdout' \
  "$ARTIFACT_PROMOTE/phase4/waves/wave-1-2/speculative-round-2/status.json")
CANONICAL_PREFIX=$(jq -r '.attempts[0].claude.stdout' \
  "$ARTIFACT_PROMOTE/phase4/round-2/status.json")
case "$SOURCE_PREFIX" in
  *"/waves/wave-1-2/speculative-round-2/"*) ok "source status remains isolated" ;;
  *) ng "source status remains isolated" ;;
esac
case "$CANONICAL_PREFIX" in
  *"/phase4/round-2/"*) ok "promoted status uses canonical paths" ;;
  *) ng "promoted status uses canonical paths" ;;
esac
CLAUDE_1=$(cat "$T/state/round-1-claude.started")
CLAUDE_2=$(cat "$T/state/round-2-claude.started")
START_DELTA=$((CLAUDE_1 > CLAUDE_2 ? CLAUDE_1 - CLAUDE_2 : CLAUDE_2 - CLAUDE_1))
if [ "$START_DELTA" -lt 400 ]; then
  ok "lead and speculative reviewers overlap in wall-clock time"
else
  ng "lead and speculative reviewers overlap in wall-clock time"
fi
check "$(inspect_waves "$CONTEXT_PROMOTE" "$ARTIFACT_PROMOTE")" "[1,2]" \
  "wave validator derives only promoted canonical rounds"
if jq -e '
  .lead.executionEvidence.schema == "deep-review-wave-execution-evidence/v1" and
  .lead.executionEvidence.attempts[0].claude.stdout.sha256 != null and
  .lead.executionEvidence.attempts[0].claude.stderr.sha256 != null and
  .speculative.executionEvidence.attempts[0].codex.stdout.sha256 != null and
  .speculative.executionEvidence.attempts[0].codex.stderr.sha256 != null
' "$WAVE_STATUS" >/dev/null; then
  ok "wave status fixes stdout and stderr digests for both rounds"
else
  ng "wave status fixes stdout and stderr digests for both rounds"
fi
SPECULATIVE_ERROR=$(jq -r '.attempts[0].codex.stderr' \
  "$ARTIFACT_PROMOTE/phase4/waves/wave-1-2/speculative-round-2/status.json")
cp "$SPECULATIVE_ERROR" "$T/speculative-error.backup"
printf 'tampered\n' >> "$SPECULATIVE_ERROR"
if inspect_waves "$CONTEXT_PROMOTE" "$ARTIFACT_PROMOTE" \
  > "$T/tampered-wave.out" 2>&1; then
  ng "wave validation rejects tampered speculative stderr"
else
  ok "wave validation rejects tampered speculative stderr"
fi
mv "$T/speculative-error.backup" "$SPECULATIVE_ERROR"
cp "$T/wave-promote-before-decision.json" "$WAVE_STATUS"
mkdir "$ARTIFACT_PROMOTE/phase4/.round-2.promoting-99999999-abandoned"
jq -n \
  --arg createdAt "2026-08-10T00:00:00.000Z" \
  '{schema:"deep-review-wave-lock/v1",pid:99999999,
    nonce:"abandoned-lock",createdAt:$createdAt}' \
  > "$WAVE_STATUS.lock"
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_PROMOTE" --wave-status "$WAVE_STATUS" \
  --action promote > "$T/control-promote-recovered.out"
if [ ! -e "$WAVE_STATUS.lock" ] &&
  [ ! -e "$ARTIFACT_PROMOTE/phase4/.round-2.promoting-99999999-abandoned" ] &&
  [ "$(jq -r .speculative.state "$WAVE_STATUS")" = "promoted" ]; then
  ok "stale lock and interrupted promotion recover idempotently"
else
  ng "stale lock and interrupted promotion recover idempotently"
fi

echo "== W02: convergence cancels only the running speculative round =="
rm -f "$T/state/"*.started
ARTIFACT_CANCEL="$T/artifact-cancel"
CONTEXT_CANCEL="$T/context-cancel.json"
write_context "$ARTIFACT_CANCEL" "$CONTEXT_CANCEL" wave-cancel
promote_first_wave \
  "$ARTIFACT_CANCEL" "$CONTEXT_CANCEL" cancel-first wave-cancel
write_adjudication "$ARTIFACT_CANCEL" wave-cancel 2 true
prepare_prompts "$CONTEXT_CANCEL" cancel 3 4
WAVE_TEST_DELAY_3=0.2 WAVE_TEST_DELAY_4=10
export WAVE_TEST_DELAY_3 WAVE_TEST_DELAY_4
start_wave "$CONTEXT_CANCEL" cancel 3 "$T/wave-cancel.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_CANCEL/phase4/waves/wave-3-4/status.json"
wait_for_json "$WAVE_STATUS" \
  '.lead.state == "running" and .speculative.state == "running"' || true
kill -KILL "$WAVE_PID" 2>/dev/null || true
wait "$WAVE_PID" 2>/dev/null || true
start_wave "$CONTEXT_CANCEL" cancel 3 "$T/wave-cancel-replacement.out"
WAVE_PID=$STARTED_WAVE_PID
wait_for_json "$WAVE_STATUS" '.lead.process.finishedAt != null' || true
write_adjudication "$ARTIFACT_CANCEL" wave-cancel 3 true
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_CANCEL" --wave-status "$WAVE_STATUS" \
  --action converge > "$T/control-cancel.out"
wait "$WAVE_PID"
check "$?" "0" \
  "replacement wave remains successful when an attached round is cancelled"
check "$(jq -r .speculative.state "$WAVE_STATUS")" \
  "cancelled-after-convergence" "running speculative round is cancelled"
if jq -e '
  .speculative.process.exitCode == 143 and
  .speculative.process.exitCodeSource == "process" and
  .speculative.process.signal == "TERM" and
  .speculative.state == "cancelled-after-convergence"
' "$WAVE_STATUS" >/dev/null; then
  ok "attached cancellation waits for its owner-measured exit code"
else
  ng "attached cancellation waits for its owner-measured exit code"
fi
if [ ! -e "$ARTIFACT_CANCEL/phase4/round-4" ] &&
  jq -e '.attempts[-1].interrupted == true' \
    "$ARTIFACT_CANCEL/phase4/waves/wave-3-4/speculative-round-4/status.json" \
    >/dev/null; then
  ok "cancelled output stays non-canonical with interrupted evidence"
else
  ng "cancelled output stays non-canonical with interrupted evidence"
fi
check "$(inspect_waves "$CONTEXT_CANCEL" "$ARTIFACT_CANCEL")" "[1,2,3]" \
  "convergence is re-derived across a wave boundary"

echo "== W02a: a role child owns final process result publication =="
ARTIFACT_LIVE_RESULT="$T/artifact-live-result"
CONTEXT_LIVE_RESULT="$T/context-live-result.json"
write_context "$ARTIFACT_LIVE_RESULT" "$CONTEXT_LIVE_RESULT" wave-live-result
prepare_prompts "$CONTEXT_LIVE_RESULT" live-result 1 2
LIVE_RESULT_RESERVATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_LIVE_RESULT" --first-round 1 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/live-result-claude-round-1.md" \
  --codex-lead-prompt "$T/live-result-codex-round-1.md" \
  --claude-speculative-prompt "$T/live-result-claude-round-2.md" \
  --codex-speculative-prompt "$T/live-result-codex-round-2.md")
LIVE_RESULT_STATUS=$(printf '%s' "$LIVE_RESULT_RESERVATION" | jq -r .statusPath)
LIVE_RESULT_NONCE=$(printf '%s' "$LIVE_RESULT_RESERVATION" |
  jq -r .status.supervisor.nonce)
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_LIVE_RESULT" \
    --claude-prompt "$T/live-result-claude-round-1.md" \
    --codex-prompt "$T/live-result-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    --wave-status "$LIVE_RESULT_STATUS" --wave-role lead \
    --wave-supervisor-nonce "$LIVE_RESULT_NONCE" \
    > "$T/live-result-lead.out" 2>&1 &
LIVE_RESULT_LEAD_PID=$!
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_LIVE_RESULT" \
    --claude-prompt "$T/live-result-claude-round-2.md" \
    --codex-prompt "$T/live-result-codex-round-2.md" \
    --phase convergence --round 2 --reviewer both --attempt 1 \
    --wave-status "$LIVE_RESULT_STATUS" --wave-role speculative \
    --wave-supervisor-nonce "$LIVE_RESULT_NONCE" \
    > "$T/live-result-speculative.out" 2>&1 &
LIVE_RESULT_SPECULATIVE_PID=$!
wait_for_json "$LIVE_RESULT_STATUS" '
  .lead.process.startedAt != null and
  .speculative.process.startedAt != null
' || true
node "$T/tooling/scripts/review-wave-state.mjs" mark-reviewers-ready \
  --context "$CONTEXT_LIVE_RESULT" --status "$LIVE_RESULT_STATUS" \
  --supervisor-nonce "$LIVE_RESULT_NONCE" \
  > "$T/live-result-reviewers-ready.out"
wait "$LIVE_RESULT_LEAD_PID"
node "$T/tooling/scripts/review-wave-state.mjs" record-result \
  --context "$CONTEXT_LIVE_RESULT" --status "$LIVE_RESULT_STATUS" \
  --role lead --exit-code 0 > "$T/live-result-lead-result.out"
wait "$LIVE_RESULT_SPECULATIVE_PID"
write_adjudication "$ARTIFACT_LIVE_RESULT" wave-live-result 1 false
if jq -e '
  .speculative.process.exitCodeSource == "process" and
  .speculative.state == "completed-awaiting-decision"
' "$LIVE_RESULT_STATUS" >/dev/null; then
  ok "the claimed role publishes its measured result before supervisor recovery"
else
  ng "the claimed role publishes its measured result before supervisor recovery"
fi
node "$T/tooling/scripts/review-wave-state.mjs" decide \
  --context "$CONTEXT_LIVE_RESULT" --status "$LIVE_RESULT_STATUS" \
  --action promote > "$T/live-result-decision.out"
if jq -e '
  .speculative.process.exitCodeSource == "process" and
  .speculative.state == "promoted"
' "$LIVE_RESULT_STATUS" >/dev/null; then
  ok "the fixed decision consumes the role-owned measured result"
else
  ng "the fixed decision consumes the role-owned measured result"
fi

echo "== W03: an already completed speculative round is not promoted =="
rm -f "$T/state/"*.started
ARTIFACT_COMPLETE="$T/artifact-complete"
CONTEXT_COMPLETE="$T/context-complete.json"
write_context "$ARTIFACT_COMPLETE" "$CONTEXT_COMPLETE" wave-complete
promote_first_wave \
  "$ARTIFACT_COMPLETE" "$CONTEXT_COMPLETE" complete-first wave-complete
write_adjudication "$ARTIFACT_COMPLETE" wave-complete 2 true
prepare_prompts "$CONTEXT_COMPLETE" complete 3 4
WAVE_TEST_DELAY_3=0.4 WAVE_TEST_DELAY_4=0.1
export WAVE_TEST_DELAY_3 WAVE_TEST_DELAY_4
start_wave "$CONTEXT_COMPLETE" complete 3 "$T/wave-complete.out"
WAVE_PID=$STARTED_WAVE_PID
wait "$WAVE_PID"
check "$?" "0" "completed speculative wave waits for a decision"
WAVE_STATUS="$ARTIFACT_COMPLETE/phase4/waves/wave-3-4/status.json"
write_adjudication "$ARTIFACT_COMPLETE" wave-complete 3 true
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_COMPLETE" --wave-status "$WAVE_STATUS" \
  --action converge > "$T/control-complete.out"
check "$(jq -r .speculative.state "$WAVE_STATUS")" \
  "completed-but-not-promoted" "completed later output stays non-canonical"
if [ ! -e "$ARTIFACT_COMPLETE/phase4/round-4" ]; then
  ok "completed non-promoted output is excluded from canonical rounds"
else
  ng "completed non-promoted output is excluded from canonical rounds"
fi
check "$(inspect_waves "$CONTEXT_COMPLETE" "$ARTIFACT_COMPLETE")" "[1,2,3]" \
  "completed non-promoted output stays outside the canonical sequence"
printf '{}\n' > \
  "$ARTIFACT_COMPLETE/phase4/waves/wave-3-4/speculative-round-4/adjudication.json"
if inspect_waves "$CONTEXT_COMPLETE" "$ARTIFACT_COMPLETE" \
  > "$T/non-promoted-adjudication.out" 2>&1; then
  ng "wave validation rejects adjudication of non-canonical output"
else
  ok "wave validation rejects adjudication of non-canonical output"
fi
rm "$ARTIFACT_COMPLETE/phase4/waves/wave-3-4/speculative-round-4/adjudication.json"

echo "== W03a: a late TERM cannot rewrite a finalized pair result =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_FINAL_RESULT="$T/artifact-final-result"
CONTEXT_FINAL_RESULT="$T/context-final-result.json"
write_context \
  "$ARTIFACT_FINAL_RESULT" "$CONTEXT_FINAL_RESULT" wave-final-result
promote_first_wave \
  "$ARTIFACT_FINAL_RESULT" "$CONTEXT_FINAL_RESULT" final-result-first \
  wave-final-result
write_adjudication "$ARTIFACT_FINAL_RESULT" wave-final-result 2 true
prepare_prompts "$CONTEXT_FINAL_RESULT" final-result 3 4
WAVE_TEST_DELAY_3=0.2 WAVE_TEST_DELAY_4=0.1
DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_ROLE=speculative
DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_MARKER_PREFIX="$T/evidence-finalized-marker"
DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_DELAY_SECONDS=2
DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_ROLE=speculative
DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_MARKER_PREFIX="$T/final-result-marker"
DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_DELAY_SECONDS=2
export WAVE_TEST_DELAY_3 WAVE_TEST_DELAY_4
start_wave \
  "$CONTEXT_FINAL_RESULT" final-result 3 "$T/wave-final-result.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_FINAL_RESULT/phase4/waves/wave-3-4/status.json"
wait_for_file "$T/evidence-finalized-marker.speculative" || true
FINAL_RESULT_SIGNAL_PID=$(jq -r .speculative.process.signalPid "$WAVE_STATUS")
if kill -TERM -- "-$FINAL_RESULT_SIGNAL_PID" 2>/dev/null ||
  kill -TERM "$FINAL_RESULT_SIGNAL_PID" 2>/dev/null; then
  ok "the pair receives TERM at the evidence-finalization boundary"
else
  ng "the pair receives TERM at the evidence-finalization boundary"
fi
wait_for_file "$T/final-result-marker.speculative" || true
write_adjudication "$ARTIFACT_FINAL_RESULT" wave-final-result 3 true
node "$T/tooling/scripts/review-wave-state.mjs" decide \
  --context "$CONTEXT_FINAL_RESULT" --status "$WAVE_STATUS" \
  --action converge > "$T/final-result-decision.out"
if kill -TERM -- "-$FINAL_RESULT_SIGNAL_PID" 2>/dev/null ||
  kill -TERM "$FINAL_RESULT_SIGNAL_PID" 2>/dev/null; then
  ok "the finalized pair receives the late TERM"
else
  ng "the finalized pair receives the late TERM"
fi
wait "$WAVE_PID"
check "$?" "0" "a late TERM preserves the successful wave result"
unset DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_ROLE
unset DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_MARKER_PREFIX
unset DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_DELAY_SECONDS
unset DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_ROLE
unset DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_MARKER_PREFIX
unset DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_DELAY_SECONDS
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_FINAL_RESULT" --wave-status "$WAVE_STATUS" \
  --action converge > "$T/control-final-result.out"
if jq -e '
  .speculative.state == "completed-but-not-promoted" and
  .speculative.process.exitCode == 0 and
  .speculative.executionEvidence.complete == true
' "$WAVE_STATUS" >/dev/null; then
  ok "the finalized wave evidence retains the successful process result"
else
  ng "the finalized wave evidence retains the successful process result"
fi
if jq -e '.interrupted == false' \
  "$ARTIFACT_FINAL_RESULT/phase4/waves/wave-3-4/speculative-round-4/attempt-1/status.json" \
  >/dev/null; then
  ok "the immutable attempt status is not rewritten as interrupted"
else
  ng "the immutable attempt status is not rewritten as interrupted"
fi
check "$(inspect_waves "$CONTEXT_FINAL_RESULT" "$ARTIFACT_FINAL_RESULT")" \
  "[1,2,3]" "wave validation accepts the unchanged execution evidence"

echo "== W03b: missing non-canonical pair status remains recoverable =="
rm -f "$T/state/"*.started
ARTIFACT_MISSING_STATUS="$T/artifact-missing-status"
CONTEXT_MISSING_STATUS="$T/context-missing-status.json"
write_context \
  "$ARTIFACT_MISSING_STATUS" "$CONTEXT_MISSING_STATUS" wave-missing-status
promote_first_wave \
  "$ARTIFACT_MISSING_STATUS" "$CONTEXT_MISSING_STATUS" \
  missing-status-first wave-missing-status
write_adjudication "$ARTIFACT_MISSING_STATUS" wave-missing-status 2 true
prepare_prompts "$CONTEXT_MISSING_STATUS" missing-status 3 4
WAVE_TEST_DELAY_3=0.3 WAVE_TEST_DELAY_4=0.1
export WAVE_TEST_DELAY_3 WAVE_TEST_DELAY_4
start_wave \
  "$CONTEXT_MISSING_STATUS" missing-status 3 "$T/wave-missing-status.out"
WAVE_PID=$STARTED_WAVE_PID
wait "$WAVE_PID"
check "$?" "0" "completed wave can await its decision before reconciliation"
WAVE_STATUS="$ARTIFACT_MISSING_STATUS/phase4/waves/wave-3-4/status.json"
rm "$ARTIFACT_MISSING_STATUS/phase4/waves/wave-3-4/speculative-round-4/status.json"
write_adjudication "$ARTIFACT_MISSING_STATUS" wave-missing-status 3 true
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_MISSING_STATUS" --wave-status "$WAVE_STATUS" \
  --action converge > "$T/control-missing-status.out"
if jq -e '
  .speculative.state == "cancelled-after-convergence" and
  .speculative.executionEvidence.complete == false
' "$WAVE_STATUS" >/dev/null; then
  ok "recorded process completion repairs missing non-canonical status fail-closed"
else
  ng "recorded process completion repairs missing non-canonical status fail-closed"
fi
check "$(inspect_waves "$CONTEXT_MISSING_STATUS" "$ARTIFACT_MISSING_STATUS")" \
  "[1,2,3]" "missing irrelevant status does not corrupt canonical convergence"

echo "== W03c: missing promotion status terminalizes the run =="
rm -f "$T/state/"*.started
ARTIFACT_MISSING_PROMOTE="$T/artifact-missing-promote"
CONTEXT_MISSING_PROMOTE="$T/context-missing-promote.json"
write_context \
  "$ARTIFACT_MISSING_PROMOTE" "$CONTEXT_MISSING_PROMOTE" wave-missing-promote
prepare_prompts "$CONTEXT_MISSING_PROMOTE" missing-promote 1 2
unset WAVE_TEST_CLAUDE_FAIL_ROUND WAVE_TEST_CODEX_FAIL_ROUND
WAVE_TEST_DELAY_1=0.2 WAVE_TEST_DELAY_2=0.1
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
start_wave \
  "$CONTEXT_MISSING_PROMOTE" missing-promote 1 "$T/wave-missing-promote.out"
WAVE_PID=$STARTED_WAVE_PID
wait "$WAVE_PID"
check "$?" "0" "promotion fixture completes both pair processes"
WAVE_STATUS="$ARTIFACT_MISSING_PROMOTE/phase4/waves/wave-1-2/status.json"
cp "$ARTIFACT_MISSING_PROMOTE/phase4/waves/wave-1-2/speculative-round-2/status.json" \
  "$T/missing-promote-late-status.json"
rm "$ARTIFACT_MISSING_PROMOTE/phase4/waves/wave-1-2/speculative-round-2/status.json"
write_adjudication "$ARTIFACT_MISSING_PROMOTE" wave-missing-promote 1 false
WAVE_CONTROL_WAIT_SECONDS=1 \
  bash "$T/tooling/scripts/control-review-wave.sh" \
    --context "$CONTEXT_MISSING_PROMOTE" --wave-status "$WAVE_STATUS" \
    --action promote > "$T/control-missing-promote.out" 2>&1 &
CONTROL_PID=$!
CONTROL_POLLS=0
while kill -0 "$CONTROL_PID" 2>/dev/null && [ "$CONTROL_POLLS" -lt 100 ]; do
  sleep 0.05
  CONTROL_POLLS=$((CONTROL_POLLS + 1))
done
if kill -0 "$CONTROL_PID" 2>/dev/null; then
  /bin/kill -TERM "$CONTROL_PID" 2>/dev/null || true
  wait "$CONTROL_PID" 2>/dev/null
  ng "missing promotion status terminalizes without waiting"
else
  wait "$CONTROL_PID"
  check "$?" "30" "missing promotion status returns the incomplete-run exit"
fi
if jq -e '
  .decision.action == "promote" and
  .speculative.state == "aborted-incomplete" and
  .speculative.nonPromotionReason == "incomplete-execution" and
  .speculative.executionEvidence.complete == false
' "$WAVE_STATUS" >/dev/null; then
  ok "missing promotion status retains an explicit incomplete terminal state"
else
  ng "missing promotion status retains an explicit incomplete terminal state"
fi
check "$(inspect_waves "$CONTEXT_MISSING_PROMOTE" "$ARTIFACT_MISSING_PROMOTE")" \
  "[1]" "incomplete speculative evidence stays outside canonical rounds"

write_prompt \
  "$CONTEXT_MISSING_PROMOTE" "$T/missing-promote-claude-round-3.md" claude 3
write_prompt \
  "$CONTEXT_MISSING_PROMOTE" "$T/missing-promote-codex-round-3.md" codex 3
node "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_MISSING_PROMOTE" --first-round 2 \
  --supervisor-pid "$WAVE_TEST_SUPERVISOR_PID" \
  --claude-lead-prompt "$T/missing-promote-claude-round-2.md" \
  --codex-lead-prompt "$T/missing-promote-codex-round-2.md" \
  --claude-speculative-prompt "$T/missing-promote-claude-round-3.md" \
  --codex-speculative-prompt "$T/missing-promote-codex-round-3.md" \
  > "$T/reserve-after-incomplete.out" 2>&1
check "$?" "1" "an incomplete wave requires a new review run"
node "$T/tooling/scripts/review-wave-state.mjs" record-result \
  --context "$CONTEXT_MISSING_PROMOTE" --status "$WAVE_STATUS" \
  --role speculative --exit-code 0 > "$T/late-incomplete-result.out" 2>&1
check "$?" "1" "a late process result cannot reopen an incomplete wave"
cp "$T/missing-promote-late-status.json" \
  "$ARTIFACT_MISSING_PROMOTE/phase4/waves/wave-1-2/speculative-round-2/status.json"
if inspect_waves "$CONTEXT_MISSING_PROMOTE" "$ARTIFACT_MISSING_PROMOTE" \
  > "$T/late-incomplete-status.out" 2>&1; then
  ng "late pair status cannot reopen an incomplete wave"
else
  ok "late pair status cannot reopen an incomplete wave"
fi

ARTIFACT_SLOW_CONTROL="$T/artifact-slow-control"
CONTEXT_SLOW_CONTROL="$T/context-slow-control.json"
write_context "$ARTIFACT_SLOW_CONTROL" "$CONTEXT_SLOW_CONTROL" wave-slow-control
prepare_prompts "$CONTEXT_SLOW_CONTROL" slow-control 1 2
SLOW_RESERVATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_SLOW_CONTROL" --first-round 1 \
  --supervisor-pid 99999999 \
  --claude-lead-prompt "$T/slow-control-claude-round-1.md" \
  --codex-lead-prompt "$T/slow-control-codex-round-1.md" \
  --claude-speculative-prompt "$T/slow-control-claude-round-2.md" \
  --codex-speculative-prompt "$T/slow-control-codex-round-2.md")
SLOW_STATUS=$(printf '%s' "$SLOW_RESERVATION" | jq -r .statusPath)
SLOW_NONCE=$(printf '%s' "$SLOW_RESERVATION" | jq -r .status.supervisor.nonce)
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_SLOW_CONTROL" \
    --claude-prompt "$T/slow-control-claude-round-1.md" \
    --codex-prompt "$T/slow-control-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 1 \
    --wave-status "$SLOW_STATUS" --wave-role lead \
    --wave-supervisor-nonce "$SLOW_NONCE" \
    > "$T/slow-control-lead.out" 2>&1 &
SLOW_CONTROL_LEAD_PID=$!
wait_for_json "$SLOW_STATUS" '.lead.process.startedAt != null' || true
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_SLOW_CONTROL" --status "$SLOW_STATUS" \
  --role speculative --pid "$WAVE_TEST_SUPERVISOR_PID" \
  > "$T/slow-control-speculative-start.out"
node "$T/tooling/scripts/review-wave-state.mjs" mark-reviewers-ready \
  --context "$CONTEXT_SLOW_CONTROL" --status "$SLOW_STATUS" \
  --supervisor-nonce "$SLOW_NONCE" \
  > "$T/slow-control-reviewers-ready.out"
wait "$SLOW_CONTROL_LEAD_PID"
write_adjudication "$ARTIFACT_SLOW_CONTROL" wave-slow-control 1 false

mkdir -p "$T/slow-node-bin"
cat > "$T/slow-node-bin/node" <<'SH'
#!/usr/bin/env bash
set -eu
count=0
if [ -f "$WAVE_TEST_NODE_COUNT" ]; then
  count=$(cat "$WAVE_TEST_NODE_COUNT")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$WAVE_TEST_NODE_COUNT"
if [ "$count" -le 2 ]; then
  sleep 0.6
fi
exec "$WAVE_TEST_REAL_NODE" "$@"
SH
chmod +x "$T/slow-node-bin/node"
: > "$T/slow-node-count"
WAVE_TEST_NODE_COUNT="$T/slow-node-count" \
WAVE_TEST_REAL_NODE="$(command -v node)" \
WAVE_CONTROL_WAIT_SECONDS=1 \
PATH="$T/slow-node-bin:$PATH" \
  bash "$T/tooling/scripts/control-review-wave.sh" \
    --context "$CONTEXT_SLOW_CONTROL" --wave-status "$SLOW_STATUS" \
    --action promote > "$T/control-slow-node.out" 2>&1
check "$?" "1" "controller wait remains bounded when Node startup is slow"
if [ "$(cat "$T/slow-node-count")" -le 4 ]; then
  ok "controller timeout includes subprocess startup time"
else
  ng "controller timeout includes subprocess startup time"
fi

echo "== W03c1: a dead speculative child cannot hang its supervisor =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_DEAD_SPECULATIVE="$T/artifact-dead-speculative"
CONTEXT_DEAD_SPECULATIVE="$T/context-dead-speculative.json"
write_context \
  "$ARTIFACT_DEAD_SPECULATIVE" "$CONTEXT_DEAD_SPECULATIVE" \
  wave-dead-speculative
prepare_prompts "$CONTEXT_DEAD_SPECULATIVE" dead-speculative 1 2
WAVE_TEST_DELAY_1=0.2 WAVE_TEST_DELAY_2=5
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
start_wave \
  "$CONTEXT_DEAD_SPECULATIVE" dead-speculative 1 \
  "$T/wave-dead-speculative.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_DEAD_SPECULATIVE/phase4/waves/wave-1-2/status.json"
wait_for_json "$WAVE_STATUS" \
  '.lead.process.finishedAt != null and .speculative.state == "running"' || true
for started in \
  "$T/state/round-2-claude.started" "$T/state/round-2-codex.started"; do
  wait_for_file "$started" || true
done
write_adjudication "$ARTIFACT_DEAD_SPECULATIVE" wave-dead-speculative 1 false
WAVE_CONTROL_WAIT_SECONDS=5 \
  bash "$T/tooling/scripts/control-review-wave.sh" \
    --context "$CONTEXT_DEAD_SPECULATIVE" --wave-status "$WAVE_STATUS" \
    --action promote > "$T/control-dead-speculative.out" 2>&1 &
CONTROL_PID=$!
wait_for_json "$WAVE_STATUS" '.decision.action == "promote"' || true
SPECULATIVE_SIGNAL_PID=$(jq -r .speculative.process.signalPid "$WAVE_STATUS")
kill -KILL -- "-$SPECULATIVE_SIGNAL_PID" 2>/dev/null ||
  /bin/kill -KILL "$SPECULATIVE_SIGNAL_PID" 2>/dev/null || true
wait "$WAVE_PID"
check "$?" "0" "a dead speculative child releases the wave supervisor"
wait "$CONTROL_PID"
check "$?" "30" "a dead speculative child fails the controller immediately"
if jq -e '
  .speculative.state == "aborted-incomplete" and
  .speculative.process.exitCode == 137 and
  .speculative.process.exitCodeSource == "process" and
  .speculative.executionEvidence.complete == false
' "$WAVE_STATUS" >/dev/null; then
  ok "the supervisor records the measured incomplete process result"
else
  ng "the supervisor records the measured incomplete process result"
fi
for pid_file in \
  "$T/state/round-2-claude.pid" "$T/state/round-2-codex.pid"; do
  if [ -f "$pid_file" ]; then
    reviewer_pid=$(cat "$pid_file")
    kill -KILL -- "-$reviewer_pid" 2>/dev/null ||
      kill -KILL "$reviewer_pid" 2>/dev/null || true
  fi
done

echo "== W03c2: attached PID liveness cannot wait forever =="
ARTIFACT_RECOVERY_BOUND="$T/artifact-recovery-bound"
CONTEXT_RECOVERY_BOUND="$T/context-recovery-bound.json"
write_context \
  "$ARTIFACT_RECOVERY_BOUND" "$CONTEXT_RECOVERY_BOUND" wave-recovery-bound
prepare_prompts "$CONTEXT_RECOVERY_BOUND" recovery-bound 1 2
RECOVERY_BOUND_RESERVATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_RECOVERY_BOUND" --first-round 1 \
  --supervisor-pid 99999999 \
  --claude-lead-prompt "$T/recovery-bound-claude-round-1.md" \
  --codex-lead-prompt "$T/recovery-bound-codex-round-1.md" \
  --claude-speculative-prompt "$T/recovery-bound-claude-round-2.md" \
  --codex-speculative-prompt "$T/recovery-bound-codex-round-2.md")
RECOVERY_BOUND_STATUS=$(printf '%s' "$RECOVERY_BOUND_RESERVATION" |
  jq -r .statusPath)
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_RECOVERY_BOUND" --status "$RECOVERY_BOUND_STATUS" \
  --role lead --pid "$WAVE_TEST_SUPERVISOR_PID" \
  > "$T/recovery-bound-lead-start.out"
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_RECOVERY_BOUND" --status "$RECOVERY_BOUND_STATUS" \
  --role speculative --pid "$WAVE_TEST_SUPERVISOR_PID" \
  > "$T/recovery-bound-speculative-start.out"
RECOVERY_BOUND_STARTED_AT=$SECONDS
WAVE_RECOVERY_WAIT_SECONDS=1 WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-wave.sh" \
    --context "$CONTEXT_RECOVERY_BOUND" --first-round 1 \
    --claude-lead-prompt "$T/recovery-bound-claude-round-1.md" \
    --codex-lead-prompt "$T/recovery-bound-codex-round-1.md" \
    --claude-speculative-prompt "$T/recovery-bound-claude-round-2.md" \
    --codex-speculative-prompt "$T/recovery-bound-codex-round-2.md" \
    > "$T/recovery-bound-wave.out" 2>&1
check "$?" "1" "attached PID-only liveness stops at the recovery deadline"
if [ "$((SECONDS - RECOVERY_BOUND_STARTED_AT))" -le 5 ]; then
  ok "recovery timeout remains bounded through termination cleanup"
else
  ng "recovery timeout remains bounded through termination cleanup"
fi

echo "== W03c3: replacement recovery terminalizes a missing pair status =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_REPLACEMENT_ABORT="$T/artifact-replacement-abort"
CONTEXT_REPLACEMENT_ABORT="$T/context-replacement-abort.json"
write_context \
  "$ARTIFACT_REPLACEMENT_ABORT" "$CONTEXT_REPLACEMENT_ABORT" \
  wave-replacement-abort
prepare_prompts "$CONTEXT_REPLACEMENT_ABORT" replacement-abort 1 2
WAVE_TEST_DELAY_1=0.2 WAVE_TEST_DELAY_2=5
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
start_wave \
  "$CONTEXT_REPLACEMENT_ABORT" replacement-abort 1 \
  "$T/wave-replacement-abort.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_REPLACEMENT_ABORT/phase4/waves/wave-1-2/status.json"
wait_for_json "$WAVE_STATUS" \
  '.lead.process.finishedAt != null and .speculative.state == "running"' || true
for started in \
  "$T/state/round-2-claude.started" "$T/state/round-2-codex.started"; do
  wait_for_file "$started" || true
done
SPECULATIVE_SIGNAL_PID=$(jq -r .speculative.process.signalPid "$WAVE_STATUS")
/bin/kill -KILL "$WAVE_PID" 2>/dev/null || true
wait "$WAVE_PID" 2>/dev/null || true
kill -KILL -- "-$SPECULATIVE_SIGNAL_PID" 2>/dev/null ||
  /bin/kill -KILL "$SPECULATIVE_SIGNAL_PID" 2>/dev/null || true
start_wave \
  "$CONTEXT_REPLACEMENT_ABORT" replacement-abort 1 \
  "$T/wave-replacement-abort-recovered.out"
REPLACEMENT_WAVE_PID=$STARTED_WAVE_PID
wait_for_json "$WAVE_STATUS" '
  .speculative.process.finishedAt != null and
  .speculative.process.exitCodeSource == "reconstructed"
' || true
write_adjudication \
  "$ARTIFACT_REPLACEMENT_ABORT" wave-replacement-abort 1 false
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_REPLACEMENT_ABORT" --wave-status "$WAVE_STATUS" \
  --action promote > "$T/control-replacement-abort.out" 2>&1
check "$?" "30" "recovered missing status returns the incomplete-run exit"
wait "$REPLACEMENT_WAVE_PID"
check "$?" "0" "replacement supervisor exits after terminal recovery"
if jq -e '
  .speculative.state == "aborted-incomplete" and
  .speculative.process.exitCodeSource == "reconstructed" and
  .speculative.executionEvidence.complete == false
' "$WAVE_STATUS" >/dev/null; then
  ok "replacement recovery preserves incomplete execution evidence"
else
  ng "replacement recovery preserves incomplete execution evidence"
fi
for pid_file in \
  "$T/state/round-2-claude.pid" "$T/state/round-2-codex.pid"; do
  if [ -f "$pid_file" ]; then
    reviewer_pid=$(cat "$pid_file")
    kill -KILL -- "-$reviewer_pid" 2>/dev/null ||
      kill -KILL "$reviewer_pid" 2>/dev/null || true
  fi
done

echo "== W03d: lead failure without pair status can terminate fail-closed =="
ARTIFACT_MISSING_LEAD="$T/artifact-missing-lead"
CONTEXT_MISSING_LEAD="$T/context-missing-lead.json"
write_context "$ARTIFACT_MISSING_LEAD" "$CONTEXT_MISSING_LEAD" wave-missing-lead
prepare_prompts "$CONTEXT_MISSING_LEAD" missing-lead 1 2
MISSING_LEAD_RESERVATION=$(node \
  "$T/tooling/scripts/review-wave-state.mjs" reserve \
  --context "$CONTEXT_MISSING_LEAD" --first-round 1 \
  --supervisor-pid 99999999 \
  --claude-lead-prompt "$T/missing-lead-claude-round-1.md" \
  --codex-lead-prompt "$T/missing-lead-codex-round-1.md" \
  --claude-speculative-prompt "$T/missing-lead-claude-round-2.md" \
  --codex-speculative-prompt "$T/missing-lead-codex-round-2.md")
MISSING_LEAD_STATUS=$(printf '%s' "$MISSING_LEAD_RESERVATION" | jq -r .statusPath)
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_MISSING_LEAD" --status "$MISSING_LEAD_STATUS" \
  --role lead --pid 7101 > "$T/missing-lead-start.out"
node "$T/tooling/scripts/review-wave-state.mjs" record-result \
  --context "$CONTEXT_MISSING_LEAD" --status "$MISSING_LEAD_STATUS" \
  --role lead --exit-code 2 > "$T/missing-lead-result.out"
node "$T/tooling/scripts/review-wave-state.mjs" record-start \
  --context "$CONTEXT_MISSING_LEAD" --status "$MISSING_LEAD_STATUS" \
  --role speculative --pid 7102 > "$T/missing-speculative-start.out"
node "$T/tooling/scripts/review-wave-state.mjs" record-result \
  --context "$CONTEXT_MISSING_LEAD" --status "$MISSING_LEAD_STATUS" \
  --role speculative --exit-code 143 --signal TERM \
  > "$T/missing-speculative-result.out"
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_MISSING_LEAD" --wave-status "$MISSING_LEAD_STATUS" \
  --action prior-failure > "$T/control-missing-lead.out"
check "$?" "0" "missing lead status accepts only a prior-failure decision"
if jq -e '
  .decision.action == "prior-failure" and
  .lead.state == "canonical-failed" and
  .lead.executionEvidence.complete == false and
  .speculative.state == "cancelled-after-prior-failure"
' "$MISSING_LEAD_STATUS" >/dev/null; then
  ok "unrecoverable lead failure terminates the speculative wave fail-closed"
else
  ng "unrecoverable lead failure terminates the speculative wave fail-closed"
fi
node "$T/tooling/scripts/review-wave-state.mjs" decide \
  --context "$CONTEXT_MISSING_LEAD" --status "$MISSING_LEAD_STATUS" \
  --action promote > "$T/promote-missing-lead.out" 2>&1
check "$?" "1" "missing lead status can never be promoted"

echo "== W04: exhausted lead failure cancels the speculative process =="
rm -f "$T/state/"*.started
ARTIFACT_FAIL="$T/artifact-fail"
CONTEXT_FAIL="$T/context-fail.json"
write_context "$ARTIFACT_FAIL" "$CONTEXT_FAIL" wave-fail
promote_first_wave "$ARTIFACT_FAIL" "$CONTEXT_FAIL" fail-first wave-fail
write_adjudication "$ARTIFACT_FAIL" wave-fail 2 false
prepare_prompts "$CONTEXT_FAIL" fail 3 4
WAVE_TEST_DELAY_3=0.1 WAVE_TEST_DELAY_4=10
WAVE_TEST_CLAUDE_FAIL_ROUND=3
export WAVE_TEST_DELAY_3 WAVE_TEST_DELAY_4 WAVE_TEST_CLAUDE_FAIL_ROUND
start_wave "$CONTEXT_FAIL" fail 3 "$T/wave-fail.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_FAIL/phase4/waves/wave-3-4/status.json"
wait_for_file "$ARTIFACT_FAIL/phase4/round-3/status.json" || true
WAVE_TEST_STATE="$T/state" WAVE_TEST_CLAUDE_FAIL_ROUND=3 \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_FAIL" \
    --claude-prompt "$T/fail-claude-round-3.md" \
    --phase convergence --round 3 --reviewer claude --attempt 2 \
    --wave-status "$WAVE_STATUS" --wave-role lead \
    > "$T/retry-fail.out" 2>&1
RETRY_RC=$?
check "$RETRY_RC" "20" "failed lead retry remains fail-closed"
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_FAIL" --wave-status "$WAVE_STATUS" \
  --action prior-failure > "$T/control-fail.out"
wait "$WAVE_PID"
WAVE_RC=$?
check "$WAVE_RC" "20" "wave reports the exhausted lead failure"
check "$(jq -r .speculative.state "$WAVE_STATUS")" \
  "cancelled-after-prior-failure" "prior failure cancels speculative work"

echo "== W05: a promoted failed attempt can retry without breaking provenance =="
rm -f "$T/state/"*.started
ARTIFACT_RETRY="$T/artifact-retry"
CONTEXT_RETRY="$T/context-retry.json"
write_context "$ARTIFACT_RETRY" "$CONTEXT_RETRY" wave-retry
prepare_prompts "$CONTEXT_RETRY" retry 1 2
WAVE_TEST_DELAY_1=0.1 WAVE_TEST_DELAY_2=0.1
WAVE_TEST_CLAUDE_FAIL_ROUND=2
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2 WAVE_TEST_CLAUDE_FAIL_ROUND
start_wave "$CONTEXT_RETRY" retry 1 "$T/wave-retry.out"
WAVE_PID=$STARTED_WAVE_PID
wait "$WAVE_PID"
check "$?" "0" "speculative failure does not fail a successful lead round"
WAVE_STATUS="$ARTIFACT_RETRY/phase4/waves/wave-1-2/status.json"
write_adjudication "$ARTIFACT_RETRY" wave-retry 1 false
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_RETRY" --wave-status "$WAVE_STATUS" \
  --action promote > "$T/control-retry.out"
unset WAVE_TEST_CLAUDE_FAIL_ROUND
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_RETRY" \
    --claude-prompt "$T/retry-claude-round-2.md" \
    --phase convergence --round 2 --reviewer claude --attempt 2 \
    > "$T/promoted-retry.out"
check "$?" "0" "promoted speculative failure uses the existing retry contract"
check "$(jq -r '.attempts | length' "$ARTIFACT_RETRY/phase4/round-2/status.json")" \
  "2" "promoted canonical status retains both attempts"
check "$(inspect_waves "$CONTEXT_RETRY" "$ARTIFACT_RETRY")" "[1,2]" \
  "promotion provenance survives a canonical retry"

echo "== W06: outer termination reaps both isolated pair process groups =="
rm -f "$T/state/"*.started
ARTIFACT_TERM="$T/artifact-term"
CONTEXT_TERM="$T/context-term.json"
write_context "$ARTIFACT_TERM" "$CONTEXT_TERM" wave-term
prepare_prompts "$CONTEXT_TERM" term 1 2
WAVE_TEST_DELAY_1=10 WAVE_TEST_DELAY_2=10
WAVE_TEST_TERM_CLEANUP_DELAY=3
DEEP_REVIEW_TEST_ROLE_CLAIM_TERMINATION_GRACE_SECONDS=1
unset WAVE_TEST_CLAUDE_FAIL_ROUND WAVE_TEST_CODEX_FAIL_ROUND
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2 WAVE_TEST_TERM_CLEANUP_DELAY
export DEEP_REVIEW_TEST_ROLE_CLAIM_TERMINATION_GRACE_SECONDS
start_wave "$CONTEXT_TERM" term 1 "$T/wave-term.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_TERM/phase4/waves/wave-1-2/status.json"
wait_for_json "$WAVE_STATUS" \
  '.lead.state == "running" and .speculative.state == "running"' || true
for started in \
  "$T/state/round-1-claude.started" "$T/state/round-1-codex.started" \
  "$T/state/round-2-claude.started" "$T/state/round-2-codex.started"; do
  wait_for_file "$started" || true
done
LEAD_GROUP=$(jq -r .lead.process.pid "$WAVE_STATUS")
SPECULATIVE_GROUP=$(jq -r .speculative.process.pid "$WAVE_STATUS")
/bin/kill -TERM "$WAVE_PID"
wait "$WAVE_PID"
check "$?" "143" "outer TERM is propagated by the wave runner"
unset WAVE_TEST_TERM_CLEANUP_DELAY
unset DEEP_REVIEW_TEST_ROLE_CLAIM_TERMINATION_GRACE_SECONDS
if jq -e '
  .lead.process.signal == "TERM" and
  .speculative.process.signal == "TERM" and
  .lead.executionEvidence.attempts[0].interrupted == true and
  .speculative.executionEvidence.attempts[0].interrupted == true
' "$WAVE_STATUS" >/dev/null; then
  ok "outer TERM atomically records both interrupted pair results"
else
  ng "outer TERM atomically records both interrupted pair results"
  jq '{lead:.lead.process,speculative:.speculative.process,
    leadAttempt:.lead.executionEvidence.attempts[0],
    speculativeAttempt:.speculative.executionEvidence.attempts[0]}' \
    "$WAVE_STATUS"
fi
if ! kill -0 -- "-$LEAD_GROUP" 2>/dev/null &&
  ! kill -0 -- "-$SPECULATIVE_GROUP" 2>/dev/null; then
  ok "outer TERM leaves neither pair process group running"
else
  ng "outer TERM leaves neither pair process group running"
fi

echo "== W07: exhausted two-sided lead failure remains fail-closed =="
rm -f "$T/state/"*.started
ARTIFACT_BOTH_FAIL="$T/artifact-both-fail"
CONTEXT_BOTH_FAIL="$T/context-both-fail.json"
write_context "$ARTIFACT_BOTH_FAIL" "$CONTEXT_BOTH_FAIL" wave-both-fail
prepare_prompts "$CONTEXT_BOTH_FAIL" both-fail 1 2
WAVE_TEST_DELAY_1=0.1 WAVE_TEST_DELAY_2=10
WAVE_TEST_CLAUDE_FAIL_ROUND=1
WAVE_TEST_CODEX_FAIL_ROUND=1
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2 \
  WAVE_TEST_CLAUDE_FAIL_ROUND WAVE_TEST_CODEX_FAIL_ROUND
start_wave "$CONTEXT_BOTH_FAIL" both-fail 1 "$T/wave-both-fail.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_BOTH_FAIL/phase4/waves/wave-1-2/status.json"
wait_for_file "$ARTIFACT_BOTH_FAIL/phase4/round-1/status.json" || true
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_BOTH_FAIL" \
    --claude-prompt "$T/both-fail-claude-round-1.md" \
    --codex-prompt "$T/both-fail-codex-round-1.md" \
    --phase convergence --round 1 --reviewer both --attempt 2 \
    --wave-status "$WAVE_STATUS" --wave-role lead \
    > "$T/retry-both-fail.out" 2>&1
check "$?" "21" "two-sided retry failure retains pair exit semantics"
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_BOTH_FAIL" --wave-status "$WAVE_STATUS" \
  --action prior-failure > "$T/control-both-fail.out"
node "$T/tooling/scripts/review-wave-state.mjs" authorize \
  --context "$CONTEXT_BOTH_FAIL" --status "$WAVE_STATUS" \
  --role lead --round 1 --attempt 2 --reviewer both \
  --claude-prompt "$T/both-fail-claude-round-1.md" \
  --claude-prompt-purpose review \
  --codex-prompt "$T/both-fail-codex-round-1.md" \
  --codex-prompt-purpose review > "$T/authorize-after-decision.out" 2>&1
check "$?" "1" "fixed prior-failure decision rejects a later lead retry"
wait "$WAVE_PID"
check "$?" "21" "wave reports the exhausted two-sided lead failure"
check "$(jq -r .speculative.state "$WAVE_STATUS")" \
  "cancelled-after-prior-failure" \
  "two-sided lead failure cancels only speculative work"

echo "== W07b: every failed reviewer must exhaust its own retry =="
rm -f "$T/state/"*.started
ARTIFACT_SPLIT_FAIL="$T/artifact-split-fail"
CONTEXT_SPLIT_FAIL="$T/context-split-fail.json"
write_context "$ARTIFACT_SPLIT_FAIL" "$CONTEXT_SPLIT_FAIL" wave-split-fail
prepare_prompts "$CONTEXT_SPLIT_FAIL" split-fail 1 2
WAVE_TEST_DELAY_1=0.1 WAVE_TEST_DELAY_2=10
WAVE_TEST_CLAUDE_FAIL_ROUND=1
WAVE_TEST_CODEX_FAIL_ROUND=1
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
export WAVE_TEST_CLAUDE_FAIL_ROUND WAVE_TEST_CODEX_FAIL_ROUND
start_wave "$CONTEXT_SPLIT_FAIL" split-fail 1 "$T/wave-split-fail.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_SPLIT_FAIL/phase4/waves/wave-1-2/status.json"
wait_for_file "$ARTIFACT_SPLIT_FAIL/phase4/round-1/status.json" || true
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_SPLIT_FAIL" \
    --claude-prompt "$T/split-fail-claude-round-1.md" \
    --phase convergence --round 1 --reviewer claude --attempt 2 \
    --wave-status "$WAVE_STATUS" --wave-role lead \
    > "$T/retry-split-fail-claude.out" 2>&1
check "$?" "21" "single-reviewer retry preserves the two-sided failure"
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_SPLIT_FAIL" --wave-status "$WAVE_STATUS" \
  --action prior-failure > "$T/control-split-fail-early.out" 2>&1
check "$?" "1" "prior failure waits for the other failed reviewer retry"
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_SPLIT_FAIL" \
    --codex-prompt "$T/split-fail-codex-round-1.md" \
    --phase convergence --round 1 --reviewer codex --attempt 3 \
    --wave-status "$WAVE_STATUS" --wave-role lead \
    > "$T/retry-split-fail-codex.out" 2>&1
check "$?" "21" "remaining failed reviewer can consume its retry"
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_SPLIT_FAIL" --wave-status "$WAVE_STATUS" \
  --action prior-failure > "$T/control-split-fail.out"
check "$?" "0" "prior failure is accepted after every failed reviewer exhausts"
wait "$WAVE_PID"
check "$?" "21" "split retries retain the exhausted lead failure"

echo "== W08: a lead reviewer can use its attested finalize-only resume =="
rm -f "$T/state/"*.started
ARTIFACT_RESUME="$T/artifact-resume"
CONTEXT_RESUME="$T/context-resume.json"
write_context "$ARTIFACT_RESUME" "$CONTEXT_RESUME" wave-resume
prepare_prompts "$CONTEXT_RESUME" resume 1 2
write_resume_prompt \
  "$CONTEXT_RESUME" "$T/resume-claude-round-1-finalize.md" claude 1
WAVE_TEST_DELAY_1=0.1 WAVE_TEST_DELAY_2=0.1
WAVE_TEST_CLAUDE_FAIL_ROUND=1
unset WAVE_TEST_CODEX_FAIL_ROUND
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2 WAVE_TEST_CLAUDE_FAIL_ROUND
start_wave "$CONTEXT_RESUME" resume 1 "$T/wave-resume.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_RESUME/phase4/waves/wave-1-2/status.json"
wait_for_json "$WAVE_STATUS" '.lead.process.finishedAt != null' || true
check "$(jq -r .lead.process.exitCode "$WAVE_STATUS")" "20" \
  "initial one-sided lead failure remains retryable"
wait_for_json "$WAVE_STATUS" '.speculative.process.finishedAt != null' || true
if kill -0 "$WAVE_PID" 2>/dev/null; then
  ok "wave remains active while a failed lead awaits retry"
else
  ng "wave remains active while a failed lead awaits retry"
fi
unset WAVE_TEST_CLAUDE_FAIL_ROUND
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_RESUME" \
    --claude-prompt "$T/resume-claude-round-1-finalize.md" \
    --phase convergence --round 1 --reviewer claude --attempt 2 \
    --wave-status "$WAVE_STATUS" --wave-role lead \
    --claude-resume-session-id fixture-claude-1 \
    > "$T/resume-lead.out" 2>&1
check "$?" "0" "lead retry accepts its attested finalize-only resume prompt"
if jq -e '
  .complete == true and
  .attempts[1].claude.execution == "resume" and
  .attempts[1].claude.resumedFromAttempt == 1
' "$ARTIFACT_RESUME/phase4/round-1/status.json" >/dev/null; then
  ok "lead resume retains canonical provenance"
else
  ng "lead resume retains canonical provenance"
fi
write_adjudication "$ARTIFACT_RESUME" wave-resume 1 false
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_RESUME" --wave-status "$WAVE_STATUS" \
  --action promote > "$T/control-resume.out"
wait "$WAVE_PID"
check "$?" "0" "recovered lead makes the active wave exit successfully"
check "$(inspect_waves "$CONTEXT_RESUME" "$ARTIFACT_RESUME")" "[1,2]" \
  "wave validation accepts recovered lead resume evidence"

echo "== W09: infrastructure exit 3 survives wave propagation and fresh retry =="
rm -f "$T/state/"*.started "$T/state/"*.pid
ARTIFACT_INFRA="$T/artifact-infra"
CONTEXT_INFRA="$T/context-infra.json"
write_context "$ARTIFACT_INFRA" "$CONTEXT_INFRA" wave-infra
prepare_prompts "$CONTEXT_INFRA" infra 1 2
WAVE_TEST_DELAY_1=0.1 WAVE_TEST_DELAY_2=0.1
WAVE_TEST_CLAUDE_INFRA_FAIL_ROUND=1
unset WAVE_TEST_CLAUDE_FAIL_ROUND WAVE_TEST_CODEX_FAIL_ROUND
unset WAVE_TEST_CODEX_INFRA_FAIL_ROUND
export WAVE_TEST_DELAY_1 WAVE_TEST_DELAY_2
export WAVE_TEST_CLAUDE_INFRA_FAIL_ROUND
start_wave "$CONTEXT_INFRA" infra 1 "$T/wave-infra.out"
WAVE_PID=$STARTED_WAVE_PID
WAVE_STATUS="$ARTIFACT_INFRA/phase4/waves/wave-1-2/status.json"
wait_for_json "$WAVE_STATUS" '.lead.process.finishedAt != null' || true
check "$(jq -r .lead.process.exitCode "$WAVE_STATUS")" "3" \
  "wave preserves the infrastructure exit code"
check "$(jq -r .lead.process.exitCodeSource "$WAVE_STATUS")" "process" \
  "wave records the measured infrastructure result"
wait_for_json "$WAVE_STATUS" '.speculative.process.finishedAt != null' || true
unset WAVE_TEST_CLAUDE_INFRA_FAIL_ROUND
WAVE_TEST_STATE="$T/state" \
  bash "$T/tooling/scripts/run-review-pair.sh" \
    --context "$CONTEXT_INFRA" \
    --claude-prompt "$T/infra-claude-round-1.md" \
    --phase convergence --round 1 --reviewer claude --attempt 2 \
    --wave-status "$WAVE_STATUS" --wave-role lead \
    > "$T/retry-infra-lead.out" 2>&1
check "$?" "0" "wave fresh-retries the infrastructure-failed reviewer"
if jq -e '
  .complete == true and
  .attempts[1].claude.execution == "retry" and
  .attempts[1].claude.resumedFromAttempt == null
' "$ARTIFACT_INFRA/phase4/round-1/status.json" >/dev/null; then
  ok "wave recovery records a fresh retry rather than resume"
else
  ng "wave recovery records a fresh retry rather than resume"
fi
write_adjudication "$ARTIFACT_INFRA" wave-infra 1 false
bash "$T/tooling/scripts/control-review-wave.sh" \
  --context "$CONTEXT_INFRA" --wave-status "$WAVE_STATUS" \
  --action promote > "$T/control-infra.out"
wait "$WAVE_PID"
check "$?" "0" "recovered infrastructure wave completes normally"
check "$(inspect_waves "$CONTEXT_INFRA" "$ARTIFACT_INFRA")" "[1,2]" \
  "wave validation accepts infrastructure recovery evidence"

printf '\nSummary: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
