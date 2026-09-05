#!/bin/bash
# Functional tests for per-run artifact isolation and report publication.

set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPTS/.." && pwd)"
SKILL_SCRIPTS="$SKILL_DIR/scripts"
INITIALIZER="$SKILL_SCRIPTS/init-review-run.sh"
PUBLISHER="$SKILL_SCRIPTS/publish-review-report.mjs"
FORMATTER="$SKILL_SCRIPTS/format-review-context.mjs"
DURATION_FORMATTER="$SKILL_SCRIPTS/format-review-duration.mjs"
SNAPSHOT_BUILDER="$SKILL_SCRIPTS/build-review-snapshot.mjs"
SNAPSHOT_CLEANUP="$SKILL_SCRIPTS/cleanup-review-snapshot.sh"
OUTPUT_EVIDENCE="$SKILL_SCRIPTS/review-output-evidence.mjs"
ADJUDICATION="$SKILL_SCRIPTS/review-adjudication.mjs"
FINAL_FINDINGS="$SKILL_SCRIPTS/review-final-findings.mjs"
PR_CONTEXT_MODULE="$SKILL_SCRIPTS/review-pr-context.mjs"
WAVE_STATE="$SKILL_SCRIPTS/review-wave-state.mjs"
PATH_INTEROP="$SKILL_SCRIPTS/path-interop.mjs"

T=$(mktemp -d /tmp/deep-review-artifacts-test.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/tooling" "$T/temp"

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
BASE_SHA=1111111111111111111111111111111111111111
HEAD_SHA=2222222222222222222222222222222222222222
TOOLING_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DIFF_DIGEST=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SNAPSHOT_DIGEST=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
GUIDANCE_DIGEST=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
write_pr_context_receipt() {
  node --input-type=module - "$PR_CONTEXT_MODULE" "$1" <<'NODE'
const [modulePath, contextPath] = process.argv.slice(2);
const { pathToFileURL } = await import("node:url");
const { writePrReviewContextReceipt } = await import(pathToFileURL(modulePath));
writePrReviewContextReceipt(contextPath);
NODE
}
write_pr_review_context() {
  local context="$1" output artifact run_id pr_number head_sha initial_sha
  output=$(jq -r .prReviewContextPath "$context")
  artifact=$(dirname "$output")
  run_id=$(jq -r .reviewRunId "$context")
  pr_number=$(jq -r .prNumber "$context")
  head_sha=$(jq -r .headSha "$context")
  jq -n \
    --arg reviewRunId "$run_id" \
    --arg repositoryHost github.example.com \
    --arg repository owner/repo \
    --argjson prNumber "$pr_number" \
    --arg expectedHeadSha "$head_sha" '
      {
        schema:"deep-review-pr-review-context/v1",
        snapshotRole:"initial",
        supersedesSha256:null,
        reviewRunId:$reviewRunId,
        repositoryHost:$repositoryHost,
        repository:$repository,
        prNumber:$prNumber,
        expectedHeadSha:$expectedHeadSha,
        headShaBefore:$expectedHeadSha,
        headShaAfter:$expectedHeadSha,
        status:"checked",
        reasons:[],
        unfetched:[],
        limits:{pageSize:100,sourceRecords:10000,combinedRawBytes:67108864},
        rawBytes:0,
        counts:{
          issueComments:{pages:0,raw:0,nonBot:0,deduped:0},
          reviews:{pages:0,raw:0,nonBot:0,deduped:0},
          inlineComments:{pages:0,raw:0,nonBot:0,deduped:0},
          reviewThreads:{pages:0,raw:0,nonBot:0,deduped:0}
        },
        records:{issueComments:[],reviews:[],inlineComments:[],reviewThreads:[]}
      }
    ' > "$output"
  chmod 600 "$output" 2>/dev/null || true
  write_pr_context_receipt "$output"
  mkdir -p "$artifact/phase5"
  initial_sha=$(jq -r .sha256 "$output.receipt.json")
  jq --arg initialSha "$initial_sha" \
    '.snapshotRole = "final" | .supersedesSha256 = $initialSha' \
    "$output" > "$artifact/phase5/pr-review-context.json"
  chmod 600 "$artifact/phase5/pr-review-context.json" 2>/dev/null || true
  write_pr_context_receipt "$artifact/phase5/pr-review-context.json"
}
write_context_file() {
  local raw_context="$1" review_mode="$2" target="$3" target_slug="$4"
  local pr_number="$5" head_ref="$6" artifact review_started_at_ms
  artifact=$(printf '%s' "$raw_context" | jq -r .reviewArtifactDir)
  review_started_at_ms=$(node -e 'process.stdout.write(String(Date.now()))')
  printf '%s' "$raw_context" | jq \
    --arg reviewMode "$review_mode" \
    --arg target "$target" \
    --arg targetSlug "$target_slug" \
    --arg repositoryHost github.example.com \
    --arg repository owner/repo \
    --arg prNumber "$pr_number" \
    --arg prReviewContextPath "$artifact/pr-review-context.json" \
    --arg headRef "$head_ref" \
    --arg baseSha "$BASE_SHA" \
    --arg headSha "$HEAD_SHA" \
    --arg mergeBaseSha "$BASE_SHA" \
    --arg toolingDigest "$TOOLING_DIGEST" \
    --arg diffSha256 "$DIFF_DIGEST" \
    --arg snapshotMetadataSha256 "$SNAPSHOT_DIGEST" \
    --arg baseGuidanceSha256 "$GUIDANCE_DIGEST" \
    --argjson reviewStartedAtMs "$review_started_at_ms" \
    '. + {$reviewMode,$target,$targetSlug,$prNumber,$headRef,$baseSha,$headSha,
      $mergeBaseSha,$toolingDigest,$diffSha256,$snapshotMetadataSha256,
      $baseGuidanceSha256,$reviewStartedAtMs} +
      (if $reviewMode == "pr" then {$repositoryHost,$repository,$prReviewContextPath}
       else {repositoryHost:null,repository:null,prReviewContextPath:null} end)' > "$artifact/context.json"
  chmod 400 "$artifact/context.json" 2>/dev/null || true
  if [ "$review_mode" = "pr" ]; then
    write_pr_review_context "$artifact/context.json"
  fi
}
write_prompt_receipt() {
  local context="$1" prompt="$2" reviewer="$3" phase="$4"
  local round="$5" purpose="$6"
  node --input-type=module - \
    "$SKILL_SCRIPTS/review-prompt-manifest.mjs" \
    "$context" "$prompt" "$reviewer" "$phase" "$round" "$purpose" <<'JS'
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [modulePath, contextPath, promptPath, reviewer, phase, round, purpose] =
  process.argv.slice(2);
const { createPromptManifest, verifyPromptManifest } =
  await import(pathToFileURL(modulePath));
const context = JSON.parse(readFileSync(contextPath, "utf8"));
mkdirSync(path.dirname(promptPath), { recursive: true });
writeFileSync(
  promptPath,
  `${reviewer} ${phase} ${round || "primary"} ${purpose} ${path.basename(promptPath)} fixture prompt\n`,
);
createPromptManifest({
  context,
  promptPath,
  reviewer,
  phase,
  round: round || undefined,
  purpose,
});
process.stdout.write(JSON.stringify(verifyPromptManifest({
  context,
  promptPath,
  reviewer,
  phase,
  round: round || undefined,
  purpose,
})));
JS
}
rebuild_pair_status() {
  local status_dir="$1" context="$2" phase="$3" round_json="$4" run_id
  run_id=$(jq -r .reviewRunId "$context")
  jq -s \
    --arg reviewRunId "$run_id" \
    --arg phase "$phase" \
    --argjson round "$round_json" '
      sort_by(.attempt) as $attempts |
      def canonical($reviewer):
        [$attempts[] as $attempt |
          $attempt[$reviewer] |
          select(.requested) |
          . + {attempt:$attempt.attempt, interrupted:$attempt.interrupted}
        ] as $runs |
        if ($runs | length) == 0 then null
        else (($runs | map(select(.exitCode == 0)) | last) // ($runs | last))
        end;
      canonical("claude") as $claude |
      canonical("codex") as $codex |
      {
        schema:"deep-review-pair/v6",
        reviewRunId:$reviewRunId,
        expectedReviewers:["claude","codex"],
        phase:$phase,
        round:$round,
        attempts:$attempts,
        canonical:{claude:$claude,codex:$codex},
        complete:(
          $claude != null and $claude.exitCode == 0 and
          $codex != null and $codex.exitCode == 0
        )
      }
    ' "$status_dir"/attempt-*/status.json > "$status_dir/status.json"
}
write_successful_pair_status() {
  local artifact="$1" phase="$2" round_json="$3" status_dir attempt_dir
  local context run_id target head_sha diff_sha snapshot_sha round_value
  local claude_prompt codex_prompt claude_prompt_receipt codex_prompt_receipt
  local claude_evidence_receipt codex_evidence_receipt
  local -a evidence_args
  local resume_header
  context="$artifact/context.json"
  run_id=$(jq -r .reviewRunId "$context")
  target=$(jq -r .target "$context")
  head_sha=$(jq -r .headSha "$context")
  diff_sha=$(jq -r .diffSha256 "$context")
  snapshot_sha=$(jq -r .snapshotMetadataSha256 "$context")
  if [ "$phase" = "primary" ]; then
    status_dir="$artifact/phase2"
    round_value=""
  else
    status_dir="$artifact/phase4/round-$round_json"
    round_value="$round_json"
  fi
  claude_prompt="$artifact/prompts/$phase-${round_value:-primary}-claude-review.md"
  codex_prompt="$artifact/prompts/$phase-${round_value:-primary}-codex-review.md"
  claude_prompt_receipt=$(write_prompt_receipt \
    "$context" "$claude_prompt" claude "$phase" "$round_value" review)
  codex_prompt_receipt=$(write_prompt_receipt \
    "$context" "$codex_prompt" codex "$phase" "$round_value" review)
  attempt_dir="$status_dir/attempt-1"
  mkdir -p "$attempt_dir"
  for reviewer in claude codex; do
    if [ "$reviewer" = "claude" ]; then
      resume_header='SESSION_ID: fixture-claude-session'
    else
      resume_header='THREAD_ID: fixture-codex-thread'
    fi
    cat > "$attempt_dir/$reviewer.out" <<OUTPUT
$resume_header
RUN_ID: $run_id
INPUT_ATTESTATION: verified
TARGET: $target
HEAD_SHA: $head_sha
DIFF_SHA256: $diff_sha
SNAPSHOT_METADATA_SHA256: $snapshot_sha
---
NO_FINDINGS
scope: fixed diff and HEAD snapshot
reason: no actionable issue in fixture
OUTPUT
    : > "$attempt_dir/$reviewer.err"
  done
  evidence_args=(--phase "$phase" --attempt 1)
  if [ -n "$round_value" ]; then
    evidence_args+=(--round "$round_value")
  fi
  claude_evidence_receipt=$(node "$OUTPUT_EVIDENCE" \
    --input "$attempt_dir/claude.out" \
    --output "$attempt_dir/claude.evidence.json" \
    --reviewer claude "${evidence_args[@]}")
  codex_evidence_receipt=$(node "$OUTPUT_EVIDENCE" \
    --input "$attempt_dir/codex.out" \
    --output "$attempt_dir/codex.evidence.json" \
    --reviewer codex "${evidence_args[@]}")
  jq -n \
    --arg phase "$phase" \
    --argjson round "$round_json" \
    --arg claudeOutput "$attempt_dir/claude.out" \
    --arg claudeError "$attempt_dir/claude.err" \
    --arg codexOutput "$attempt_dir/codex.out" \
    --arg codexError "$attempt_dir/codex.err" \
    --argjson claudePrompt "$claude_prompt_receipt" \
    --argjson codexPrompt "$codex_prompt_receipt" \
    --argjson claudeEvidence "$claude_evidence_receipt" \
    --argjson codexEvidence "$codex_evidence_receipt" '
      {
        schema:"deep-review-attempt/v4",
        phase:$phase,
        round:$round,
        attempt:1,
        interrupted:false,
        claude:{
          requested:true,launched:true,exitCode:0,execution:"initial",
          resumeId:null,resumedFromAttempt:null,prompt:$claudePrompt,evidence:$claudeEvidence,
          stdout:$claudeOutput,stderr:$claudeError
        },
        codex:{
          requested:true,launched:true,exitCode:0,execution:"initial",
          resumeId:null,resumedFromAttempt:null,prompt:$codexPrompt,evidence:$codexEvidence,
          stdout:$codexOutput,stderr:$codexError
        }
      }
    ' > "$attempt_dir/status.json"
  rebuild_pair_status "$status_dir" "$context" "$phase" "$round_json"
}
write_successful_review_evidence() {
  local artifact="$1"
  write_successful_pair_status "$artifact" primary null
  write_successful_pair_status "$artifact" convergence 1
  write_successful_pair_status "$artifact" convergence 2
}
add_successful_codex_retry() {
  local artifact="$1" status_dir attempt_dir context codex_prompt_receipt
  local codex_evidence_receipt
  status_dir="$artifact/phase2"
  context="$artifact/context.json"
  jq '.codex.exitCode = 7 | .codex.evidence = null' "$status_dir/attempt-1/status.json" \
    > "$T/retry-attempt-1.json"
  mv "$T/retry-attempt-1.json" "$status_dir/attempt-1/status.json"
  attempt_dir="$status_dir/attempt-2"
  mkdir "$attempt_dir"
  cp "$status_dir/attempt-1/codex.out" "$attempt_dir/codex.out"
  : > "$attempt_dir/codex.err"
  codex_prompt_receipt=$(jq -c '.codex.prompt' \
    "$status_dir/attempt-1/status.json")
  codex_evidence_receipt=$(node "$OUTPUT_EVIDENCE" \
    --input "$attempt_dir/codex.out" \
    --output "$attempt_dir/codex.evidence.json" \
    --reviewer codex --phase primary --attempt 2)
  jq -n \
    --arg phase primary \
    --arg codexOutput "$attempt_dir/codex.out" \
    --arg codexError "$attempt_dir/codex.err" \
    --argjson codexPrompt "$codex_prompt_receipt" \
    --argjson codexEvidence "$codex_evidence_receipt" '
      {
        schema:"deep-review-attempt/v4",
        phase:$phase,
        round:null,
        attempt:2,
        interrupted:false,
        claude:{
          requested:false,launched:false,exitCode:null,execution:null,
          resumeId:null,resumedFromAttempt:null,prompt:null,evidence:null,stdout:null,stderr:null
        },
        codex:{
          requested:true,launched:true,exitCode:0,execution:"retry",
          resumeId:null,resumedFromAttempt:null,prompt:$codexPrompt,evidence:$codexEvidence,
          stdout:$codexOutput,stderr:$codexError
        }
      }
    ' > "$attempt_dir/status.json"
  rebuild_pair_status "$status_dir" "$context" primary null
}
add_successful_claude_resume() {
  local artifact="$1" status_dir attempt_dir context claude_prompt_receipt
  local claude_evidence_receipt
  status_dir="$artifact/phase2"
  context="$artifact/context.json"
  jq '.claude.exitCode = 6 | .claude.evidence = null' "$status_dir/attempt-1/status.json" \
    > "$T/resume-attempt-1.json"
  mv "$T/resume-attempt-1.json" "$status_dir/attempt-1/status.json"
  attempt_dir="$status_dir/attempt-2"
  mkdir "$attempt_dir"
  cp "$status_dir/attempt-1/claude.out" "$attempt_dir/claude.out"
  : > "$attempt_dir/claude.err"
  claude_prompt_receipt=$(write_prompt_receipt \
    "$context" \
    "$artifact/prompts/primary-primary-claude-resume.md" \
    claude primary "" resume)
  claude_evidence_receipt=$(node "$OUTPUT_EVIDENCE" \
    --input "$attempt_dir/claude.out" \
    --output "$attempt_dir/claude.evidence.json" \
    --reviewer claude --phase primary --attempt 2)
  jq -n \
    --arg phase primary \
    --arg claudeOutput "$attempt_dir/claude.out" \
    --arg claudeError "$attempt_dir/claude.err" \
    --argjson claudePrompt "$claude_prompt_receipt" \
    --argjson claudeEvidence "$claude_evidence_receipt" '
      {
        schema:"deep-review-attempt/v4",
        phase:$phase,
        round:null,
        attempt:2,
        interrupted:false,
        claude:{
          requested:true,launched:true,exitCode:0,execution:"resume",
          resumeId:"fixture-claude-session",resumedFromAttempt:1,prompt:$claudePrompt,evidence:$claudeEvidence,
          stdout:$claudeOutput,stderr:$claudeError
        },
        codex:{
          requested:false,launched:false,exitCode:null,execution:null,
          resumeId:null,resumedFromAttempt:null,prompt:null,evidence:null,stdout:null,stderr:null
        }
      }
    ' > "$attempt_dir/status.json"
  rebuild_pair_status "$status_dir" "$context" primary null
}
write_zero_adjudication_chain() {
  local artifact="$1" draft previous output round
  draft="$artifact/phase2/adjudication-draft.json"
  printf '%s\n' '{"decisions":[],"changes":[],"after":[]}' > "$draft"
  output="$artifact/phase2/adjudication.json"
  rm -f "$output"
  node "$ADJUDICATION" \
    --pair-status "$artifact/phase2/status.json" \
    --draft "$draft" --output "$output" >/dev/null || return 1
  previous="$output"
  round=1
  while [ -d "$artifact/phase4/round-$round" ]; do
    draft="$artifact/phase4/round-$round/adjudication-draft.json"
    printf '%s\n' '{"decisions":[],"changes":[],"after":[]}' > "$draft"
    output="$artifact/phase4/round-$round/adjudication.json"
    rm -f "$output"
    node "$ADJUDICATION" \
      --pair-status "$artifact/phase4/round-$round/status.json" \
      --previous "$previous" --draft "$draft" --output "$output" \
      >/dev/null || return 1
    previous="$output"
    round=$((round + 1))
  done
}
promote_fixture_as_wave() {
  local artifact="$1" outcome="${2:-promoted}"
  local context phase4 run_id saved_lead saved_speculative
  local source_speculative reservation status status_file rewritten supervisor_pid
  context="$artifact/context.json"
  phase4="$artifact/phase4"
  run_id=$(jq -r .reviewRunId "$context")
  saved_lead="$T/$run_id-round-1"
  saved_speculative="$T/$run_id-round-2"
  supervisor_pid=$$
  case "$OSTYPE" in
    msys*|cygwin*)
      supervisor_pid=$(sed -n '1p' "/proc/$$/winpid" 2>/dev/null) ||
        supervisor_pid=""
      ;;
  esac
  if ! [[ "$supervisor_pid" =~ ^[1-9][0-9]*$ ]]; then
    return 1
  fi

  write_zero_adjudication_chain "$artifact" || return 1
  rm -f \
    "$phase4/round-1/adjudication-draft.json" \
    "$phase4/round-1/adjudication.json" \
    "$phase4/round-2/adjudication-draft.json" \
    "$phase4/round-2/adjudication.json"
  mv "$phase4/round-1" "$saved_lead"
  mv "$phase4/round-2" "$saved_speculative"

  reservation=$(node "$WAVE_STATE" reserve \
    --context "$context" --first-round 1 --supervisor-pid "$supervisor_pid" \
    --claude-lead-prompt "$artifact/prompts/convergence-1-claude-review.md" \
    --codex-lead-prompt "$artifact/prompts/convergence-1-codex-review.md" \
    --claude-speculative-prompt "$artifact/prompts/convergence-2-claude-review.md" \
    --codex-speculative-prompt "$artifact/prompts/convergence-2-codex-review.md") || return 1
  status=$(printf '%s' "$reservation" | jq -r .statusPath)
  source_speculative="$phase4/waves/wave-1-2/speculative-round-2"
  mv "$saved_lead" "$phase4/round-1"
  mv "$saved_speculative" "$source_speculative"

  for status_file in \
    "$source_speculative/status.json" \
    "$source_speculative/attempt-1/status.json"; do
    rewritten="$T/$run_id-$(basename "$(dirname "$status_file")")-status.json"
    jq --arg source "$phase4/round-2" \
      --arg destination "$source_speculative" '
        walk(
          if type == "string" and startswith($source)
          then $destination + .[($source | length):]
          else .
          end
        )
      ' "$status_file" > "$rewritten" || return 1
    mv "$rewritten" "$status_file"
  done

  if [ "$outcome" = "aborted-incomplete" ]; then
    rm "$source_speculative/status.json"
  elif [ "$outcome" != "promoted" ]; then
    return 1
  fi

  write_zero_adjudication_chain "$artifact" || return 1
  node "$WAVE_STATE" record-start \
    --context "$context" --status "$status" --role lead --pid 8101 \
    >/dev/null || return 1
  node "$WAVE_STATE" record-result \
    --context "$context" --status "$status" --role lead --exit-code 0 \
    >/dev/null || return 1
  node "$WAVE_STATE" record-start \
    --context "$context" --status "$status" --role speculative --pid 8102 \
    >/dev/null || return 1
  node "$WAVE_STATE" record-result \
    --context "$context" --status "$status" --role speculative --exit-code 0 \
    >/dev/null || return 1
  node "$WAVE_STATE" decide \
    --context "$context" --status "$status" --action promote \
    >/dev/null || return 1
}
write_retained_adjudication_chain() {
  local artifact="$1" attempt_dir reviewer receipt draft previous output round
  attempt_dir="$artifact/phase2/attempt-1"
  for reviewer in claude codex; do
    sed 's/^NO_FINDINGS$/Medium: retained finding/' \
      "$attempt_dir/$reviewer.out" > "$T/retained-$reviewer.out"
    mv "$T/retained-$reviewer.out" "$attempt_dir/$reviewer.out"
    rm -f "$attempt_dir/$reviewer.evidence.json"
    receipt=$(node "$OUTPUT_EVIDENCE" \
      --input "$attempt_dir/$reviewer.out" \
      --output "$attempt_dir/$reviewer.evidence.json" \
      --reviewer "$reviewer" --phase primary --attempt 1)
    jq --argjson evidence "$receipt" ".${reviewer}.evidence = \$evidence" \
      "$attempt_dir/status.json" > "$T/retained-status.json"
    mv "$T/retained-status.json" "$attempt_dir/status.json"
  done
  rebuild_pair_status "$artifact/phase2" "$artifact/context.json" primary null

  draft="$artifact/phase2/adjudication-draft.json"
  cat > "$draft" <<'JSON'
{
  "decisions":[
    {
      "candidateId":"claude-F001",
      "outcome":"new",
      "findingId":"F1",
      "rationale":"fixture candidate"
    },
    {
      "candidateId":"codex-F001",
      "outcome":"duplicate",
      "findingId":"F1",
      "rationale":"same fixture candidate"
    }
  ],
  "changes":[],
  "after":[{"id":"F1","severity":"Medium","title":"`retained()` finding"}]
}
JSON
  output="$artifact/phase2/adjudication.json"
  rm -f "$output"
  node "$ADJUDICATION" \
    --pair-status "$artifact/phase2/status.json" \
    --draft "$draft" --output "$output" >/dev/null || return 1
  previous="$output"

  for round in 1 2; do
    draft="$artifact/phase4/round-$round/adjudication-draft.json"
    cat > "$draft" <<'JSON'
{
  "decisions":[],
  "changes":[
    {
      "findingId":"F1",
      "action":"unchanged",
      "rationale":"fixture finding still applies"
    }
  ],
  "after":[{"id":"F1","severity":"Medium","title":"`retained()` finding"}]
}
JSON
    output="$artifact/phase4/round-$round/adjudication.json"
    rm -f "$output"
    node "$ADJUDICATION" \
      --pair-status "$artifact/phase4/round-$round/status.json" \
      --previous "$previous" --draft "$draft" --output "$output" \
      >/dev/null || return 1
    previous="$output"
  done
}
write_alternating_adjudication_chain() {
  local artifact="$1" round_count="$2" draft previous output round
  local attempt_dir receipt codex_receipt finding_number title
  draft="$artifact/phase2/adjudication-draft.json"
  printf '%s\n' '{"decisions":[],"changes":[],"after":[]}' > "$draft"
  output="$artifact/phase2/adjudication.json"
  rm -f "$output"
  node "$ADJUDICATION" \
    --pair-status "$artifact/phase2/status.json" \
    --draft "$draft" --output "$output" >/dev/null || return 1
  previous="$output"
  for ((round = 1; round <= round_count; round++)); do
    attempt_dir="$artifact/phase4/round-$round/attempt-1"
    draft="$artifact/phase4/round-$round/adjudication-draft.json"
    output="$artifact/phase4/round-$round/adjudication.json"
    rm -f "$output"
    if [ $((round % 2)) -eq 1 ]; then
      finding_number=$(((round + 1) / 2))
      title="transient finding $finding_number"
      sed "s/^NO_FINDINGS$/Low: $title/" "$attempt_dir/claude.out" \
        > "$T/alternating-claude.out"
      mv "$T/alternating-claude.out" "$attempt_dir/claude.out"
      sed "s/^NO_FINDINGS$/Low: $title/" "$attempt_dir/codex.out" \
        > "$T/alternating-codex.out"
      mv "$T/alternating-codex.out" "$attempt_dir/codex.out"
      rm -f "$attempt_dir/claude.evidence.json"
      rm -f "$attempt_dir/codex.evidence.json"
      receipt=$(node "$OUTPUT_EVIDENCE" \
        --input "$attempt_dir/claude.out" \
        --output "$attempt_dir/claude.evidence.json" \
        --reviewer claude --phase convergence --round "$round" --attempt 1)
      codex_receipt=$(node "$OUTPUT_EVIDENCE" \
        --input "$attempt_dir/codex.out" \
        --output "$attempt_dir/codex.evidence.json" \
        --reviewer codex --phase convergence --round "$round" --attempt 1)
      jq --argjson evidence "$receipt" --argjson codexEvidence "$codex_receipt" \
        '.claude.evidence = $evidence | .codex.evidence = $codexEvidence' \
        "$attempt_dir/status.json" > "$T/alternating-status.json"
      mv "$T/alternating-status.json" "$attempt_dir/status.json"
      rebuild_pair_status "$artifact/phase4/round-$round" \
        "$artifact/context.json" convergence "$round"
      jq -n \
        --arg findingId "F$finding_number" \
        --arg title "$title" '
          {
            decisions:[
              {
                candidateId:"claude-F001",outcome:"new",
                findingId:$findingId,rationale:"fixture candidate"
              },
              {
                candidateId:"codex-F001",outcome:"duplicate",
                findingId:$findingId,rationale:"same fixture candidate"
              }
            ],
            changes:[],
            after:[{id:$findingId,severity:"Low",title:$title}]
          }
        ' > "$draft"
    else
      finding_number=$((round / 2))
      jq -n --arg findingId "F$finding_number" '
        {
          decisions:[],
          changes:[{
            findingId:$findingId,action:"withdrawn",
            rationale:"fixture withdrawal"
          }],
          after:[]
        }
      ' > "$draft"
    fi
    node "$ADJUDICATION" \
      --pair-status "$artifact/phase4/round-$round/status.json" \
      --previous "$previous" --draft "$draft" --output "$output" \
      >/dev/null || return 1
    previous="$output"
  done
}
write_valid_report() {
  local output="$1" label="$2" context_path header comments
  local initial_review="${3:-Claude 成功 / Codex 成功}"
  local execution_details="${4:-なし}"
  local round_count="${5:-2}" convergence_decision="${6:-収束}"
  local stable_round="${7:-連続2回}" alternate_unstable="${8:-false}"
  local finding_fixture="${9:-zero}"
  local round_rows="" round
  local target base_sha head_sha merge_base_sha run_id tooling_digest
  local diff_digest snapshot_digest guidance_digest review_mode head_ref pr_number
  local artifact final_adjudication final_draft final_output final_set_digest
  local handling_digest this_pr_count addressed_count issue_comment_count
  local phase4_count excluded_count retained_count not_judged_count excluded_section
  local earlier_section earlier_rows adjudication_file scope candidate_id outcome rationale
  local conclusion cross_rows medium_count medium_findings unchanged_count
  local -a finalizer_args
  artifact=$(dirname "$output")
  if [ "$alternate_unstable" = "true" ]; then
    write_alternating_adjudication_chain "$artifact" "$round_count" || return 1
  elif [ "$finding_fixture" = "retained" ] || [ "$finding_fixture" = "excluded" ]; then
    write_retained_adjudication_chain "$artifact" || return 1
  else
    write_zero_adjudication_chain "$artifact" || return 1
  fi
  context_path="$(dirname "$output")/context.json"
  review_mode=$(jq -r .reviewMode "$context_path")
  final_adjudication="$artifact/phase4/round-$round_count/adjudication.json"
  final_draft="$artifact/phase5/final-findings-draft.json"
  final_output="$artifact/phase5/final-findings.json"
  if [ "$finding_fixture" = "retained" ]; then
    cat > "$final_draft" <<'JSON'
{
  "decisions":[
    {
      "findingId":"F1",
      "outcome":"not-judged",
      "handling":"this-pr-candidate",
      "handlingRationale":"fixture change directly causes the issue",
      "evidence":[],
      "rationale":"no matching PR comment"
    }
  ]
}
JSON
  elif [ "$finding_fixture" = "excluded" ]; then
    chmod u+w "$artifact/phase5/pr-review-context.json" 2>/dev/null || true
    jq --arg headSha "$(jq -r .headSha "$context_path")" '
      .counts.issueComments = {pages:1,raw:1,nonBot:1,deduped:1} |
      .records.issueComments = [{
        stableId:"issueComments:9001",
        apiId:9001,
        url:"https://github.example.com/owner/repo/pull/1#issuecomment-9001",
        body:"fixed on the reviewed HEAD",
        author:"fixture",
        createdAt:null,
        updatedAt:null
      }]
    ' "$artifact/phase5/pr-review-context.json" > "$T/excluded-pr-context.json"
    mv "$T/excluded-pr-context.json" "$artifact/phase5/pr-review-context.json"
    chmod 600 "$artifact/phase5/pr-review-context.json" 2>/dev/null || true
    rm -f "$artifact/phase5/pr-review-context.json.receipt.json"
    write_pr_context_receipt "$artifact/phase5/pr-review-context.json"
    cat > "$final_draft" <<'JSON'
{
  "decisions":[
    {
      "findingId":"F1",
      "outcome":"addressed",
      "handling":"addressed",
      "handlingRationale":"reviewed HEAD contains the fixture fix",
      "evidence":[{"source":"issueComments","stableId":"issueComments:9001"}],
      "rationale":"fixed on the reviewed HEAD"
    }
  ]
}
JSON
  else
    printf '%s\n' '{"decisions":[]}' > "$final_draft"
  fi
  rm -f "$final_output"
  finalizer_args=(
    --context "$context_path"
    --adjudication "$final_adjudication"
    --draft "$final_draft"
    --output "$final_output"
  )
  if [ "$review_mode" = "pr" ]; then
    finalizer_args+=(
      --pr-review-context "$artifact/phase5/pr-review-context.json"
    )
  fi
  node "$FINAL_FINDINGS" "${finalizer_args[@]}" >/dev/null || return 1
  final_set_digest=$(jq -r .final.sha256 "$final_output")
  handling_digest=$(jq -r .handling.sha256 "$final_output")
  target=$(jq -r .target "$context_path")
  base_sha=$(jq -r .baseSha "$context_path")
  head_sha=$(jq -r .headSha "$context_path")
  merge_base_sha=$(jq -r .mergeBaseSha "$context_path")
  run_id=$(jq -r .reviewRunId "$context_path")
  tooling_digest=$(jq -r .toolingDigest "$context_path")
  diff_digest=$(jq -r .diffSha256 "$context_path")
  snapshot_digest=$(jq -r .snapshotMetadataSha256 "$context_path")
  guidance_digest=$(jq -r .baseGuidanceSha256 "$context_path")
  head_ref=$(jq -r .headRef "$context_path")
  pr_number=$(jq -r .prNumber "$context_path")
  addressed_count=0
  issue_comment_count=0
  excluded_count=0
  excluded_section='> 該当なし'
  if [ "$finding_fixture" = "retained" ]; then
    conclusion="Medium 1件（fixture report ${label}）。"
    cross_rows='| F1 | Medium | Medium | Medium | このPRでの対応候補 | fixture severity |'
    medium_count=1
    this_pr_count=1
    phase4_count=1
    retained_count=1
    not_judged_count=1
    unchanged_count=1
    medium_findings='#### M1. [F1] `retained()` finding

- 今回の取扱い: `このPRでの対応候補`
- 取扱いの根拠: fixture change directly causes the issue
- 目的との関係: fixture acceptance condition
- 既存成功記録との照合: fixture success path is separate
- 既存判断との照合: 初出
- 場所: `src/fixture.ts:1`
- 成立条件: fixture condition
- 影響: fixture impact
- 問題の根拠: fixture evidence
- コードパス: fixture path
- 確認した防御: fixture guard
- レビュアー判定: Claude `Medium` / Codex `Medium` → 最終 `Medium`
- 検出: `両方`
- 修正案: fixture fix
- 修正案の裏付け: fixture support
- 修正案の影響範囲レビュー:
  - 修正案の評価: `推奨修正案`
  - 既存呼び出し元への影響: なし
  - テストへの影響: fixture test
  - デグレ確認: fixture regression
  - proportionality: fixture scope
  - 追加検証: fixture verification'
  else
    conclusion="指摘事項なし（fixture report ${label}）。"
    cross_rows=""
    medium_count=0
    this_pr_count=0
    phase4_count=0
    retained_count=0
    not_judged_count=0
    unchanged_count=0
    medium_findings='> 該当なし'
  fi
  if [ "$finding_fixture" = "excluded" ]; then
    conclusion="指摘は現在の固定HEADで対応済み（fixture report ${label}）。"
    phase4_count=1
    excluded_count=1
    addressed_count=1
    issue_comment_count=1
    unchanged_count=1
    excluded_section='| # | Finding ID | 候補 | 元重要度 | 今回の取扱い | 理由・根拠 |
|---|---|---|---|---|---|
| X1 | F1 | `retained()` finding | Medium | 対応済み | reviewed HEAD contains the fixture fix |'
  fi
  if [ "$review_mode" = "pr" ]; then
    header="# Deep Review: PR #$pr_number"
    comments="- 取得状態: checked

| 情報源 | 取得件数 | 状態・未取得範囲 |
|---|---:|---|
| Issue comments | ${issue_comment_count} | 完全取得 |
| Reviews | 0 | 完全取得 |
| Inline comments | 0 | 完全取得 |
| Review threads | 0 | 完全取得 |

- 照合: Phase 4候補 ${phase4_count}件 → 除外 ${excluded_count}件 → 継続 ${retained_count}件 → 最終 ${retained_count}件
- 判定内訳: addressed=${addressed_count}, dismissed-valid=0, dismissed-but-rechallenge=0, not-judged=${not_judged_count}
- 件数集計: Phase4=${phase4_count}, 除外=${excluded_count}, 継続=${retained_count}, 最終=${retained_count}
- 件数式: ${phase4_count} = ${excluded_count} + ${retained_count}、${retained_count} = ${retained_count}
- UI状態だけで除外した候補: 0件"
  else
    header="# Deep Review: branch $head_ref"
    comments='PR未作成のため不適用'
  fi
  for ((round = 1; round <= round_count; round++)); do
    if [ "$alternate_unstable" = "true" ] && [ $((round % 2)) -eq 1 ]; then
      round_rows+="| $round | fixture | 成功 | 成功 | 1 | 0 | 1 | 0 | 0 | 0 | 0 | あり |"$'\n'
    elif [ "$alternate_unstable" = "true" ]; then
      round_rows+="| $round | fixture | 成功 | 成功 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | あり |"$'\n'
    else
      round_rows+="| $round | fixture | 成功 | 成功 | 0 | 0 | 0 | 0 | 0 | 0 | ${unchanged_count} | なし |"$'\n'
    fi
  done
  earlier_rows=""
  for ((round = 0; round <= round_count; round++)); do
    if [ "$round" -eq 0 ]; then
      scope="Phase 2"
      adjudication_file="$artifact/phase2/adjudication.json"
    else
      scope="round $round"
      adjudication_file="$artifact/phase4/round-$round/adjudication.json"
    fi
    while IFS=$'\t' read -r candidate_id outcome rationale; do
      [ -n "$candidate_id" ] || continue
      rationale=${rationale//|/\\|}
      earlier_rows+="| $scope | $candidate_id | $outcome | $rationale |"$'\n'
    done < <(jq -r '
      ((.decisions[] | select(.outcome == "rejected") |
        [.candidateId, "棄却", .rationale]),
       (.changes[] | select(.action == "withdrawn") |
        [.findingId, "撤回", .rationale])) | @tsv
    ' "$adjudication_file")
  done
  if [ -n "$earlier_rows" ]; then
    earlier_section='| 段階 | ID | 判定 | 理由 |
|---|---|---|---|
'$earlier_rows
  else
    earlier_section='> 該当なし'
  fi
  cat > "$output" <<REPORT
$header

## 結論

$conclusion

- このPRでの対応候補: ${this_pr_count}件
- ユーザー判断が必要: 0件
- 追加確認が必要: 0件
- 別Issue候補: 0件
- 受容済み・見送り済み: 0件
- 対応済み: ${addressed_count}件

### ユーザーへの確認事項

> 該当なし

## レビューの前提と範囲

- レビュー目的: fixture review
- このPRの対象: fixture change
- このPRの非対象: unrelated fixture
- プロジェクトの性質・利用者: fixture
- 現実的な攻撃者・誤操作・障害: fixture
- データの機密性・完全性: fixture
- 防御・検知・復旧: fixture
- 不明点・保守的仮定: なし
- 前回からの変更: 比較対象なし

## Claude／Codexクロスチェック

| Finding ID | Claude重要度 | Codex重要度 | 最終重要度 | 今回の取扱い | 訂正理由 |
|---|---|---|---|---|---|
$cross_rows

### 最終重要度件数

| 重要度 | 件数 | 意味 |
|---|---:|---|
| Critical | 0 | 極めて重大 |
| High | 0 | 重大 |
| Medium | $medium_count | 明確な支障 |
| Low | 0 | 軽微・改善提案 |

### 今回の取扱い件数

| 今回の取扱い | 件数 | 意味 |
|---|---:|---|
| このPRでの対応候補 | $this_pr_count | 目的達成との直接関係あり |
| ユーザー判断が必要 | 0 | 仕様・信頼境界・スコープの判断待ち |
| 追加確認が必要 | 0 | 事実・再現性・重要度の確定待ち |
| 別Issue候補 | 0 | 妥当だが当PRの目的外 |
| 受容済み・見送り済み | 0 | 既存判断を維持 |
| 対応済み | $addressed_count | 固定HEADで解消済み |

## Findings

### Critical (0件)

> 該当なし

### High (0件)

> 該当なし

### Medium (${medium_count}件)

$medium_findings

### Low (0件)

> 該当なし

## 除外・撤回・降格した候補

### Phase 5で除外したfindings

$excluded_section

### Phase 2〜4で棄却・撤回した候補

$earlier_section

## ラウンド別集計

| Round | 視点 | Claude状態 | Codex状態 | Claude新規 | Codex新規 | 重複 | 撤回 | 降格 | 昇格 | 据置 | 最終集合変化 |
|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|
$round_rows

## 収束判定

- 判定: $convergence_decision
- 安定round: $stable_round
- 終了条件: 実質新規0件、重要度変更0件、最終集合変化なし
- 未収束の懸念: なし
- 撤回候補: なし

## PRコメント照合結果

$comments

## 未検証事項

なし

## 実行証跡

- 対象: $target
- BASE / HEAD / merge-base: $base_sha / $head_sha / $merge_base_sha
- オーケストレーター: Codex
- Claude reviewer: Claude Code CLI test / effort=test
- Codex reviewer: Codex CLI test / reasoning=test
- review run ID: $run_id
- tooling digest: $tooling_digest
- diff digest: $diff_digest
- snapshot metadata digest: $snapshot_digest
- BASE guidance digest: $guidance_digest
- final finding-set digest: $final_set_digest
- handling digest: $handling_digest
- 初回review: $initial_review
- retry / resume / 失敗: $execution_details
- run固有report: $output
REPORT
}

echo "== R01: two runs of the same target receive distinct namespaces =="
context_a=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 42)
context_b=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 42)

run_id_a=$(printf '%s' "$context_a" | jq -r .reviewRunId)
run_id_b=$(printf '%s' "$context_b" | jq -r .reviewRunId)
run_root_a=$(printf '%s' "$context_a" | jq -r .reviewRunRoot)
run_root_b=$(printf '%s' "$context_b" | jq -r .reviewRunRoot)
artifact_a=$(printf '%s' "$context_a" | jq -r .reviewArtifactDir)
artifact_b=$(printf '%s' "$context_b" | jq -r .reviewArtifactDir)
write_context_file "$context_a" pr pr:42 42 42 ""
write_context_file "$context_b" pr pr:42 42 42 ""
for artifact in "$artifact_a" "$artifact_b"; do
  write_successful_review_evidence "$artifact"
done

if [ "$run_id_a" != "$run_id_b" ]; then
  ok "review run IDs are unique"
else
  ng "review run IDs are unique"
fi
if [ "$run_root_a" != "$run_root_b" ]; then
  ok "temporary run roots are unique"
else
  ng "temporary run roots are unique"
fi
if [ "$artifact_a" != "$artifact_b" ]; then
  ok "persistent artifact roots are unique"
else
  ng "persistent artifact roots are unique"
fi

echo "== R02: concurrent first runs safely share newly created parent directories =="
mkdir -p "$T/tooling-parallel"
parallel_ok=1
parallel_pids=""
for index in 1 2 3 4 5 6 7 8; do
  (
    DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
      --tooling-root "$T/tooling-parallel" --target parallel \
      > "$T/parallel-$index.json"
  ) &
  parallel_pids="$parallel_pids $!"
done
for pid in $parallel_pids; do
  if ! wait "$pid"; then
    parallel_ok=0
  fi
done
if [ "$parallel_ok" = "1" ]; then
  ok "all concurrent initializers succeed"
else
  ng "all concurrent initializers succeed"
fi
parallel_ids=$(jq -r .reviewRunId "$T"/parallel-*.json 2>/dev/null | sort -u | wc -l | tr -d ' ')
check "$parallel_ids" "8" "concurrent initializers retain unique run IDs"

echo "== R03: native Windows paths are returned in Git Bash form =="
windows_path=$(
  node --input-type=module -e '
    const { toBashAbsolutePath } = await import(process.argv[1]);
    process.stdout.write(toBashAbsolutePath("C:\\review\\runs\\report.md"));
  ' "$(node -e 'const { pathToFileURL } = require("node:url"); process.stdout.write(pathToFileURL(process.argv[1]).href)' "$PUBLISHER")"
)
check "$windows_path" "/c/review/runs/report.md" "Windows Node path is normalized for Git Bash"
windows_native_path=$(
  node --input-type=module -e '
    const { toNativeAbsolutePath } = await import(process.argv[1]);
    process.stdout.write(toNativeAbsolutePath("/c/review/runs/report.md", "win32"));
  ' "$(node -e 'const { pathToFileURL } = require("node:url"); process.stdout.write(pathToFileURL(process.argv[1]).href)' "$SKILL_SCRIPTS/path-interop.mjs")"
)
check "$windows_native_path" "C:/review/runs/report.md" \
  "Git Bash drive paths convert back to native Windows Node paths"
parent_directory_checks=$(
  node --input-type=module -e '
    const { sameNativeParentDirectory } = await import(process.argv[1]);
    process.stdout.write(JSON.stringify({
      windowsEquivalent: sameNativeParentDirectory(
        "C:/review/waves/wave-1-2/promotion.json",
        "C:\\review\\waves\\wave-1-2\\status.json",
        "win32",
      ),
      windowsDifferent: sameNativeParentDirectory(
        "C:/review/waves/wave-1-2/promotion.json",
        "C:\\review\\waves\\wave-3-4\\status.json",
        "win32",
      ),
      windowsParentTraversalDistinct: !sameNativeParentDirectory(
        "C:/review/waves/wave-1-2/link/../promotion.json",
        "C:\\review\\waves\\wave-1-2\\status.json",
        "win32",
      ),
      posixBackslashDistinct: !sameNativeParentDirectory(
        "/tmp/review\\waves/promotion.json",
        "/tmp/review/waves/status.json",
        "linux",
      ),
      posixParentTraversalDistinct: !sameNativeParentDirectory(
        "/tmp/review/waves/link/../promotion.json",
        "/tmp/review/waves/status.json",
        "linux",
      ),
    }));
  ' "$(node -e 'const { pathToFileURL } = require("node:url"); process.stdout.write(pathToFileURL(process.argv[1]).href)' "$PATH_INTEROP")"
)
check "$(printf '%s' "$parent_directory_checks" | jq -r .windowsEquivalent)" \
  "true" "Windows separator variants identify the same receipt directory"
check "$(printf '%s' "$parent_directory_checks" | jq -r .windowsDifferent)" \
  "false" "different Windows wave directories remain distinct"
check "$(printf '%s' "$parent_directory_checks" | jq -r .windowsParentTraversalDistinct)" \
  "true" "Windows parent traversal is not collapsed during receipt validation"
check "$(printf '%s' "$parent_directory_checks" | jq -r .posixBackslashDistinct)" \
  "true" "POSIX backslashes remain literal path characters"
check "$(printf '%s' "$parent_directory_checks" | jq -r .posixParentTraversalDistinct)" \
  "true" "POSIX parent traversal retains the strict receipt path check"
windows_promoted_path=$(
  node --input-type=module -e '
    const { replacePortablePathPrefix } = await import(process.argv[1]);
    process.stdout.write(replacePortablePathPrefix(
      "C:\\review\\waves\\round-2\\attempt-1\\claude.out",
      "/c/review/waves/round-2",
      "/c/review/phase4/round-2",
    ));
  ' "$(node -e 'const { pathToFileURL } = require("node:url"); process.stdout.write(pathToFileURL(process.argv[1]).href)' "$SKILL_SCRIPTS/path-interop.mjs")"
)
check "$windows_promoted_path" "/c/review/phase4/round-2/attempt-1/claude.out" \
  "promotion rewrites native Windows receipt paths to portable canonical paths"
windows_context=$(node "$FORMATTER" run-1 \
  'C:\review-temp' \
  'C:\review-temp\deep-review.run-1' \
  'C:\repository\_tmp\reviews\runs\42\run-1')
check "$(printf '%s' "$windows_context" | jq -r .reviewTempRoot)" \
  "/c/review-temp" "initializer context normalizes the Windows temp root"
check "$(printf '%s' "$windows_context" | jq -r .reviewRunRoot)" \
  "/c/review-temp/deep-review.run-1" "initializer context normalizes the Windows run root"
check "$(printf '%s' "$windows_context" | jq -r .reviewArtifactDir)" \
  "/c/repository/_tmp/reviews/runs/42/run-1" "initializer context normalizes the Windows artifact root"
if grep -qF 'toBashAbsolutePath(snapshotRoot)' "$SNAPSHOT_BUILDER"; then
  ok "snapshot builder normalizes its native path before returning to Bash"
else
  ng "snapshot builder normalizes its native path before returning to Bash"
fi
case "$OSTYPE" in
  msys*|cygwin*)
    windows_long_tooling=$(cd "$T/tooling" && pwd -P)
    windows_long_native=$(cygpath -w "$windows_long_tooling" 2>/dev/null)
    windows_short_tooling=$(cygpath -d "$windows_long_tooling" 2>/dev/null)
    if [ -n "$windows_short_tooling" ] &&
      [ "$windows_short_tooling" != "$windows_long_native" ]; then
      ok "Windows fixture exposes distinct long and 8.3 tooling paths"
    else
      ng "Windows fixture exposes distinct long and 8.3 tooling paths"
    fi
    for actual_path in \
      "$(printf '%s' "$context_a" | jq -r .reviewTempRoot)" \
      "$(printf '%s' "$context_a" | jq -r .reviewRunRoot)" \
      "$(printf '%s' "$context_a" | jq -r .reviewArtifactDir)"; do
      case "$actual_path" in
        /[A-Za-z]/*) ok "native Node path returns to Git Bash form: $actual_path" ;;
        *) ng "native Node path returns to Git Bash form: $actual_path" ;;
      esac
    done
    ;;
esac

echo "== R03b: read-only snapshot metadata is replaced safely =="
mkdir "$T/snapshot-repo"
git -C "$T/snapshot-repo" init -q
git -C "$T/snapshot-repo" config user.name test
git -C "$T/snapshot-repo" config user.email test@example.com
printf 'base\n' > "$T/snapshot-repo/value.txt"
git -C "$T/snapshot-repo" add value.txt
git -C "$T/snapshot-repo" commit -qm base
snapshot_base_sha=$(git -C "$T/snapshot-repo" rev-parse HEAD)
printf 'head\n' > "$T/snapshot-repo/value.txt"
git -C "$T/snapshot-repo" commit -qam head
snapshot_head_sha=$(git -C "$T/snapshot-repo" rev-parse HEAD)
snapshot_path=$(cd "$T/snapshot-repo" && node "$SNAPSHOT_BUILDER" \
  --temp-root "$T/temp" \
  --base-sha "$snapshot_base_sha" --head-sha "$snapshot_head_sha")
snapshot_rc=$?
check "$snapshot_rc" "0" "snapshot metadata can advance from building to complete"
if [ "$snapshot_rc" -eq 0 ]; then
  snapshot_metadata="$snapshot_path.metadata.json"
  if jq -e '
    .creator == "deep-review-with-claude-and-codex" and
    .state == "complete" and
    (.manifest | length) > 0
  ' "$snapshot_metadata" >/dev/null; then
    ok "the replacement publishes complete snapshot metadata"
  else
    ng "the replacement publishes complete snapshot metadata"
  fi
  if node -e '
    const { statSync } = require("node:fs");
    process.exit((statSync(process.argv[1]).mode & 0o222) === 0 ? 0 : 1);
  ' "$snapshot_metadata"; then
    ok "the published snapshot metadata remains read-only"
  else
    ng "the published snapshot metadata remains read-only"
  fi
  bash "$SNAPSHOT_CLEANUP" --temp-root "$T/temp" "$snapshot_path"
else
  ng "the replacement publishes complete snapshot metadata"
  ng "the published snapshot metadata remains read-only"
fi

echo "== R04: automation gets the exact run report while the alias updates atomically =="
write_valid_report "$artifact_a/report.md" A
write_valid_report "$artifact_b/report.md" B
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_a" --mode full \
  --report-path "$artifact_a/report.md" > "$T/published-a.out" &
publisher_a_pid=$!
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" > "$T/published-b.out" &
publisher_b_pid=$!
wait "$publisher_a_pid"
publisher_a_rc=$?
wait "$publisher_b_pid"
publisher_b_rc=$?
published_a=$(cat "$T/published-a.out")
published_b=$(cat "$T/published-b.out")

check "$publisher_a_rc" "0" "first concurrent publisher succeeds"
check "$publisher_b_rc" "0" "second concurrent publisher succeeds"
check "$published_a" "REPORT_PATH: $artifact_a/report.md" "first run returns its exact report"
check "$published_b" "REPORT_PATH: $artifact_b/report.md" "second run returns its exact report"
duration_a=$(node "$DURATION_FORMATTER" "$artifact_a/context.json")
case "$duration_a" in
  "REVIEW_DURATION: "*秒) ok "published run exposes a chat-ready review duration" ;;
  *) ng "published run exposes a chat-ready review duration" ;;
esac
if jq -e '
  .schema == "deep-review-duration/v1" and
  (.reviewStartedAtMs | type == "number") and
  (.reportPublishedAtMs | type == "number") and
  (.durationMs == .reportPublishedAtMs - .reviewStartedAtMs) and
  (.durationMs >= 0)
' "$artifact_a/timing.json" >/dev/null; then
  ok "published timing fixes the exact report-publication endpoint"
else
  ng "published timing fixes the exact report-publication endpoint"
fi
timing_b_before=$(cat "$artifact_b/timing.json")
republished_b=$(node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md")
check "$republished_b" "REPORT_PATH: $artifact_b/report.md" \
  "republication preserves the REPORT_PATH contract"
check "$(cat "$artifact_b/timing.json")" "$timing_b_before" \
  "republication preserves the first fixed publication endpoint"

echo "== R04a: publisher validates promoted wave evidence end to end =="
wave_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 50)
wave_run_id=$(printf '%s' "$wave_context" | jq -r .reviewRunId)
wave_artifact=$(printf '%s' "$wave_context" | jq -r .reviewArtifactDir)
write_context_file "$wave_context" pr pr:50 50 50 ""
write_successful_review_evidence "$wave_artifact"
promote_fixture_as_wave "$wave_artifact"
write_valid_report "$wave_artifact/report.md" wave
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 50 --run-id "$wave_run_id" --mode full \
  --report-path "$wave_artifact/report.md" > "$T/published-wave.out"
check "$?" "0" "publication accepts a complete promoted wave"
wave_source_error="$wave_artifact/phase4/waves/wave-1-2/speculative-round-2/attempt-1/codex.err"
cp "$wave_source_error" "$T/wave-source-error.backup"
printf 'tampered\n' >> "$wave_source_error"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 50 --run-id "$wave_run_id" --mode full \
  --report-path "$wave_artifact/report.md" \
  > "$T/tampered-wave-publish.out" 2> "$T/tampered-wave-publish.err"
check "$?" "1" "publication rejects tampered non-canonical wave evidence"
mv "$T/wave-source-error.backup" "$wave_source_error"

aborted_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 51)
aborted_run_id=$(printf '%s' "$aborted_context" | jq -r .reviewRunId)
aborted_artifact=$(printf '%s' "$aborted_context" | jq -r .reviewArtifactDir)
write_context_file "$aborted_context" pr pr:51 51 51 ""
write_successful_review_evidence "$aborted_artifact"
promote_fixture_as_wave "$aborted_artifact" aborted-incomplete
write_valid_report \
  "$aborted_artifact/report.md" aborted \
  "Claude 成功 / Codex 成功" \
  "speculative round incomplete" \
  1 \
  "未収束" \
  "未達"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 51 --run-id "$aborted_run_id" --mode full \
  --report-path "$aborted_artifact/report.md" \
  > "$T/aborted-wave-publish.out" 2> "$T/aborted-wave-publish.err"
check "$?" "1" "publication rejects an aborted incomplete wave"
if grep -Fq \
  "aborted incomplete speculative wave cannot be published" \
  "$T/aborted-wave-publish.err"; then
  ok "publication reports the incomplete-run boundary"
else
  ng "publication reports the incomplete-run boundary"
fi

identity_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 46)
identity_run_id=$(printf '%s' "$identity_context" | jq -r .reviewRunId)
identity_artifact=$(printf '%s' "$identity_context" | jq -r .reviewArtifactDir)
write_context_file "$identity_context" pr pr:46 46 46 ""
write_successful_review_evidence "$identity_artifact"
write_valid_report \
  "$identity_artifact/report.md" \
  identity \
  "Claude 成功 / Codex 成功" \
  "なし" \
  2 \
  "収束" \
  "連続2回" \
  false \
  retained
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 46 --run-id "$identity_run_id" --mode full \
  --report-path "$identity_artifact/report.md" >/dev/null
check "$?" "0" "publication accepts report findings derived from the final set"
original_identity_digest=$(jq -r .final.sha256 \
  "$identity_artifact/phase5/final-findings.json")
substituted_identity_digest=$(node --input-type=module - \
  "$SKILL_SCRIPTS/review-adjudication.mjs" <<'NODE'
import { pathToFileURL } from "node:url";
const { findingSetSha256 } = await import(pathToFileURL(process.argv[2]));
process.stdout.write(findingSetSha256([
  { id: "F2", severity: "Medium", title: "substituted finding" },
]));
NODE
)
cp "$identity_artifact/report.md" "$T/identity-report.md"
sed \
  -e 's/| F1 | Medium | Medium | Medium | fixture severity |/| F2 | Medium | Medium | Medium | fixture severity |/' \
  -e 's/#### M1. \[F1\] `retained()` finding/#### M1. [F2] substituted finding/' \
  -e "s/$original_identity_digest/$substituted_identity_digest/" \
  "$T/identity-report.md" > "$identity_artifact/report.md"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 46 --run-id "$identity_run_id" --mode full \
  --report-path "$identity_artifact/report.md" \
  >"$T/substituted-finding.out" 2>"$T/substituted-finding.err"
rc=$?
check "$rc" "1" \
  "publication rejects a self-consistent same-count finding substitution"
cp "$T/identity-report.md" "$identity_artifact/report.md"

retry_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 43)
retry_run_id=$(printf '%s' "$retry_context" | jq -r .reviewRunId)
retry_artifact=$(printf '%s' "$retry_context" | jq -r .reviewArtifactDir)
write_context_file "$retry_context" pr pr:43 43 43 ""
write_successful_review_evidence "$retry_artifact"
add_successful_codex_retry "$retry_artifact"
write_valid_report "$retry_artifact/report.md" retry
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 43 --run-id "$retry_run_id" --mode full \
  --report-path "$retry_artifact/report.md" \
  >"$T/retry-lie.out" 2>"$T/retry-lie.err"
rc=$?
check "$rc" "1" "report cannot hide a failed initial attempt and retry"
write_valid_report \
  "$retry_artifact/report.md" \
  retry \
  "Claude 成功 / Codex 失敗" \
  "Phase 2 Codex attempt 1 initial 失敗; Phase 2 Codex attempt 2 retry 成功"
retry_published=$(node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 43 --run-id "$retry_run_id" --mode full \
  --report-path "$retry_artifact/report.md")
check "$retry_published" "REPORT_PATH: $retry_artifact/report.md" \
  "publication accepts complete retry history and its attested canonical output"
check "$(jq -r .canonical.codex.attempt "$retry_artifact/phase2/status.json")" \
  "2" "publication fixture selects the successful retry as canonical"

cp "$retry_artifact/phase2/attempt-2/status.json" \
  "$T/retry-attempt-2-status.json"
cp "$retry_artifact/phase2/status.json" "$T/retry-pair-status.json"
alternate_codex_receipt=$(write_prompt_receipt \
  "$retry_artifact/context.json" \
  "$retry_artifact/prompts/primary-alternate-codex-review.md" \
  codex primary "" review)
jq --argjson prompt "$alternate_codex_receipt" '.codex.prompt = $prompt' \
  "$T/retry-attempt-2-status.json" \
  > "$retry_artifact/phase2/attempt-2/status.json"
rebuild_pair_status "$retry_artifact/phase2" \
  "$retry_artifact/context.json" primary null
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 43 --run-id "$retry_run_id" --mode full \
  --report-path "$retry_artifact/report.md" \
  >"$T/retry-prompt-mismatch.out" 2>"$T/retry-prompt-mismatch.err"
rc=$?
check "$rc" "1" "publication rejects a retry with a different review prompt"
cp "$T/retry-attempt-2-status.json" \
  "$retry_artifact/phase2/attempt-2/status.json"
cp "$T/retry-pair-status.json" "$retry_artifact/phase2/status.json"

resume_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 48)
resume_run_id=$(printf '%s' "$resume_context" | jq -r .reviewRunId)
resume_artifact=$(printf '%s' "$resume_context" | jq -r .reviewArtifactDir)
write_context_file "$resume_context" pr pr:48 48 48 ""
write_successful_review_evidence "$resume_artifact"
add_successful_claude_resume "$resume_artifact"
write_valid_report \
  "$resume_artifact/report.md" \
  resume \
  "Claude 失敗 / Codex 成功" \
  "Phase 2 Claude attempt 1 initial 失敗; Phase 2 Claude attempt 2 resume 成功"
resume_published=$(node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 48 --run-id "$resume_run_id" --mode full \
  --report-path "$resume_artifact/report.md")
check "$resume_published" "REPORT_PATH: $resume_artifact/report.md" \
  "publication accepts a successful resume with its attested prompt"
if jq -e '
  .canonical.claude.execution == "resume" and
  .canonical.claude.resumeId == "fixture-claude-session" and
  .canonical.claude.resumedFromAttempt == 1 and
  .attempts[1].claude.prompt.purpose == "resume"
' "$resume_artifact/phase2/status.json" >/dev/null; then
  ok "published resume preserves its execution and prompt receipt"
else
  ng "published resume preserves its execution and prompt receipt"
fi

cp "$resume_artifact/phase2/attempt-2/status.json" \
  "$T/resume-attempt-2-status.json"
cp "$resume_artifact/phase2/attempt-1/status.json" \
  "$T/resume-attempt-1-status.json"
cp "$resume_artifact/phase2/status.json" "$T/resume-pair-status.json"
jq '.claude.resumedFromAttempt = 2' \
  "$T/resume-attempt-2-status.json" \
  > "$resume_artifact/phase2/attempt-2/status.json"
rebuild_pair_status "$resume_artifact/phase2" \
  "$resume_artifact/context.json" primary null
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 48 --run-id "$resume_run_id" --mode full \
  --report-path "$resume_artifact/report.md" \
  > "$T/resume-wrong-source.out" 2> "$T/resume-wrong-source.err"
rc=$?
check "$rc" "1" \
  "publication rejects resume metadata that references the wrong attempt"
cp "$T/resume-attempt-2-status.json" \
  "$resume_artifact/phase2/attempt-2/status.json"
jq '.claude.resumeId = "other-run-session"' \
  "$T/resume-attempt-2-status.json" \
  > "$resume_artifact/phase2/attempt-2/status.json"
rebuild_pair_status "$resume_artifact/phase2" \
  "$resume_artifact/context.json" primary null
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 48 --run-id "$resume_run_id" --mode full \
  --report-path "$resume_artifact/report.md" \
  > "$T/resume-mismatched-id.out" 2> "$T/resume-mismatched-id.err"
rc=$?
check "$rc" "1" \
  "publication rejects a resume ID that differs from its source output"
cp "$T/resume-attempt-2-status.json" \
  "$resume_artifact/phase2/attempt-2/status.json"
cp "$T/resume-pair-status.json" "$resume_artifact/phase2/status.json"
jq '.claude.exitCode = 3 | .claude.evidence = null' \
  "$T/resume-attempt-1-status.json" \
  > "$resume_artifact/phase2/attempt-1/status.json"
rebuild_pair_status "$resume_artifact/phase2" \
  "$resume_artifact/context.json" primary null
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 48 --run-id "$resume_run_id" --mode full \
  --report-path "$resume_artifact/report.md" \
  > "$T/resume-after-infra.out" 2> "$T/resume-after-infra.err"
rc=$?
check "$rc" "1" \
  "publication rejects a forged resume after infrastructure exit 3"
cp "$T/resume-attempt-1-status.json" \
  "$resume_artifact/phase2/attempt-1/status.json"
cp "$T/resume-pair-status.json" "$resume_artifact/phase2/status.json"

incomplete_primary_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 47)
incomplete_primary_run_id=$(printf '%s' "$incomplete_primary_context" | jq -r .reviewRunId)
incomplete_primary_artifact=$(printf '%s' "$incomplete_primary_context" | jq -r .reviewArtifactDir)
write_context_file "$incomplete_primary_context" pr pr:47 47 47 ""
write_successful_review_evidence "$incomplete_primary_artifact"
write_valid_report \
  "$incomplete_primary_artifact/report.md" \
  incomplete-primary
jq '.codex.exitCode = 7 | .codex.evidence = null' \
  "$incomplete_primary_artifact/phase2/attempt-1/status.json" \
  > "$T/incomplete-primary-attempt.json"
mv "$T/incomplete-primary-attempt.json" \
  "$incomplete_primary_artifact/phase2/attempt-1/status.json"
rebuild_pair_status \
  "$incomplete_primary_artifact/phase2" \
  "$incomplete_primary_artifact/context.json" \
  primary null
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 47 --run-id "$incomplete_primary_run_id" --mode full \
  --report-path "$incomplete_primary_artifact/report.md" \
  > "$T/incomplete-primary.out" 2> "$T/incomplete-primary.err"
rc=$?
check "$rc" "1" \
  "publication rejects later phases after a one-sided primary failure"
if rg -q --fixed-strings \
  "Phase 2 requires successful canonical results from both reviewers" \
  "$T/incomplete-primary.err"; then
  ok "primary failure is rejected by the dual-reviewer completion gate"
else
  ng "primary failure is rejected by the dual-reviewer completion gate"
fi

degraded_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 44)
degraded_run_id=$(printf '%s' "$degraded_context" | jq -r .reviewRunId)
degraded_artifact=$(printf '%s' "$degraded_context" | jq -r .reviewArtifactDir)
write_context_file "$degraded_context" pr pr:44 44 44 ""
write_successful_review_evidence "$degraded_artifact"
write_successful_pair_status "$degraded_artifact" convergence 3
write_successful_pair_status "$degraded_artifact" convergence 4
write_valid_report \
  "$degraded_artifact/report.md" \
  degraded \
  "Claude 成功 / Codex 成功" \
  なし \
  4 \
  収束 \
  連続2回
jq '.codex.exitCode = 7 | .codex.evidence = null' \
  "$degraded_artifact/phase4/round-2/attempt-1/status.json" \
  > "$T/degraded-round-2.json"
mv "$T/degraded-round-2.json" \
  "$degraded_artifact/phase4/round-2/attempt-1/status.json"
rebuild_pair_status \
  "$degraded_artifact/phase4/round-2" \
  "$degraded_artifact/context.json" \
  convergence 2
sed \
  -e 's/| 2 | fixture | 成功 | 成功 |/| 2 | fixture | 成功 | 失敗 |/' \
  "$degraded_artifact/report.md" > "$T/degraded-report.md"
mv "$T/degraded-report.md" "$degraded_artifact/report.md"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 44 --run-id "$degraded_run_id" --mode full \
  --report-path "$degraded_artifact/report.md" \
  > "$T/degraded.out" 2> "$T/degraded.err"
rc=$?
check "$rc" "1" \
  "publication rejects later convergence after a one-sided round failure"
if rg -q --fixed-strings \
  "round 2 requires successful canonical results from both reviewers" \
  "$T/degraded.err"; then
  ok "round failure is rejected by the dual-reviewer completion gate"
else
  ng "round failure is rejected by the dual-reviewer completion gate"
fi

early_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 46)
early_run_id=$(printf '%s' "$early_context" | jq -r .reviewRunId)
early_artifact=$(printf '%s' "$early_context" | jq -r .reviewArtifactDir)
write_context_file "$early_context" pr pr:46 46 46 ""
write_successful_pair_status "$early_artifact" primary null
write_successful_pair_status "$early_artifact" convergence 1
write_valid_report \
  "$early_artifact/report.md" \
  early-unconverged \
  "Claude 成功 / Codex 成功" \
  なし \
  1 \
  未収束 \
  連続1回
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 46 --run-id "$early_run_id" --mode full \
  --report-path "$early_artifact/report.md" \
  >"$T/early-unconverged.out" 2>"$T/early-unconverged.err"
rc=$?
check "$rc" "1" \
  "publication rejects an unconverged report before the maximum round"

max_round_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 45)
max_round_run_id=$(printf '%s' "$max_round_context" | jq -r .reviewRunId)
max_round_artifact=$(printf '%s' "$max_round_context" | jq -r .reviewArtifactDir)
write_context_file "$max_round_context" pr pr:45 45 45 ""
write_successful_pair_status "$max_round_artifact" primary null
for ((round = 1; round <= 20; round++)); do
  write_successful_pair_status "$max_round_artifact" convergence "$round"
done
write_valid_report \
  "$max_round_artifact/report.md" \
  max-round \
  "Claude 成功 / Codex 成功" \
  なし \
  20 \
  未収束 \
  連続1回 \
  true
sed 's/- 未収束の懸念: なし/- 未収束の懸念: 20round到達時点で最終集合が未安定/' \
  "$max_round_artifact/report.md" > "$T/max-round-report.md"
mv "$T/max-round-report.md" "$max_round_artifact/report.md"
max_round_published=$(node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 45 --run-id "$max_round_run_id" --mode full \
  --report-path "$max_round_artifact/report.md")
check "$max_round_published" \
  "REPORT_PATH: $max_round_artifact/report.md" \
  "publication binds all twenty non-converged rounds"

cp "$max_round_artifact/phase4/round-1/adjudication.json" \
  "$T/max-round-adjudication.json"
jq '.decisions = []' "$T/max-round-adjudication.json" \
  > "$max_round_artifact/phase4/round-1/adjudication.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 45 --run-id "$max_round_run_id" --mode full \
  --report-path "$max_round_artifact/report.md" \
  >"$T/missing-candidate-decision.out" 2>"$T/missing-candidate-decision.err"
rc=$?
check "$rc" "1" "publication rejects an unadjudicated reviewer candidate"
cp "$T/max-round-adjudication.json" \
  "$max_round_artifact/phase4/round-1/adjudication.json"

jq '.summary.claudeNew = 9' "$T/max-round-adjudication.json" \
  > "$max_round_artifact/phase4/round-1/adjudication.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 45 --run-id "$max_round_run_id" --mode full \
  --report-path "$max_round_artifact/report.md" \
  >"$T/forged-adjudication-summary.out" 2>"$T/forged-adjudication-summary.err"
rc=$?
check "$rc" "1" "publication rejects a forged adjudication aggregate"
cp "$T/max-round-adjudication.json" \
  "$max_round_artifact/phase4/round-1/adjudication.json"

cp "$max_round_artifact/phase4/round-1/attempt-1/claude.out" \
  "$T/max-round-claude.out"
printf '\n' >> "$max_round_artifact/phase4/round-1/attempt-1/claude.out"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 45 --run-id "$max_round_run_id" --mode full \
  --report-path "$max_round_artifact/report.md" \
  >"$T/changed-review-output.out" 2>"$T/changed-review-output.err"
rc=$?
check "$rc" "1" "publication rejects reviewer output changed after evidence creation"
cp "$T/max-round-claude.out" \
  "$max_round_artifact/phase4/round-1/attempt-1/claude.out"

cp "$max_round_artifact/report.md" "$T/max-round-valid-report.md"
sed 's/| 1 | fixture | 成功 | 成功 | 1 |/| 1 | fixture | 成功 | 成功 | 2 |/' \
  "$T/max-round-valid-report.md" > "$max_round_artifact/report.md"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 45 --run-id "$max_round_run_id" --mode full \
  --report-path "$max_round_artifact/report.md" \
  >"$T/forged-round-table.out" 2>"$T/forged-round-table.err"
rc=$?
check "$rc" "1" "publication rejects a round aggregate not derived from adjudication"
cp "$T/max-round-valid-report.md" "$max_round_artifact/report.md"

moving_head_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 49)
moving_head_run_id=$(printf '%s' "$moving_head_context" | jq -r .reviewRunId)
moving_head_artifact=$(printf '%s' "$moving_head_context" | jq -r .reviewArtifactDir)
write_context_file "$moving_head_context" pr pr:49 49 49 ""
write_successful_review_evidence "$moving_head_artifact"
write_valid_report "$moving_head_artifact/report.md" moving-head
jq \
  '.status = "not-checked" |
   .reasons = ["PR HEAD changed during comment retrieval"] |
   .headShaAfter = "3333333333333333333333333333333333333333"' \
  "$moving_head_artifact/phase5/pr-review-context.json" \
  > "$T/moving-head-context.json"
mv "$T/moving-head-context.json" \
  "$moving_head_artifact/phase5/pr-review-context.json"
rm "$moving_head_artifact/phase5/pr-review-context.json.receipt.json"
write_pr_context_receipt "$moving_head_artifact/phase5/pr-review-context.json"
rm "$moving_head_artifact/phase5/final-findings.json"
node "$FINAL_FINDINGS" \
  --context "$moving_head_artifact/context.json" \
  --adjudication "$moving_head_artifact/phase4/round-2/adjudication.json" \
  --pr-review-context "$moving_head_artifact/phase5/pr-review-context.json" \
  --draft "$moving_head_artifact/phase5/final-findings-draft.json" \
  --output "$moving_head_artifact/phase5/final-findings.json" >/dev/null
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 49 --run-id "$moving_head_run_id" --mode full \
  --report-path "$moving_head_artifact/report.md" \
  >"$T/moving-head-status.out" 2>"$T/moving-head-status.err"
rc=$?
check "$rc" "1" "report cannot claim checked comments after the PR HEAD moves"
sed 's/- 取得状態: checked/- 取得状態: not-checked/' \
  "$moving_head_artifact/report.md" > "$T/moving-head-report.md"
mv "$T/moving-head-report.md" "$moving_head_artifact/report.md"
moving_head_published=$(node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 49 --run-id "$moving_head_run_id" --mode full \
  --report-path "$moving_head_artifact/report.md")
check "$moving_head_published" \
  "REPORT_PATH: $moving_head_artifact/report.md" \
  "moving HEAD evidence publishes only as not-checked with no exclusions"

duration_fixture="$T/duration-fixture"
mkdir "$duration_fixture"
jq -n '{reviewRunId:"duration-fixture",reviewStartedAtMs:1000}' \
  > "$duration_fixture/context.json"
jq -n '{
  schema:"deep-review-duration/v1",
  reviewRunId:"duration-fixture",
  reviewStartedAtMs:1000,
  reportPublishedAtMs:3724000,
  durationMs:3723000
}' > "$duration_fixture/timing.json"
check "$(node "$DURATION_FORMATTER" "$duration_fixture/context.json")" \
  "REVIEW_DURATION: 1時間2分3秒" \
  "duration formatter preserves hour, minute, and second boundaries"
jq '.durationMs = 1' "$duration_fixture/timing.json" \
  > "$duration_fixture/timing-invalid.json"
mv "$duration_fixture/timing-invalid.json" "$duration_fixture/timing.json"
if node "$DURATION_FORMATTER" "$duration_fixture/context.json" >/dev/null 2>&1; then
  ng "duration formatter rejects inconsistent fixed timing"
else
  ok "duration formatter rejects inconsistent fixed timing"
fi
if grep -qF 'fixture report A' "$artifact_a/report.md"; then
  ok "first run report remains unchanged"
else
  ng "first run report remains unchanged"
fi
if grep -qF 'fixture report B' "$artifact_b/report.md"; then
  ok "second run report remains unchanged"
else
  ng "second run report remains unchanged"
fi
if grep -qF 'fixture report B' "$T/tooling/_tmp/reviews/deep-review-2-42.md"; then
  ok "current compatibility alias contains the latest complete report"
else
  ng "current compatibility alias contains the latest complete report"
fi
if grep -qF 'fixture report B' "$T/tooling/_tmp/reviews/pr-42-v2.md"; then
  ok "versioned PR compatibility alias contains the latest complete report"
else
  ng "versioned PR compatibility alias contains the latest complete report"
fi
if [ ! -e "$T/tooling/_tmp/reviews/deep-review-42.md" ] &&
  [ ! -e "$T/tooling/_tmp/reviews/pr-42.md" ]; then
  ok "versioned publication does not create or overwrite old-version aliases"
else
  ng "versioned publication does not create or overwrite old-version aliases"
fi

excluded_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target 52)
excluded_run_id=$(printf '%s' "$excluded_context" | jq -r .reviewRunId)
excluded_artifact=$(printf '%s' "$excluded_context" | jq -r .reviewArtifactDir)
write_context_file "$excluded_context" pr pr:52 52 52 ""
write_successful_review_evidence "$excluded_artifact"
write_valid_report "$excluded_artifact/report.md" excluded \
  "Claude 成功 / Codex 成功" なし 2 収束 連続2回 false excluded
cp "$excluded_artifact/report.md" "$T/excluded-good-report.md"
sed 's/| X1 | F1 | `retained()` finding |/| X1 | F1 | substituted finding |/' \
  "$T/excluded-good-report.md" > "$excluded_artifact/report.md"
if node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 52 --run-id "$excluded_run_id" --mode full \
  --report-path "$excluded_artifact/report.md" >/dev/null 2>&1; then
  ng "publication rejects an excluded-candidate substitution"
else
  ok "publication rejects an excluded-candidate substitution"
fi
cp "$T/excluded-good-report.md" "$excluded_artifact/report.md"
excluded_publish=$(node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 52 --run-id "$excluded_run_id" --mode full \
  --report-path "$excluded_artifact/report.md")
check "$excluded_publish" "REPORT_PATH: $excluded_artifact/report.md" \
  "publication binds every excluded finding to the final decision artifact"

branch_context=$(DEEP_REVIEW_TEMP_ROOT="$T/temp" bash "$INITIALIZER" \
  --tooling-root "$T/tooling" --target branch-feature)
branch_run_id=$(printf '%s' "$branch_context" | jq -r .reviewRunId)
branch_artifact=$(printf '%s' "$branch_context" | jq -r .reviewArtifactDir)
write_context_file "$branch_context" branch branch:feature branch-feature "" feature
write_successful_review_evidence "$branch_artifact"
write_valid_report "$branch_artifact/report.md" branch
if jq -e '
  .schema == "deep-review-final-findings/v2" and
  .reviewMode == "branch" and
  .inputs.prReviewContext == null
' "$branch_artifact/phase5/final-findings.json" >/dev/null; then
  ok "branch finalization uses the handling-aware schema and omits PR evidence"
else
  ng "branch finalization uses the handling-aware schema and omits PR evidence"
fi
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target branch-feature --run-id "$branch_run_id" --mode full \
  --report-path "$branch_artifact/report.md" >/dev/null
if [ -f "$T/tooling/_tmp/reviews/deep-review-2-branch-feature.md" ] &&
  [ ! -e "$T/tooling/_tmp/reviews/pr-branch-feature.md" ]; then
  ok "branch reports use one collision-free human alias without a PR alias"
else
  ng "branch reports use one collision-free human alias without a PR alias"
fi

case "$OSTYPE" in
  msys*|cygwin*)
    published_short_alias=$(node "$PUBLISHER" \
      --tooling-root "$windows_short_tooling" \
      --target 42 --run-id "$run_id_a" --mode full \
      --report-path "$artifact_a/report.md")
    check "$published_short_alias" \
      "REPORT_PATH: $artifact_a/report.md" \
      "8.3 tooling path returns the initializer-selected long report path"
    ;;
esac

echo "== R05: removed single-model mode fails closed =="
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_a" --mode codex-only \
  --report-path "$artifact_a/report.md" \
  >"$T/r05.out" 2>"$T/r05.err"
rc=$?
check "$rc" "1" "single-model publication mode is rejected"

echo "== R06: caller-supplied report path must identify the selected run =="
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_a/report.md" \
  >"$T/r06.out" 2>"$T/r06.err"
rc=$?
check "$rc" "1" "a report path from another run is rejected"

echo "== R07: report content must match the selected run context and status =="
cp "$artifact_b/report.md" "$T/report-b.md"
cp "$artifact_a/report.md" "$artifact_b/report.md"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-cross-run.out" 2>"$T/r07-cross-run.err"
rc=$?
check "$rc" "1" "a structurally valid report from another run is rejected"
cp "$T/report-b.md" "$artifact_b/report.md"

cp "$artifact_b/phase4/round-2/status.json" "$T/round-2-status.json"
jq '.canonical.codex.exitCode = 1 | .complete = false' \
  "$T/round-2-status.json" > "$artifact_b/phase4/round-2/status.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-status.out" 2>"$T/r07-status.err"
rc=$?
check "$rc" "1" "reported reviewer success must match the canonical round status"
cp "$T/round-2-status.json" "$artifact_b/phase4/round-2/status.json"

cp "$artifact_b/phase2/status.json" "$T/phase2-status.json"
jq '.schema = "deep-review-pair/v4"' \
  "$T/phase2-status.json" > "$artifact_b/phase2/status.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-old-schema.out" 2>"$T/r07-old-schema.err"
rc=$?
check "$rc" "1" "legacy pair status without evidence binding is rejected"
cp "$T/phase2-status.json" "$artifact_b/phase2/status.json"

cp "$artifact_b/phase4/round-2/attempt-1/status.json" \
  "$T/round-2-attempt-status.json"
cp "$artifact_b/phase4/round-2/status.json" "$T/round-2-pair-status.json"
round_one_claude_prompt=$(jq -c '.claude.prompt' \
  "$artifact_b/phase4/round-1/attempt-1/status.json")
jq --argjson prompt "$round_one_claude_prompt" '.claude.prompt = $prompt' \
  "$T/round-2-attempt-status.json" \
  > "$artifact_b/phase4/round-2/attempt-1/status.json"
rebuild_pair_status "$artifact_b/phase4/round-2" \
  "$artifact_b/context.json" convergence 2
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-wrong-round-prompt.out" 2>"$T/r07-wrong-round-prompt.err"
rc=$?
check "$rc" "1" "publisher rejects a round-one prompt recorded for round two"
cp "$T/round-2-attempt-status.json" \
  "$artifact_b/phase4/round-2/attempt-1/status.json"
cp "$T/round-2-pair-status.json" "$artifact_b/phase4/round-2/status.json"

jq '.claude.prompt as $claudePrompt |
    .codex.prompt as $codexPrompt |
    .claude.prompt = $codexPrompt |
    .codex.prompt = $claudePrompt' \
  "$T/round-2-attempt-status.json" \
  > "$artifact_b/phase4/round-2/attempt-1/status.json"
rebuild_pair_status "$artifact_b/phase4/round-2" \
  "$artifact_b/context.json" convergence 2
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-swapped-prompts.out" 2>"$T/r07-swapped-prompts.err"
rc=$?
check "$rc" "1" "publisher rejects swapped Claude and Codex prompt receipts"
cp "$T/round-2-attempt-status.json" \
  "$artifact_b/phase4/round-2/attempt-1/status.json"
cp "$T/round-2-pair-status.json" "$artifact_b/phase4/round-2/status.json"

primary_claude_prompt="$artifact_b/prompts/primary-primary-claude-review.md"
cp "$primary_claude_prompt" "$T/primary-claude-prompt.md"
chmod u+w "$primary_claude_prompt" 2>/dev/null || true
printf 'modified after execution\n' >> "$primary_claude_prompt"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-modified-prompt.out" 2>"$T/r07-modified-prompt.err"
rc=$?
check "$rc" "1" "publisher rejects a prompt changed after its attempt"
cp "$T/primary-claude-prompt.md" "$primary_claude_prompt"
chmod 400 "$primary_claude_prompt" 2>/dev/null || true

jq '.reviewRunId = "00000000-0000-4000-8000-000000000000"' \
  "$T/phase2-status.json" > "$artifact_b/phase2/status.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-wrong-run.out" 2>"$T/r07-wrong-run.err"
rc=$?
check "$rc" "1" "pair status from another review run is rejected"
cp "$T/phase2-status.json" "$artifact_b/phase2/status.json"

final_pr_review_context="$artifact_b/phase5/pr-review-context.json"
chmod u+w "$final_pr_review_context" 2>/dev/null || true
cp "$final_pr_review_context" "$T/final-pr-review-context.json"
rm "$final_pr_review_context"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-final-pr-missing.out" 2>"$T/r07-final-pr-missing.err"
rc=$?
check "$rc" "1" "publisher requires a final Phase 5 PR comment snapshot"
cp "$T/final-pr-review-context.json" "$final_pr_review_context"

mv "$final_pr_review_context.receipt.json" \
  "$T/final-pr-review-context.receipt.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-final-pr-receipt-missing.out" \
  2>"$T/r07-final-pr-receipt-missing.err"
rc=$?
check "$rc" "1" "publisher requires the final PR comment fetch receipt"
mv "$T/final-pr-review-context.receipt.json" \
  "$final_pr_review_context.receipt.json"

cp "$artifact_b/pr-review-context.json" "$final_pr_review_context"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-final-pr-fallback.out" 2>"$T/r07-final-pr-fallback.err"
rc=$?
check "$rc" "1" "publisher rejects the initial PR snapshot copied into Phase 5"
cp "$T/final-pr-review-context.json" "$final_pr_review_context"

jq '.repositoryHost = "other.example.com"' \
  "$T/final-pr-review-context.json" > "$final_pr_review_context"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-final-pr-host.out" 2>"$T/r07-final-pr-host.err"
rc=$?
check "$rc" "1" "final PR comment snapshot from another GitHub host is rejected"
cp "$T/final-pr-review-context.json" "$final_pr_review_context"

chmod u+w "$artifact_b/pr-review-context.json" 2>/dev/null || true
cp "$artifact_b/pr-review-context.json" "$T/pr-review-context.json"
jq '.repositoryHost = "other.example.com"' \
  "$T/pr-review-context.json" > "$artifact_b/pr-review-context.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-pr-host.out" 2>"$T/r07-pr-host.err"
rc=$?
check "$rc" "1" "PR comment evidence from another GitHub host is rejected"
cp "$T/pr-review-context.json" "$artifact_b/pr-review-context.json"

jq '.repository = "other/repository"' \
  "$T/pr-review-context.json" > "$artifact_b/pr-review-context.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-pr-repository.out" 2>"$T/r07-pr-repository.err"
rc=$?
check "$rc" "1" "PR comment evidence from another repository is rejected"
cp "$T/pr-review-context.json" "$artifact_b/pr-review-context.json"

jq '.prNumber = 9999' \
  "$T/pr-review-context.json" > "$artifact_b/pr-review-context.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-pr-number.out" 2>"$T/r07-pr-number.err"
rc=$?
check "$rc" "1" "PR comment evidence from another PR is rejected"
cp "$T/pr-review-context.json" "$artifact_b/pr-review-context.json"

jq '.headShaAfter = "3333333333333333333333333333333333333333"' \
  "$T/pr-review-context.json" > "$artifact_b/pr-review-context.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-pr-head.out" 2>"$T/r07-pr-head.err"
rc=$?
check "$rc" "1" "checked PR comment evidence from another HEAD is rejected"
cp "$T/pr-review-context.json" "$artifact_b/pr-review-context.json"

jq '.counts.issueComments.raw = 1 |
    .counts.issueComments.nonBot = 1 |
    .counts.issueComments.deduped = 1 |
    .records.issueComments = [{}]' \
  "$T/final-pr-review-context.json" > "$final_pr_review_context"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-pr-count.out" 2>"$T/r07-pr-count.err"
rc=$?
check "$rc" "1" "reported PR comment counts must match their artifact"
cp "$T/final-pr-review-context.json" "$final_pr_review_context"

cp "$artifact_b/phase2/attempt-1/claude.out" "$T/phase2-claude.out"
sed '/^INPUT_ATTESTATION: verified$/d' "$T/phase2-claude.out" \
  > "$artifact_b/phase2/attempt-1/claude.out"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-attestation.out" 2>"$T/r07-attestation.err"
rc=$?
check "$rc" "1" "canonical output without input attestation is rejected"
cp "$T/phase2-claude.out" "$artifact_b/phase2/attempt-1/claude.out"

awk '
  /^INPUT_ATTESTATION: verified$/ { next }
  { print }
  /^---$/ && !moved { print "INPUT_ATTESTATION: verified"; moved = 1 }
' "$T/phase2-claude.out" > "$artifact_b/phase2/attempt-1/claude.out"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-attestation-position.out" \
  2>"$T/r07-attestation-position.err"
rc=$?
check "$rc" "1" "input attestation must be in the verified header block"
cp "$T/phase2-claude.out" "$artifact_b/phase2/attempt-1/claude.out"

cp "$artifact_b/phase2/attempt-1/status.json" "$T/phase2-attempt-status.json"
jq '.claude.exitCode = 9' "$T/phase2-attempt-status.json" \
  > "$artifact_b/phase2/attempt-1/status.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-attempt-history.out" 2>"$T/r07-attempt-history.err"
rc=$?
check "$rc" "1" "pair summary must match the persisted attempt history"
cp "$T/phase2-attempt-status.json" "$artifact_b/phase2/attempt-1/status.json"

wrong_stdout="$artifact_b/phase2/claude.out"
jq --arg stdout "$wrong_stdout" '.claude.stdout = $stdout' \
  "$T/phase2-attempt-status.json" > "$artifact_b/phase2/attempt-1/status.json"
jq --arg stdout "$wrong_stdout" '
  .attempts[0].claude.stdout = $stdout |
  .canonical.claude.stdout = $stdout
' "$T/phase2-status.json" > "$artifact_b/phase2/status.json"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-output-path.out" 2>"$T/r07-output-path.err"
rc=$?
check "$rc" "1" "canonical stdout must remain inside its selected attempt"
cp "$T/phase2-attempt-status.json" "$artifact_b/phase2/attempt-1/status.json"
cp "$T/phase2-status.json" "$artifact_b/phase2/status.json"

mkdir "$artifact_b/phase2/attempt-2"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-extra-attempt.out" 2>"$T/r07-extra-attempt.err"
rc=$?
check "$rc" "1" "unrecorded attempt directories are rejected"
rmdir "$artifact_b/phase2/attempt-2"

write_successful_pair_status "$artifact_b" convergence 3
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-extra-round.out" 2>"$T/r07-extra-round.err"
rc=$?
check "$rc" "1" "executed rounds omitted from the report are rejected"
rm -r "$artifact_b/phase4/round-3"

cp -R "$artifact_b/phase4/round-2" "$T/round-2-directory"
mkdir "$T/linked-round-2"
cp "$T/round-2-status.json" "$T/linked-round-2/status.json"
rm -r "$artifact_b/phase4/round-2"
ln -s "$T/linked-round-2" "$artifact_b/phase4/round-2"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$artifact_b/report.md" \
  >"$T/r07-status-link.out" 2>"$T/r07-status-link.err"
rc=$?
check "$rc" "1" "a symlinked round status directory is rejected"
rm "$artifact_b/phase4/round-2"
cp -R "$T/round-2-directory" "$artifact_b/phase4/round-2"

cp "$branch_artifact/report.md" "$T/branch-report.md"
sed '1s/.*/# Deep Review: PR #42/' "$T/branch-report.md" > "$branch_artifact/report.md"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target branch-feature --run-id "$branch_run_id" --mode full \
  --report-path "$branch_artifact/report.md" \
  >"$T/r07-branch.out" 2>"$T/r07-branch.err"
rc=$?
check "$rc" "1" "a PR-form report cannot be published for a branch run"
cp "$T/branch-report.md" "$branch_artifact/report.md"

echo "== R07b: dialogue tables are bound to canonical artifacts =="
for dialogue_artifact in "$identity_artifact" "$excluded_artifact" "$branch_artifact" "$retry_artifact"; do
  dialogue_target=$(jq -r .targetSlug "$dialogue_artifact/context.json")
  dialogue_run_id=$(jq -r .reviewRunId "$dialogue_artifact/context.json")
  cp "$dialogue_artifact/report.md" "$T/dialogue-legacy.md"
  node "$SCRIPTS/report-dialogue-fixture.mjs" "$T/dialogue-legacy.md" \
    "$dialogue_artifact/report.md" "$dialogue_artifact"
  node "$PUBLISHER" --tooling-root "$T/tooling" \
    --target "$dialogue_target" --run-id "$dialogue_run_id" --mode full \
    --report-path "$dialogue_artifact/report.md" >"$T/dialogue-publish.out" 2>"$T/dialogue-publish.err"
  dialogue_rc=$?
  check "$dialogue_rc" "0" "dialogue publication accepts canonical $dialogue_target artifacts"
  if [ "$dialogue_rc" != "0" ]; then
    sed -n '1,12p' "$T/dialogue-publish.err"
  fi
  cp "$dialogue_artifact/report.md" "$T/dialogue-good.md"
  for dialogue_column in 1 3; do
    node --input-type=module - "$T/dialogue-good.md" "$dialogue_artifact/report.md" "$dialogue_column" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
const [input, output, column]=process.argv.slice(2);
const content=readFileSync(input,'utf8').replace(/^\| 初回 \|.*$/mu, line=> {
  const cells=line.split('|');
  cells[Number(column)+1]=cells[Number(column)+1]
    .replace(/M(\d+)/u,(_match,n)=>`M${Number(n)+1}`)
    .replace(/計(\d+)/u,(_match,n)=>`計${Number(n)+1}`);
  return cells.join('|');
});
writeFileSync(output,content);
NODE
    node "$PUBLISHER" --tooling-root "$T/tooling" \
      --target "$dialogue_target" --run-id "$dialogue_run_id" --mode full \
      --report-path "$dialogue_artifact/report.md" >/dev/null 2>&1
    check "$?" "1" "dialogue publication rejects forged column $dialogue_column for $dialogue_target"
  done
  if [ "$dialogue_artifact" = "$identity_artifact" ]; then
    node --input-type=module - "$T/dialogue-good.md" "$dialogue_artifact/report.md" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
const [input, output]=process.argv.slice(2);
const content=readFileSync(input,'utf8')
  .replace(/^(\| M1 \| [^\n]+ \| )Medium( \| (?:Medium|未検出) \| Medium \|)$/mu,'$1High$2')
  .replace(/(モデル別重要度: Claude )`?Medium`?/u,'$1`High`');
if(content===readFileSync(input,'utf8')) throw new Error('expected model verdict fixture');
writeFileSync(output,content);
NODE
    node "$PUBLISHER" --tooling-root "$T/tooling" \
      --target "$dialogue_target" --run-id "$dialogue_run_id" --mode full \
      --report-path "$dialogue_artifact/report.md" >/dev/null 2>"$T/dialogue-model.err"
    check "$?" "1" "dialogue publication rejects a self-consistent forged model verdict"
    if rg -q 'dialogue cross-check differs from reviewer evidence' "$T/dialogue-model.err"; then
      ok "model verdict rejection is bound to canonical reviewer evidence"
    else
      ng "model verdict rejection is bound to canonical reviewer evidence"
      sed -n '1,12p' "$T/dialogue-model.err"
    fi
  fi
  cp "$T/dialogue-legacy.md" "$dialogue_artifact/report.md"
done

echo "== R07c: separate-issue partitions use final findings and preserve full audit digests =="
for partition_artifact in "$identity_artifact" "$excluded_artifact"; do
  partition_target=$(jq -r .targetSlug "$partition_artifact/context.json")
  partition_run_id=$(jq -r .reviewRunId "$partition_artifact/context.json")
  cp "$partition_artifact/report.md" "$T/partition-legacy.md"
  cp "$partition_artifact/phase5/final-findings.json" "$T/partition-final-original.json"
  jq '{decisions: [.decisions[] | {
    findingId, outcome: (if .outcome == "addressed" then "dismissed-valid" else .outcome end),
    handling: "separate-issue", handlingRationale, evidence, rationale
  }]}' "$T/partition-final-original.json" > "$T/partition-final-draft.json"
  rm "$partition_artifact/phase5/final-findings.json"
  node "$FINAL_FINDINGS" --context "$partition_artifact/context.json" \
    --adjudication "$partition_artifact/phase4/round-2/adjudication.json" \
    --pr-review-context "$partition_artifact/phase5/pr-review-context.json" \
    --draft "$T/partition-final-draft.json" \
    --output "$partition_artifact/phase5/final-findings.json" >/dev/null
  check "$?" "0" "separate-issue fixture uses the canonical finalizer for $partition_target"
  node --input-type=module - "$SCRIPTS/report-dialogue-fixture.mjs" "$T" "$partition_artifact" <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [fixturePath, root, artifact] = process.argv.slice(2);
const { dialogueFixture } = await import(pathToFileURL(fixturePath));
const original = JSON.parse(readFileSync(`${root}/partition-final-original.json`, 'utf8'));
const current = JSON.parse(readFileSync(`${artifact}/phase5/final-findings.json`, 'utf8'));
assert.equal(current.final.sha256, original.final.sha256);
assert.notEqual(current.handling.sha256, original.handling.sha256);
const retained = current.final.findings.length === 1;
const previousHandling = retained ? 'このPRでの対応候補' : '対応済み';
let legacy = readFileSync(`${root}/partition-legacy.md`, 'utf8')
  .replace(`- ${previousHandling}: 1件`, `- ${previousHandling}: 0件`)
  .replace('- 別Issue候補: 0件', '- 別Issue候補: 1件')
  .replace(`| ${previousHandling} | 1 |`, `| ${previousHandling} | 0 |`)
  .replace('| 別Issue候補 | 0 |', '| 別Issue候補 | 1 |')
  .replace(`- 今回の取扱い: \`${previousHandling}\``, '- 今回の取扱い: `別Issue候補`')
  .replace(/^(\| (?:F1|X1) \|.*)$/mu, row => row.replace(`| ${previousHandling} |`, '| 別Issue候補 |'))
  .replace(original.handling.sha256, current.handling.sha256);
if (!retained) legacy = legacy.replace('addressed=1, dismissed-valid=0', 'addressed=0, dismissed-valid=1');
const report = dialogueFixture(legacy, artifact);
writeFileSync(`${artifact}/report.md`, report);
writeFileSync(`${root}/partition-good.md`, report);
assert.ok(report.includes(retained ? '| Medium | 1 | 0 | 0 | 1 |' : '| Medium | 1 | 1 | 0 | 0 |'));
assert.ok(report.includes(`- final finding-set digest: ${original.final.sha256}`));
assert.ok(report.includes(`- handling digest: ${current.handling.sha256}`));
assert.ok(report.includes('| 別Issue候補 | 1 |'));
if (retained) {
  assert.ok(report.includes('### M1 — `retained()` finding'));
  assert.ok(report.includes('| M1 | `retained()` finding | Medium | Medium | Medium |'));
} else {
  assert.ok(report.includes('| X1 | F1 | `retained()` finding | Medium | 別Issue候補 |'));
}
const mutations = {
  'main-count': report.replace(/^(\| Medium \| \d+ \| \d+ \| )0( \| \d+ \|)$/mu,
    (_row, prefix, suffix) => `${prefix}1${suffix}`),
  'separate-count': report.replace(/^(\| Medium \| \d+ \| \d+ \| \d+ \| )(\d+)( \|)$/mu,
    (_row, prefix, number, suffix) => `${prefix}${Number(number) + 1}${suffix}`),
  'missing-separate': report.replace(/### 別Issue候補（Medium以上）\n[\s\S]*?(?=## レビューの前提と範囲)/u, ''),
  'handling-digest': report.replace(current.handling.sha256, original.handling.sha256),
};
if (retained) {
  const row = '| M1 | `retained()` finding | 別Issue候補 | 未確認 |';
  assert.ok(report.includes(row));
  mutations.promote = report.replace(row, '> 該当なし').replace('> 該当なし', row);
  mutations['canonical-handling'] = dialogueFixture(readFileSync(`${root}/partition-legacy.md`, 'utf8'), artifact)
    .replace(original.handling.sha256, current.handling.sha256);
}
for (const [name, value] of Object.entries(mutations)) {
  assert.notEqual(value, report, `mutation ${name} must change the fixture`);
  writeFileSync(`${root}/partition-${name}.md`, value);
}
NODE
  check "$?" "0" "separate-issue report preserves canonical final and handling evidence for $partition_target"
  node "$PUBLISHER" --tooling-root "$T/tooling" \
    --target "$partition_target" --run-id "$partition_run_id" --mode full \
    --report-path "$partition_artifact/report.md" >"$T/partition-publish.out" 2>"$T/partition-publish.err"
  partition_rc=$?
  check "$partition_rc" "0" "publication accepts final-only separate-issue accounting for $partition_target"
  if [ "$partition_rc" != "0" ]; then sed -n '1,12p' "$T/partition-publish.err"; fi
  partition_mutations="main-count separate-count missing-separate handling-digest"
  if [ "$partition_artifact" = "$identity_artifact" ]; then
    partition_mutations="$partition_mutations promote canonical-handling"
  fi
  for partition_mutation in $partition_mutations; do
    cp "$T/partition-$partition_mutation.md" "$partition_artifact/report.md"
    node "$PUBLISHER" --tooling-root "$T/tooling" \
      --target "$partition_target" --run-id "$partition_run_id" --mode full \
      --report-path "$partition_artifact/report.md" >/dev/null 2>"$T/partition-reject.err"
    check "$?" "1" "publication rejects $partition_mutation for $partition_target"
    if [ "$partition_mutation" = "canonical-handling" ]; then
      if rg -q 'report handling does not match the final finding artifact' "$T/partition-reject.err"; then
        ok "a self-consistent promotion is rejected against canonical handling"
      else
        ng "a self-consistent promotion is rejected against canonical handling"
        sed -n '1,12p' "$T/partition-reject.err"
      fi
    fi
  done
  cp "$T/partition-legacy.md" "$partition_artifact/report.md"
  cp "$T/partition-final-original.json" "$partition_artifact/phase5/final-findings.json"
done

echo "== R08: caller-supplied report aliases cannot bypass symlink rejection =="
ln -s "$artifact_b/report.md" "$T/caller-report-link.md"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$T/caller-report-link.md" \
  >"$T/r08-file.out" 2>"$T/r08-file.err"
rc=$?
check "$rc" "1" "a symlinked caller report path is rejected"
ln -s "$artifact_b" "$T/caller-run-link"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_b" --mode full \
  --report-path "$T/caller-run-link/report.md" \
  >"$T/r08-directory.out" 2>"$T/r08-directory.err"
rc=$?
check "$rc" "1" "a caller path with a symlinked directory is rejected"

if [ "${PATH_INTEROP_ONLY:-0}" = "1" ]; then
  echo ""
  printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
  exit "$fail"
fi

echo "== R09: a symlink cannot be published as a run report =="
rm -f "$artifact_a/report.md"
ln -s "$artifact_b/report.md" "$artifact_a/report.md"
node "$PUBLISHER" --tooling-root "$T/tooling" \
  --target 42 --run-id "$run_id_a" --mode full \
  --report-path "$artifact_a/report.md" \
  >"$T/r09.out" 2>"$T/r09.err"
rc=$?
check "$rc" "1" "symlink report is rejected"

echo ""
printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
exit "$fail"
