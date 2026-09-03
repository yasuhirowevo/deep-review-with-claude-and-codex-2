#!/usr/bin/env bash
# Run one Claude/Codex review attempt and preserve pair history.
#
# Usage:
#   run-review-pair.sh \
#     --context <context.json> \
#     [--claude-prompt <prompt-template>] \
#     [--codex-prompt <prompt-template>] \
#     --phase <primary|convergence> \
#     [--round <1..20>] \
#     [--reviewer <both|claude|codex>] \
#     [--attempt <positive-integer>] \
#     [--wave-status <status.json> --wave-role <lead|speculative> \
#      --wave-supervisor-nonce <nonce>] \
#     [--claude-resume-session-id <session-id>] \
#     [--codex-thread-id <thread-id>]
#
# Attempt 1 must launch both reviewers. Later attempts may launch only the
# failed reviewer, or both reviewers when both are retryable. Every attempt is
# immutable. The phase status selects the latest successful attempt per model,
# or the latest failed attempt when that model has no success.
# Exit 3 preserves an execution-infrastructure refusal; exits 20 and 21 remain
# the one-sided and no-success reviewer result codes.

set -uo pipefail

if [ -n "${DEEP_REVIEW_WAVE_NATIVE_PID_FD:-}" ]; then
  if [ -n "${DEEP_REVIEW_TEST_NATIVE_PID_HANDOFF_ATTEMPT_LOG:-}" ]; then
    printf '%s\n' "$$" >> "$DEEP_REVIEW_TEST_NATIVE_PID_HANDOFF_ATTEMPT_LOG"
  fi
  if [ "${DEEP_REVIEW_TEST_FAIL_NATIVE_PID_HANDOFF_ALWAYS:-}" = "1" ]; then
    exit 87
  fi
  if [ "${DEEP_REVIEW_TEST_FAIL_SPECULATIVE_NATIVE_PID_HANDOFF_ALWAYS:-}" = \
    "1" ] && [[ " $* " == *" --wave-role speculative "* ]]; then
    exit 87
  fi
  if [ -n "${DEEP_REVIEW_TEST_FAIL_FIRST_NATIVE_PID_HANDOFF_MARKER:-}" ] &&
    mkdir "$DEEP_REVIEW_TEST_FAIL_FIRST_NATIVE_PID_HANDOFF_MARKER" \
      2>/dev/null; then
    exit 87
  fi
  if [ "$DEEP_REVIEW_WAVE_NATIVE_PID_FD" != "3" ]; then
    echo "ERROR: wave native PID handoff must use file descriptor 3" >&2
    exit 2
  fi
  WAVE_HANDOFF_NATIVE_PID=$$
  case "$OSTYPE" in
    msys*|cygwin*)
      WAVE_HANDOFF_NATIVE_PID=$(sed -n '1p' "/proc/$$/winpid" 2>/dev/null) ||
        WAVE_HANDOFF_NATIVE_PID=""
      ;;
  esac
  if ! [[ "$WAVE_HANDOFF_NATIVE_PID" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: native wave pair PID is unavailable" >&2
    exit 2
  fi
  printf '%s %s\n' "$WAVE_HANDOFF_NATIVE_PID" "$$" >&3 || exit 2
  exec 3>&-
  if [ "${DEEP_REVIEW_TEST_EXIT_AFTER_NATIVE_PID_HANDOFF:-}" = "1" ]; then
    exit 86
  fi
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONTEXT_PATH=""
CLAUDE_PROMPT=""
CODEX_PROMPT=""
PHASE=""
ROUND=""
REVIEWER="both"
ATTEMPT=1
CLAUDE_RESUME_SESSION_ID=""
CODEX_THREAD_ID=""
WAVE_STATUS_PATH=""
WAVE_ROLE=""
WAVE_SUPERVISOR_NONCE=""
WAVE_PROCESS_PID=""
WAVE_CANCEL_WATCHER_PID=""
PAIR_LAUNCH_BOOKKEEPING=false
PAIR_PENDING_SIGNAL_RC=""
PAIR_PENDING_SIGNAL_NAME=""
CLAUDE_REQUESTED=false
CODEX_REQUESTED=false
CLAUDE_PID=""
CODEX_PID=""
CLAUDE_LAUNCHED=false
CODEX_LAUNCHED=false
CLAUDE_RC=125
CODEX_RC=125
INTERRUPTED=false
OUTPUT_EVIDENCE_FINALIZED=false
CLAUDE_PROMPT_RECEIPT=null
CODEX_PROMPT_RECEIPT=null
CLAUDE_EVIDENCE_RECEIPT=null
CODEX_EVIDENCE_RECEIPT=null
CLAUDE_RESUMED_FROM_ATTEMPT=null
CODEX_RESUMED_FROM_ATTEMPT=null
OUTPUT_EVIDENCE_TIMEOUT_SECONDS="${OUTPUT_EVIDENCE_TIMEOUT_SECONDS:-15}"
WAVE_REVIEWER_AUTHORIZATION_WAIT_SECONDS="${WAVE_REVIEWER_AUTHORIZATION_WAIT_SECONDS:-1200}"

if ! [[ "$OUTPUT_EVIDENCE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  [ "$OUTPUT_EVIDENCE_TIMEOUT_SECONDS" -gt 30 ]; then
  echo "ERROR: OUTPUT_EVIDENCE_TIMEOUT_SECONDS must be an integer from 1 to 30" >&2
  exit 2
fi

usage() {
  sed -n '4,15p' "$0" >&2
}

require_option_value() {
  if [ "$#" -lt 2 ]; then
    echo "ERROR: $1 requires a value" >&2
    usage
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context) require_option_value "$@"; CONTEXT_PATH="$2"; shift 2 ;;
    --claude-prompt) require_option_value "$@"; CLAUDE_PROMPT="$2"; shift 2 ;;
    --codex-prompt) require_option_value "$@"; CODEX_PROMPT="$2"; shift 2 ;;
    --phase) require_option_value "$@"; PHASE="$2"; shift 2 ;;
    --round) require_option_value "$@"; ROUND="$2"; shift 2 ;;
    --reviewer) require_option_value "$@"; REVIEWER="$2"; shift 2 ;;
    --attempt) require_option_value "$@"; ATTEMPT="$2"; shift 2 ;;
    --wave-status) require_option_value "$@"; WAVE_STATUS_PATH="$2"; shift 2 ;;
    --wave-role) require_option_value "$@"; WAVE_ROLE="$2"; shift 2 ;;
    --wave-supervisor-nonce)
      require_option_value "$@"
      WAVE_SUPERVISOR_NONCE="$2"
      shift 2
      ;;
    --claude-resume-session-id)
      require_option_value "$@"
      CLAUDE_RESUME_SESSION_ID="$2"
      shift 2
      ;;
    --codex-thread-id) require_option_value "$@"; CODEX_THREAD_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$CONTEXT_PATH" ] || [ -z "$PHASE" ]; then
  usage
  exit 2
fi
case "$REVIEWER" in
  both)
    CLAUDE_REQUESTED=true
    CODEX_REQUESTED=true
    ;;
  claude) CLAUDE_REQUESTED=true ;;
  codex) CODEX_REQUESTED=true ;;
  *)
    echo "ERROR: --reviewer must be both, claude, or codex" >&2
    exit 2
    ;;
esac
if ! [[ "$ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --attempt must be a positive integer" >&2
  exit 2
fi
if [ "$ATTEMPT" -eq 1 ] && [ "$REVIEWER" != "both" ]; then
  echo "ERROR: attempt 1 must launch both reviewers" >&2
  exit 2
fi
if $CLAUDE_REQUESTED && [ -z "$CLAUDE_PROMPT" ]; then
  echo "ERROR: --claude-prompt is required for the selected reviewer" >&2
  exit 2
fi
if $CODEX_REQUESTED && [ -z "$CODEX_PROMPT" ]; then
  echo "ERROR: --codex-prompt is required for the selected reviewer" >&2
  exit 2
fi
if ! $CLAUDE_REQUESTED && [ -n "$CLAUDE_RESUME_SESSION_ID" ]; then
  echo "ERROR: --claude-resume-session-id requires --reviewer claude or both" >&2
  exit 2
fi
if ! $CODEX_REQUESTED && [ -n "$CODEX_THREAD_ID" ]; then
  echo "ERROR: --codex-thread-id requires --reviewer codex or both" >&2
  exit 2
fi
if [ "$ATTEMPT" -eq 1 ] &&
  { [ -n "$CLAUDE_RESUME_SESSION_ID" ] || [ -n "$CODEX_THREAD_ID" ]; }; then
  echo "ERROR: resume identifiers are only valid after attempt 1" >&2
  exit 2
fi
if { [ -n "$WAVE_STATUS_PATH" ] && [ -z "$WAVE_ROLE" ]; } ||
  { [ -z "$WAVE_STATUS_PATH" ] && [ -n "$WAVE_ROLE" ]; }; then
  echo "ERROR: --wave-status and --wave-role must be supplied together" >&2
  exit 2
fi
if [ "$ATTEMPT" -eq 1 ] && [ -n "$WAVE_STATUS_PATH" ] &&
  [ -z "$WAVE_SUPERVISOR_NONCE" ]; then
  echo "ERROR: wave attempt 1 requires --wave-supervisor-nonce" >&2
  exit 2
fi
if { [ -z "$WAVE_STATUS_PATH" ] || [ "$ATTEMPT" -ne 1 ]; } &&
  [ -n "$WAVE_SUPERVISOR_NONCE" ]; then
  echo "ERROR: --wave-supervisor-nonce is only valid for wave attempt 1" >&2
  exit 2
fi
if [ -n "$WAVE_ROLE" ]; then
  case "$WAVE_ROLE" in
    lead|speculative) ;;
    *) echo "ERROR: --wave-role must be lead or speculative" >&2; exit 2 ;;
  esac
fi
if [ "$ATTEMPT" -eq 1 ] && [ -n "$WAVE_STATUS_PATH" ] &&
  { ! [[ "$WAVE_REVIEWER_AUTHORIZATION_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
    [ "$WAVE_REVIEWER_AUTHORIZATION_WAIT_SECONDS" -gt 1200 ]; }; then
  echo "ERROR: wave reviewer authorization wait must be 1 to 1200 seconds" >&2
  exit 2
fi

case "$PHASE" in
  primary)
    if [ -n "$ROUND" ]; then
      echo "ERROR: --round is only valid for convergence" >&2
      exit 2
    fi
    if [ -n "$WAVE_STATUS_PATH" ]; then
      echo "ERROR: wave options are only valid for convergence" >&2
      exit 2
    fi
    ;;
  convergence)
    if ! [[ "$ROUND" =~ ^[1-9][0-9]*$ ]] || [ "$ROUND" -gt 20 ]; then
      echo "ERROR: convergence requires --round <1..20>" >&2
      exit 2
    fi
    if [ -n "$WAVE_STATUS_PATH" ] &&
      { [ ! -f "$WAVE_STATUS_PATH" ] || [ -L "$WAVE_STATUS_PATH" ]; }; then
      echo "ERROR: wave status must be a regular non-symlink file" >&2
      exit 2
    fi
    ;;
  *)
    echo "ERROR: --phase must be primary or convergence" >&2
    exit 2
    ;;
esac

if [ ! -f "$CONTEXT_PATH" ] || [ -L "$CONTEXT_PATH" ]; then
  echo "ERROR: input must be a regular non-symlink file: $CONTEXT_PATH" >&2
  exit 2
fi
if $CLAUDE_REQUESTED &&
  { [ ! -f "$CLAUDE_PROMPT" ] || [ -L "$CLAUDE_PROMPT" ]; }; then
  echo "ERROR: input must be a regular non-symlink file: $CLAUDE_PROMPT" >&2
  exit 2
fi
if $CODEX_REQUESTED &&
  { [ ! -f "$CODEX_PROMPT" ] || [ -L "$CODEX_PROMPT" ]; }; then
  echo "ERROR: input must be a regular non-symlink file: $CODEX_PROMPT" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 2
fi

value() {
  jq -er "$1" "$CONTEXT_PATH"
}

path_for_comparison() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -am -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

paths_match() {
  local left right
  left=$(path_for_comparison "$1") || return 1
  right=$(path_for_comparison "$2") || return 1
  [ "$left" = "$right" ]
}

SKILL_DIR=$(value .skillDir)
PROJECT_ROOT=$(value .projectRoot)
REVIEW_TEMP_ROOT=$(value .reviewTempRoot)
REVIEW_ARTIFACT_DIR=$(value .reviewArtifactDir)
CODEX_LAUNCHER=$(value .codexLauncherPath)
RUN_ID=$(value .reviewRunId)
TARGET=$(value .target)
HEAD_SHA=$(value .headSha)
DIFF_FILE=$(value .diffFile)
DIFF_SHA256=$(value .diffSha256)
SNAPSHOT_DIR=$(value .reviewSnapshotDir)
SNAPSHOT_METADATA_SHA256=$(value .snapshotMetadataSha256)

SKILL_DIR_REAL=$(cd -P "$SKILL_DIR" 2>/dev/null && pwd -P) || {
  echo "ERROR: run-specific skill directory is unavailable" >&2
  exit 2
}
if ! paths_match "$SCRIPT_DIR" "$SKILL_DIR_REAL/scripts"; then
  echo "ERROR: pair runner must execute from the context's tooling snapshot" >&2
  exit 1
fi
if [ ! -f "$CODEX_LAUNCHER" ] || [ -L "$CODEX_LAUNCHER" ]; then
  echo "ERROR: trusted Codex launcher is unavailable" >&2
  exit 1
fi

PROMPT_MANIFEST_TOOL="$SKILL_DIR_REAL/scripts/review-prompt-manifest.mjs"
if [ ! -f "$PROMPT_MANIFEST_TOOL" ] || [ -L "$PROMPT_MANIFEST_TOOL" ]; then
  echo "ERROR: review prompt manifest verifier is unavailable" >&2
  exit 1
fi
RESUME_PROVENANCE_TOOL="$SKILL_DIR_REAL/scripts/review-resume-provenance.mjs"
if [ ! -f "$RESUME_PROVENANCE_TOOL" ] || [ -L "$RESUME_PROVENANCE_TOOL" ]; then
  echo "ERROR: review resume provenance verifier is unavailable" >&2
  exit 1
fi
PAIR_POLICY_TOOL="$SKILL_DIR_REAL/scripts/review-pair-policy.mjs"
if [ ! -f "$PAIR_POLICY_TOOL" ] || [ -L "$PAIR_POLICY_TOOL" ]; then
  echo "ERROR: review pair policy helper is unavailable" >&2
  exit 1
fi
OUTPUT_EVIDENCE_TOOL="$SKILL_DIR_REAL/scripts/review-output-evidence.mjs"
if [ ! -f "$OUTPUT_EVIDENCE_TOOL" ] || [ -L "$OUTPUT_EVIDENCE_TOOL" ]; then
  echo "ERROR: review output evidence builder is unavailable" >&2
  exit 1
fi
BOUNDED_OUTPUT_EVIDENCE_TOOL="$SKILL_DIR_REAL/scripts/run-output-evidence-bounded.mjs"
if [ ! -f "$BOUNDED_OUTPUT_EVIDENCE_TOOL" ] ||
  [ -L "$BOUNDED_OUTPUT_EVIDENCE_TOOL" ]; then
  echo "ERROR: bounded output evidence runner is unavailable" >&2
  exit 1
fi
WAVE_STATE_TOOL="$SKILL_DIR_REAL/scripts/review-wave-state.mjs"
if [ "$PHASE" = "convergence" ] &&
  { [ ! -f "$WAVE_STATE_TOOL" ] || [ -L "$WAVE_STATE_TOOL" ]; }; then
  echo "ERROR: review wave state tool is unavailable" >&2
  exit 1
fi

verify_prompt_manifest() {
  local reviewer="$1" prompt="$2" purpose="$3"
  local -a manifest_args
  manifest_args=(
    --verify
    --context "$CONTEXT_PATH"
    --prompt "$prompt"
    --reviewer "$reviewer"
    --phase "$PHASE"
    --purpose "$purpose"
  )
  if [ -n "$ROUND" ]; then
    manifest_args+=(--round "$ROUND")
  fi
  node "$PROMPT_MANIFEST_TOOL" "${manifest_args[@]}"
}

if $CLAUDE_REQUESTED; then
  CLAUDE_PROMPT_PURPOSE=review
  if [ -n "$CLAUDE_RESUME_SESSION_ID" ]; then
    CLAUDE_PROMPT_PURPOSE=resume
  fi
  CLAUDE_PROMPT_RECEIPT=$(verify_prompt_manifest \
    claude "$CLAUDE_PROMPT" "$CLAUDE_PROMPT_PURPOSE") || {
    echo "ERROR: Claude prompt provenance verification failed" >&2
    exit 2
  }
fi
if $CODEX_REQUESTED; then
  CODEX_PROMPT_PURPOSE=review
  if [ -n "$CODEX_THREAD_ID" ]; then
    CODEX_PROMPT_PURPOSE=resume
  fi
  CODEX_PROMPT_RECEIPT=$(verify_prompt_manifest \
    codex "$CODEX_PROMPT" "$CODEX_PROMPT_PURPOSE") || {
    echo "ERROR: Codex prompt provenance verification failed" >&2
    exit 2
  }
fi

ARTIFACT_REAL=$(cd -P "$REVIEW_ARTIFACT_DIR" 2>/dev/null && pwd -P) || {
  echo "ERROR: review artifact directory is unavailable" >&2
  exit 2
}
if ! paths_match "$ARTIFACT_REAL" "$REVIEW_ARTIFACT_DIR"; then
  echo "ERROR: review artifact directory contains symlink traversal" >&2
  exit 1
fi
if [ "$PHASE" = "primary" ]; then
  PHASE_DIR="$REVIEW_ARTIFACT_DIR/phase2"
else
  PHASE4_DIR="$REVIEW_ARTIFACT_DIR/phase4"
  PHASE4_REAL=$(cd -P "$PHASE4_DIR" 2>/dev/null && pwd -P) || {
    echo "ERROR: phase4 artifact directory is unavailable" >&2
    exit 2
  }
  if ! paths_match "$PHASE4_REAL" "$PHASE4_DIR"; then
    echo "ERROR: phase4 artifact directory contains symlink traversal" >&2
    exit 1
  fi
  if [ -n "$WAVE_STATUS_PATH" ]; then
    if [ "${DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_IGNORE_SIGNALS:-}" = "1" ]; then
      trap '' INT TERM HUP
    fi
    if [ -n "${DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX:-}" ]; then
      : > "$DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_PREFIX.$WAVE_ROLE.ready"
    fi
    if [ -n "${DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_DELAY_SECONDS:-}" ]; then
      sleep "$DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_DELAY_SECONDS"
    fi
    if [ "${DEEP_REVIEW_TEST_PRE_WAVE_CLAIM_IGNORE_SIGNALS:-}" = "1" ]; then
      trap - INT TERM HUP
    fi
    WAVE_PROCESS_PID=$$
    case "$OSTYPE" in
      msys*|cygwin*)
        WAVE_PROCESS_PID=$(sed -n '1p' "/proc/$$/winpid" 2>/dev/null) ||
          WAVE_PROCESS_PID=""
        ;;
    esac
    if ! [[ "$WAVE_PROCESS_PID" =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: native wave pair PID is unavailable" >&2
      exit 2
    fi
    wave_authorize_args=(
      authorize
      --context "$CONTEXT_PATH"
      --status "$WAVE_STATUS_PATH"
      --role "$WAVE_ROLE"
      --round "$ROUND"
      --attempt "$ATTEMPT"
      --reviewer "$REVIEWER"
    )
    if [ "$ATTEMPT" -eq 1 ]; then
      wave_authorize_args+=(
        --supervisor-nonce "$WAVE_SUPERVISOR_NONCE"
        --process-pid "$WAVE_PROCESS_PID"
        --signal-pid "$$"
      )
    fi
    if $CLAUDE_REQUESTED; then
      wave_authorize_args+=(
        --claude-prompt "$CLAUDE_PROMPT"
        --claude-prompt-purpose "$CLAUDE_PROMPT_PURPOSE"
      )
    fi
    if $CODEX_REQUESTED; then
      wave_authorize_args+=(
        --codex-prompt "$CODEX_PROMPT"
        --codex-prompt-purpose "$CODEX_PROMPT_PURPOSE"
      )
    fi
    WAVE_AUTHORIZATION=$(node "$WAVE_STATE_TOOL" "${wave_authorize_args[@]}") || exit 2
    PHASE_DIR=$(printf '%s' "$WAVE_AUTHORIZATION" | jq -er .phaseDirectory) || exit 2
  else
    if [ "$ATTEMPT" -eq 1 ]; then
      node "$WAVE_STATE_TOOL" authorize-sequential \
        --context "$CONTEXT_PATH" --round "$ROUND" >/dev/null || exit 2
    fi
    PHASE_DIR="$PHASE4_DIR/round-$ROUND"
  fi
fi

if [ "$ATTEMPT" -eq 1 ]; then
  if ! mkdir "$PHASE_DIR"; then
    echo "ERROR: pair phase directory already exists or cannot be created: $PHASE_DIR" >&2
    exit 1
  fi
  chmod 700 "$PHASE_DIR" 2>/dev/null || true
else
  PHASE_REAL=$(cd -P "$PHASE_DIR" 2>/dev/null && pwd -P) || {
    echo "ERROR: pair phase directory is unavailable for retry: $PHASE_DIR" >&2
    exit 2
  }
  if ! paths_match "$PHASE_REAL" "$PHASE_DIR"; then
    echo "ERROR: pair phase directory contains symlink traversal" >&2
    exit 1
  fi
fi

STATUS_PATH="$PHASE_DIR/status.json"
if [ "$ATTEMPT" -eq 1 ]; then
  if [ -e "$STATUS_PATH" ]; then
    echo "ERROR: pair status already exists: $STATUS_PATH" >&2
    exit 1
  fi
else
  if [ ! -f "$STATUS_PATH" ] || [ -L "$STATUS_PATH" ]; then
    echo "ERROR: prior pair status is unavailable: $STATUS_PATH" >&2
    exit 1
  fi
  if ! jq -e \
    --arg phase "$PHASE" \
    --arg round "$ROUND" \
    --arg reviewRunId "$RUN_ID" \
    '.schema == "deep-review-pair/v6" and
     .reviewRunId == $reviewRunId and
     .expectedReviewers == ["claude", "codex"] and
     .phase == $phase and
     .round == (if $round == "" then null else ($round | tonumber) end) and
     (.attempts | type == "array" and length > 0) and
     all(.attempts[]; .schema == "deep-review-attempt/v4")' \
    "$STATUS_PATH" >/dev/null; then
    echo "ERROR: prior pair status is incompatible with this attempt" >&2
    exit 1
  fi
  PREVIOUS_ATTEMPT=$(jq -er '[.attempts[].attempt] | max' "$STATUS_PATH") || exit 1
  if [ "$ATTEMPT" -ne $((PREVIOUS_ATTEMPT + 1)) ]; then
    echo "ERROR: --attempt must be the next pair attempt: $((PREVIOUS_ATTEMPT + 1))" >&2
    exit 2
  fi

  verify_resume_source() {
    local reviewer="$1" supplied_id="$2" source_attempt source_output
    local recorded_output source_exit_code source_id
    source_attempt=$(jq -er \
      --arg reviewer "$reviewer" \
      '[.attempts[] | select(.[$reviewer].requested)] |
       max_by(.attempt) | .attempt' \
      "$STATUS_PATH") || return 1
    if ! jq -e \
      --arg reviewer "$reviewer" \
      --argjson sourceAttempt "$source_attempt" \
      '.attempts[] |
       select(.attempt == $sourceAttempt) |
       .[$reviewer] |
       .requested == true and .launched == true and
       (.exitCode | type == "number") and
       .exitCode == (.exitCode | floor) and .exitCode != 0' \
      "$STATUS_PATH" >/dev/null; then
      echo "ERROR: $reviewer resume source must be its latest failed launched attempt" >&2
      return 1
    fi
    source_exit_code=$(jq -er \
      --arg reviewer "$reviewer" \
      --argjson sourceAttempt "$source_attempt" \
      '.attempts[] |
       select(.attempt == $sourceAttempt) |
       .[$reviewer].exitCode' \
      "$STATUS_PATH") || return 1
    node "$PAIR_POLICY_TOOL" transition \
      --reviewer "$reviewer" \
      --previous-exit-code "$source_exit_code" \
      --execution resume || return 1
    source_output="$PHASE_DIR/attempt-$source_attempt/$reviewer.out"
    recorded_output=$(jq -er \
      --arg reviewer "$reviewer" \
      --argjson sourceAttempt "$source_attempt" \
      '.attempts[] |
       select(.attempt == $sourceAttempt) |
       .[$reviewer].stdout' \
      "$STATUS_PATH") || return 1
    if [ "$recorded_output" != "$source_output" ] ||
      [ ! -f "$source_output" ] || [ -L "$source_output" ]; then
      echo "ERROR: $reviewer resume source output is unavailable or mismatched" >&2
      return 1
    fi
    source_id=$(node "$RESUME_PROVENANCE_TOOL" \
      --input "$source_output" --reviewer "$reviewer") || return 1
    if [ "$source_id" != "$supplied_id" ]; then
      echo "ERROR: $reviewer resume ID does not match its latest failed attempt" >&2
      return 1
    fi
    printf '%s\n' "$source_attempt"
  }

  if $CLAUDE_REQUESTED; then
    CLAUDE_CANONICAL_RC=$(jq -r '.canonical.claude.exitCode // 125' "$STATUS_PATH")
    if [ "$CLAUDE_CANONICAL_RC" -eq 0 ]; then
      echo "ERROR: canonical Claude attempt already succeeded" >&2
      exit 2
    fi
    CLAUDE_ATTEMPTS=$(jq '[.attempts[] | select(.claude.requested)] | length' "$STATUS_PATH")
    if [ "$CLAUDE_ATTEMPTS" -ge 2 ]; then
      echo "ERROR: Claude retry/resume limit has already been reached" >&2
      exit 2
    fi
    if [ -n "$CLAUDE_RESUME_SESSION_ID" ]; then
      CLAUDE_RESUMED_FROM_ATTEMPT=$(verify_resume_source \
        claude "$CLAUDE_RESUME_SESSION_ID") || exit 2
    else
      CLAUDE_INITIAL_PROMPT_SHA=$(jq -er \
        '[.attempts[].claude | select(.requested and .execution == "initial")][0].prompt.promptSha256' \
        "$STATUS_PATH") || exit 1
      CLAUDE_RETRY_PROMPT_SHA=$(printf '%s' "$CLAUDE_PROMPT_RECEIPT" | \
        jq -er .promptSha256) || exit 1
      if [ "$CLAUDE_RETRY_PROMPT_SHA" != "$CLAUDE_INITIAL_PROMPT_SHA" ]; then
        echo "ERROR: Claude retry must reuse the initial review prompt" >&2
        exit 2
      fi
    fi
  fi
  if $CODEX_REQUESTED; then
    CODEX_CANONICAL_RC=$(jq -r '.canonical.codex.exitCode // 125' "$STATUS_PATH")
    if [ "$CODEX_CANONICAL_RC" -eq 0 ]; then
      echo "ERROR: canonical Codex attempt already succeeded" >&2
      exit 2
    fi
    CODEX_ATTEMPTS=$(jq '[.attempts[] | select(.codex.requested)] | length' "$STATUS_PATH")
    if [ "$CODEX_ATTEMPTS" -ge 2 ]; then
      echo "ERROR: Codex retry/resume limit has already been reached" >&2
      exit 2
    fi
    if [ -n "$CODEX_THREAD_ID" ]; then
      CODEX_RESUMED_FROM_ATTEMPT=$(verify_resume_source \
        codex "$CODEX_THREAD_ID") || exit 2
    else
      CODEX_INITIAL_PROMPT_SHA=$(jq -er \
        '[.attempts[].codex | select(.requested and .execution == "initial")][0].prompt.promptSha256' \
        "$STATUS_PATH") || exit 1
      CODEX_RETRY_PROMPT_SHA=$(printf '%s' "$CODEX_PROMPT_RECEIPT" | \
        jq -er .promptSha256) || exit 1
      if [ "$CODEX_RETRY_PROMPT_SHA" != "$CODEX_INITIAL_PROMPT_SHA" ]; then
        echo "ERROR: Codex retry must reuse the initial review prompt" >&2
        exit 2
      fi
    fi
  fi
fi

ATTEMPT_DIR="$PHASE_DIR/attempt-$ATTEMPT"
if ! mkdir "$ATTEMPT_DIR"; then
  echo "ERROR: attempt output directory already exists or cannot be created: $ATTEMPT_DIR" >&2
  exit 1
fi
chmod 700 "$ATTEMPT_DIR" 2>/dev/null || true

CLAUDE_OUTPUT="$ATTEMPT_DIR/claude.out"
CLAUDE_ERROR="$ATTEMPT_DIR/claude.err"
CODEX_OUTPUT="$ATTEMPT_DIR/codex.out"
CODEX_ERROR="$ATTEMPT_DIR/codex.err"
ATTEMPT_STATUS_PATH="$ATTEMPT_DIR/status.json"
if $CLAUDE_REQUESTED; then
  : > "$CLAUDE_OUTPUT"
  : > "$CLAUDE_ERROR"
fi
if $CODEX_REQUESTED; then
  : > "$CODEX_OUTPUT"
  : > "$CODEX_ERROR"
fi

build_output_evidence() {
  local reviewer="$1" output="$2" evidence="$3"
  local -a evidence_args
  evidence_args=(
    --input "$output"
    --output "$evidence"
    --reviewer "$reviewer"
    --phase "$PHASE"
    --attempt "$ATTEMPT"
  )
  if [ -n "$ROUND" ]; then
    evidence_args+=(--round "$ROUND")
  fi
  node "$BOUNDED_OUTPUT_EVIDENCE_TOOL" \
    --timeout-seconds "$OUTPUT_EVIDENCE_TIMEOUT_SECONDS" \
    -- "$OUTPUT_EVIDENCE_TOOL" "${evidence_args[@]}"
}

finalize_output_evidence() {
  if $CLAUDE_REQUESTED && [ "$CLAUDE_RC" -eq 0 ] &&
    [ "$CLAUDE_EVIDENCE_RECEIPT" = null ]; then
    CLAUDE_EVIDENCE_RECEIPT=$(build_output_evidence \
      claude "$CLAUDE_OUTPUT" "$ATTEMPT_DIR/claude.evidence.json") || {
      echo "ERROR: Claude output evidence generation failed" >> "$CLAUDE_ERROR"
      CLAUDE_EVIDENCE_RECEIPT=null
      CLAUDE_RC=1
    }
  fi
  if $CODEX_REQUESTED && [ "$CODEX_RC" -eq 0 ] &&
    [ "$CODEX_EVIDENCE_RECEIPT" = null ]; then
    CODEX_EVIDENCE_RECEIPT=$(build_output_evidence \
      codex "$CODEX_OUTPUT" "$ATTEMPT_DIR/codex.evidence.json") || {
      echo "ERROR: Codex output evidence generation failed" >> "$CODEX_ERROR"
      CODEX_EVIDENCE_RECEIPT=null
      CODEX_RC=1
    }
  fi
  OUTPUT_EVIDENCE_FINALIZED=true
  if [ -n "${DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_ROLE:-}" ] &&
    [ "$DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_ROLE" = "$WAVE_ROLE" ]; then
    if [ -n "${DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_MARKER_PREFIX:-}" ]; then
      : > "$DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_MARKER_PREFIX.$WAVE_ROLE"
    fi
    if [ -n "${DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_DELAY_SECONDS:-}" ]; then
      sleep "$DEEP_REVIEW_TEST_PAIR_EVIDENCE_FINALIZED_DELAY_SECONDS" || true
    fi
  fi
}

publish_attempt_status() {
  local status_temp claude_rc_json codex_rc_json
  if $CLAUDE_REQUESTED && [ "$CLAUDE_RC" -eq 0 ] &&
    [ "$CLAUDE_EVIDENCE_RECEIPT" = null ]; then
    echo "ERROR: successful Claude attempt is missing output evidence" >&2
    return 1
  fi
  if $CODEX_REQUESTED && [ "$CODEX_RC" -eq 0 ] &&
    [ "$CODEX_EVIDENCE_RECEIPT" = null ]; then
    echo "ERROR: successful Codex attempt is missing output evidence" >&2
    return 1
  fi
  claude_rc_json=null
  codex_rc_json=null
  if $CLAUDE_REQUESTED; then claude_rc_json=$CLAUDE_RC; fi
  if $CODEX_REQUESTED; then codex_rc_json=$CODEX_RC; fi
  status_temp=$(mktemp "$ATTEMPT_DIR/.status.XXXXXX") || return 1
  MSYS2_ARG_CONV_EXCL='*' jq -n \
    --arg phase "$PHASE" \
    --arg round "$ROUND" \
    --argjson attempt "$ATTEMPT" \
    --arg claudeOutput "$CLAUDE_OUTPUT" \
    --arg claudeError "$CLAUDE_ERROR" \
    --arg codexOutput "$CODEX_OUTPUT" \
    --arg codexError "$CODEX_ERROR" \
    --argjson claudeRequested "$CLAUDE_REQUESTED" \
    --argjson claudeLaunched "$CLAUDE_LAUNCHED" \
    --argjson claudeExitCode "$claude_rc_json" \
    --argjson claudeResumed "$([ -n "$CLAUDE_RESUME_SESSION_ID" ] && printf true || printf false)" \
    --arg claudeResumeSessionId "$CLAUDE_RESUME_SESSION_ID" \
    --argjson claudeResumedFromAttempt "$CLAUDE_RESUMED_FROM_ATTEMPT" \
    --argjson claudePrompt "$CLAUDE_PROMPT_RECEIPT" \
    --argjson claudeEvidence "$CLAUDE_EVIDENCE_RECEIPT" \
    --argjson codexRequested "$CODEX_REQUESTED" \
    --argjson codexLaunched "$CODEX_LAUNCHED" \
    --argjson codexExitCode "$codex_rc_json" \
    --argjson codexResumed "$([ -n "$CODEX_THREAD_ID" ] && printf true || printf false)" \
    --arg codexThreadId "$CODEX_THREAD_ID" \
    --argjson codexResumedFromAttempt "$CODEX_RESUMED_FROM_ATTEMPT" \
    --argjson codexPrompt "$CODEX_PROMPT_RECEIPT" \
    --argjson codexEvidence "$CODEX_EVIDENCE_RECEIPT" \
    --argjson interrupted "$INTERRUPTED" \
    '{
      schema:"deep-review-attempt/v4",
      phase:$phase,
      round:(if $round == "" then null else ($round | tonumber) end),
      attempt:$attempt,
      interrupted:$interrupted,
      claude:{
        requested:$claudeRequested,
        launched:$claudeLaunched,
        exitCode:$claudeExitCode,
        execution:(if $claudeRequested then
          (if $claudeResumed then "resume"
           elif $attempt == 1 then "initial" else "retry" end)
          else null end),
        resumeId:(if $claudeResumed then $claudeResumeSessionId else null end),
        resumedFromAttempt:(if $claudeResumed then $claudeResumedFromAttempt else null end),
        prompt:(if $claudeRequested then $claudePrompt else null end),
        evidence:(if $claudeRequested and $claudeExitCode == 0 then
          $claudeEvidence else null end),
        stdout:(if $claudeRequested then $claudeOutput else null end),
        stderr:(if $claudeRequested then $claudeError else null end)
      },
      codex:{
        requested:$codexRequested,
        launched:$codexLaunched,
        exitCode:$codexExitCode,
        execution:(if $codexRequested then
          (if $codexResumed then "resume"
           elif $attempt == 1 then "initial" else "retry" end)
          else null end),
        resumeId:(if $codexResumed then $codexThreadId else null end),
        resumedFromAttempt:(if $codexResumed then $codexResumedFromAttempt else null end),
        prompt:(if $codexRequested then $codexPrompt else null end),
        evidence:(if $codexRequested and $codexExitCode == 0 then
          $codexEvidence else null end),
        stdout:(if $codexRequested then $codexOutput else null end),
        stderr:(if $codexRequested then $codexError else null end)
      }
    }' > "$status_temp" || {
      rm -f "$status_temp"
      return 1
    }
  chmod 600 "$status_temp" 2>/dev/null || true
  mv -f "$status_temp" "$ATTEMPT_STATUS_PATH"
}

publish_pair_status() {
  local status_temp attempt_status
  local -a attempt_statuses
  attempt_statuses=()
  for attempt_status in "$PHASE_DIR"/attempt-*/status.json; do
    if [ ! -f "$attempt_status" ] || [ -L "$attempt_status" ]; then
      echo "ERROR: attempt status is unavailable: $attempt_status" >&2
      return 1
    fi
    attempt_statuses+=("$attempt_status")
  done
  status_temp=$(mktemp "$PHASE_DIR/.status.XXXXXX") || return 1
  jq -s \
    --arg phase "$PHASE" \
    --arg round "$ROUND" \
    --arg reviewRunId "$RUN_ID" '
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
        round:(if $round == "" then null else ($round | tonumber) end),
        attempts:$attempts,
        canonical:{claude:$claude,codex:$codex},
        complete:(
          $claude != null and $claude.exitCode == 0 and
          $codex != null and $codex.exitCode == 0
        )
      }
    ' "${attempt_statuses[@]}" > "$status_temp" || {
      rm -f "$status_temp"
      return 1
    }
  chmod 600 "$status_temp" 2>/dev/null || true
  mv -f "$status_temp" "$STATUS_PATH"
}

publish_status() {
  publish_attempt_status && publish_pair_status
}

publish_wave_result() {
  local exit_code="$1" signal="${2:-}"
  local -a args
  if [ "$ATTEMPT" -ne 1 ] || [ -z "$WAVE_STATUS_PATH" ]; then
    return 0
  fi
  args=(
    record-result
    --context "$CONTEXT_PATH"
    --status "$WAVE_STATUS_PATH"
    --role "$WAVE_ROLE"
    --exit-code "$exit_code"
    --supervisor-nonce "$WAVE_SUPERVISOR_NONCE"
    --process-pid "$WAVE_PROCESS_PID"
  )
  if [ -n "$signal" ]; then args+=(--signal "$signal"); fi
  node "$WAVE_STATE_TOOL" "${args[@]}" >/dev/null
}

stop_wave_cancel_watcher() {
  if [ -n "$WAVE_CANCEL_WATCHER_PID" ]; then
    kill -TERM -- "-$WAVE_CANCEL_WATCHER_PID" 2>/dev/null ||
      kill "$WAVE_CANCEL_WATCHER_PID" 2>/dev/null ||
      true
    wait "$WAVE_CANCEL_WATCHER_PID" 2>/dev/null || true
    WAVE_CANCEL_WATCHER_PID=""
  fi
}

record_wave_decision_signal() {
  local signal="$1"
  if [ "$ATTEMPT" -ne 1 ] || [ "$WAVE_ROLE" != "speculative" ] ||
    [ -z "$WAVE_STATUS_PATH" ]; then
    return 0
  fi
  node "$WAVE_STATE_TOOL" record-signal \
    --context "$CONTEXT_PATH" \
    --status "$WAVE_STATUS_PATH" \
    --signal "$signal" >/dev/null 2>&1 || true
}

start_wave_cancel_watcher() {
  local pair_signal_pid="$1"
  local cancellation signal
  if [ "$ATTEMPT" -ne 1 ] || [ -z "$WAVE_STATUS_PATH" ]; then
    return 0
  fi
  set -m
  PAIR_LAUNCH_BOOKKEEPING=true
  (
    cancellation=$(node "$WAVE_STATE_TOOL" wait-cancellation \
      --context "$CONTEXT_PATH" \
      --status "$WAVE_STATUS_PATH" \
      --role "$WAVE_ROLE" \
      --supervisor-nonce "$WAVE_SUPERVISOR_NONCE" \
      --process-pid "$WAVE_PROCESS_PID") || {
        kill -TERM "$pair_signal_pid" 2>/dev/null || true
        exit 1
      }
    if [ "$(printf '%s' "$cancellation" | jq -r .done)" = "true" ]; then
      exit 0
    fi
    signal=$(printf '%s' "$cancellation" | jq -er .signal) || signal=TERM
    kill -"$signal" "$pair_signal_pid" 2>/dev/null || true
  ) &
  if [ -n "${DEEP_REVIEW_TEST_WATCHER_PID_PREFIX:-}" ]; then
    : > "$DEEP_REVIEW_TEST_WATCHER_PID_PREFIX.$WAVE_ROLE.forked"
  fi
  pause_after_pair_fork_for_test
  WAVE_CANCEL_WATCHER_PID=$!
  if [ -n "${DEEP_REVIEW_TEST_WATCHER_PID_PREFIX:-}" ]; then
    printf '%s\n' "$WAVE_CANCEL_WATCHER_PID" \
      > "$DEEP_REVIEW_TEST_WATCHER_PID_PREFIX.$WAVE_ROLE.pid"
  fi
  if [ -n "${DEEP_REVIEW_TEST_PAIR_POST_CAPTURE_DELAY_SECONDS:-}" ]; then
    sleep "$DEEP_REVIEW_TEST_PAIR_POST_CAPTURE_DELAY_SECONDS"
  fi
  finish_pair_launch_bookkeeping
  set +m
}

authorize_wave_reviewer_launch() {
  local authorization current_supervisor_nonce expiration signal signal_rc
  local active_supervisor_nonce="" wait_started_at=$SECONDS
  if [ "$ATTEMPT" -ne 1 ] || [ -z "$WAVE_STATUS_PATH" ]; then
    return 0
  fi
  while true; do
    authorization=$(node "$WAVE_STATE_TOOL" authorize-reviewers \
      --context "$CONTEXT_PATH" \
      --status "$WAVE_STATUS_PATH" \
      --role "$WAVE_ROLE" \
      --supervisor-nonce "$WAVE_SUPERVISOR_NONCE" \
      --process-pid "$WAVE_PROCESS_PID") || return 1
    current_supervisor_nonce=$(printf '%s' "$authorization" |
      jq -er .supervisorNonce) || return 1
    if [ "$current_supervisor_nonce" != "$active_supervisor_nonce" ]; then
      active_supervisor_nonce="$current_supervisor_nonce"
      wait_started_at=$SECONDS
    fi
    if [ "$(printf '%s' "$authorization" | jq -r .authorized)" = "true" ]; then
      return 0
    fi
    if [ "$(printf '%s' "$authorization" | jq -r .pending)" = "true" ]; then
      if [ "$((SECONDS - wait_started_at))" -ge \
        "$WAVE_REVIEWER_AUTHORIZATION_WAIT_SECONDS" ]; then
        expiration=$(node "$WAVE_STATE_TOOL" expire-reviewer-authorization \
          --context "$CONTEXT_PATH" \
          --status "$WAVE_STATUS_PATH" \
          --role "$WAVE_ROLE" \
          --supervisor-nonce "$WAVE_SUPERVISOR_NONCE" \
          --process-pid "$WAVE_PROCESS_PID" \
          --active-supervisor-nonce "$active_supervisor_nonce") || return 1
        current_supervisor_nonce=$(printf '%s' "$expiration" |
          jq -er .supervisorNonce) || return 1
        active_supervisor_nonce="$current_supervisor_nonce"
        wait_started_at=$SECONDS
        if [ "$(printf '%s' "$expiration" | jq -r .source)" = \
          "reviewer-authorization-timeout" ]; then
          echo "ERROR: wave reviewer authorization wait expired: $WAVE_ROLE" >&2
        fi
        continue
      fi
      sleep 0.05
      continue
    fi
    signal=$(printf '%s' "$authorization" | jq -er .signal) || signal=TERM
    case "$signal" in
      INT) signal_rc=130 ;;
      TERM) signal_rc=143 ;;
      HUP) signal_rc=129 ;;
      *) signal=TERM; signal_rc=143 ;;
    esac
    terminate_children "$signal_rc" "$signal"
  done
}

# shellcheck disable=SC2329
terminate_children() {
  local signal_rc="$1" signal_name="$2"
  local child_rc
  trap '' INT TERM HUP
  set +m 2>/dev/null || true
  stop_wave_cancel_watcher
  INTERRUPTED=true
  for child_pid in "$CLAUDE_PID" "$CODEX_PID"; do
    if [ -n "$child_pid" ]; then
      kill -TERM -- "-$child_pid" 2>/dev/null ||
        kill "$child_pid" 2>/dev/null ||
        true
    fi
  done
  if [ -n "$CLAUDE_PID" ]; then
    wait "$CLAUDE_PID" 2>/dev/null
    child_rc=$?
    CLAUDE_RC=$child_rc
    CLAUDE_PID=""
  fi
  if [ -n "$CODEX_PID" ]; then
    wait "$CODEX_PID" 2>/dev/null
    child_rc=$?
    CODEX_RC=$child_rc
    CODEX_PID=""
  fi
  finalize_output_evidence
  publish_status || true
  record_wave_decision_signal "$signal_name"
  publish_wave_result "$signal_rc" "$signal_name" || true
  exit "$signal_rc"
}

handle_pair_signal() {
  local signal_rc="$1" signal_name="$2"
  if $OUTPUT_EVIDENCE_FINALIZED; then
    return
  fi
  if $PAIR_LAUNCH_BOOKKEEPING; then
    if [ -z "$PAIR_PENDING_SIGNAL_NAME" ]; then
      PAIR_PENDING_SIGNAL_RC="$signal_rc"
      PAIR_PENDING_SIGNAL_NAME="$signal_name"
    fi
    return
  fi
  terminate_children "$signal_rc" "$signal_name"
}

finish_pair_launch_bookkeeping() {
  PAIR_LAUNCH_BOOKKEEPING=false
  if [ -n "$PAIR_PENDING_SIGNAL_NAME" ]; then
    terminate_children "$PAIR_PENDING_SIGNAL_RC" "$PAIR_PENDING_SIGNAL_NAME"
  fi
}

pause_after_pair_fork_for_test() {
  if [ -n "${DEEP_REVIEW_TEST_PAIR_POST_FORK_DELAY_SECONDS:-}" ]; then
    sleep "$DEEP_REVIEW_TEST_PAIR_POST_FORK_DELAY_SECONDS"
  fi
}

trap 'handle_pair_signal 130 INT' INT
trap 'handle_pair_signal 143 TERM' TERM
trap 'handle_pair_signal 143 HUP' HUP

VERIFY_RUN="$SKILL_DIR_REAL/scripts/verify-review-run.sh"
if $CLAUDE_REQUESTED &&
  ! bash "$VERIFY_RUN" "$CONTEXT_PATH" > "$ATTEMPT_DIR/claude-integrity.log" 2>&1; then
  : > "$CLAUDE_OUTPUT"
  : > "$CLAUDE_ERROR"
  if $CODEX_REQUESTED; then
    : > "$CODEX_OUTPUT"
    : > "$CODEX_ERROR"
  fi
  publish_status || true
  echo "ERROR: Claude pre-launch integrity verification failed" >&2
  exit 1
fi
if $CODEX_REQUESTED &&
  ! bash "$VERIFY_RUN" "$CONTEXT_PATH" > "$ATTEMPT_DIR/codex-integrity.log" 2>&1; then
  if $CLAUDE_REQUESTED; then
    : > "$CLAUDE_OUTPUT"
    : > "$CLAUDE_ERROR"
  fi
  : > "$CODEX_OUTPUT"
  : > "$CODEX_ERROR"
  publish_status || true
  echo "ERROR: Codex pre-launch integrity verification failed" >&2
  exit 1
fi

authorize_wave_reviewer_launch || {
  echo "ERROR: failed to authorize wave reviewer launch" >&2
  exit 1
}
start_wave_cancel_watcher "$$"

set -m
if $CLAUDE_REQUESTED; then
  claude_args=(
    --context "$CONTEXT_PATH"
    --project "$PROJECT_ROOT"
    --prompt-template "$CLAUDE_PROMPT"
    --diff "$DIFF_FILE"
    --snapshot "$SNAPSHOT_DIR"
    --run-id "$RUN_ID"
    --target "$TARGET"
    --head-sha "$HEAD_SHA"
    --diff-sha256 "$DIFF_SHA256"
    --snapshot-metadata-sha256 "$SNAPSHOT_METADATA_SHA256"
    --result-contract review
  )
  if [ -n "$CLAUDE_RESUME_SESSION_ID" ]; then
    claude_args+=(--resume-session-id "$CLAUDE_RESUME_SESSION_ID")
  fi
  PAIR_LAUNCH_BOOKKEEPING=true
  bash "$SKILL_DIR_REAL/scripts/run-claude-attested.sh" \
    "${claude_args[@]}" > "$CLAUDE_OUTPUT" 2> "$CLAUDE_ERROR" &
  pause_after_pair_fork_for_test
  CLAUDE_PID=$!
  CLAUDE_LAUNCHED=true
  finish_pair_launch_bookkeeping
fi

if $CODEX_REQUESTED; then
  codex_args=(
    --context "$CONTEXT_PATH"
    --project "$PROJECT_ROOT"
    --temp-root "$REVIEW_TEMP_ROOT"
    --prompt-template "$CODEX_PROMPT"
    --diff "$DIFF_FILE"
    --snapshot "$SNAPSHOT_DIR"
    --run-id "$RUN_ID"
    --target "$TARGET"
    --head-sha "$HEAD_SHA"
    --diff-sha256 "$DIFF_SHA256"
    --snapshot-metadata-sha256 "$SNAPSHOT_METADATA_SHA256"
    --result-contract review
  )
  if [ -n "$CODEX_THREAD_ID" ]; then
    codex_args+=(--thread-id "$CODEX_THREAD_ID")
  fi
  PAIR_LAUNCH_BOOKKEEPING=true
  bash "$CODEX_LAUNCHER" \
    "${codex_args[@]}" > "$CODEX_OUTPUT" 2> "$CODEX_ERROR" &
  pause_after_pair_fork_for_test
  CODEX_PID=$!
  CODEX_LAUNCHED=true
  finish_pair_launch_bookkeeping
fi
set +m

if [ -n "$CLAUDE_PID" ]; then
  wait "$CLAUDE_PID" 2>/dev/null
  CLAUDE_RC=$?
  CLAUDE_PID=""
fi
if [ -n "$CODEX_PID" ]; then
  wait "$CODEX_PID" 2>/dev/null
  CODEX_RC=$?
  CODEX_PID=""
fi

stop_wave_cancel_watcher

finalize_output_evidence

# Both reviewer processes and their output evidence are final. Keep the
# immutable attempt/pair status and wave result consistent if a cancellation
# arrives during this last publication-only section.
trap '' INT TERM HUP

publish_status || {
  echo "ERROR: failed to publish pair status" >&2
  exit 1
}

printf 'PAIR_STATUS_PATH: %s\n' "$STATUS_PATH"
printf 'ATTEMPT_STATUS_PATH: %s\n' "$ATTEMPT_STATUS_PATH"
if $CLAUDE_REQUESTED; then
  printf 'CLAUDE_OUTPUT_PATH: %s\n' "$CLAUDE_OUTPUT"
  printf 'CLAUDE_EXIT_CODE: %s\n' "$CLAUDE_RC"
fi
if $CODEX_REQUESTED; then
  printf 'CODEX_OUTPUT_PATH: %s\n' "$CODEX_OUTPUT"
  printf 'CODEX_EXIT_CODE: %s\n' "$CODEX_RC"
fi

CANONICAL_CLAUDE_RC=$(jq -r '.canonical.claude.exitCode // 125' "$STATUS_PATH")
CANONICAL_CODEX_RC=$(jq -r '.canonical.codex.exitCode // 125' "$STATUS_PATH")
PAIR_EXIT_CODE=$(node "$PAIR_POLICY_TOOL" exit-code \
  --claude-exit-code "$CANONICAL_CLAUDE_RC" \
  --codex-exit-code "$CANONICAL_CODEX_RC") || {
  echo "ERROR: failed to determine pair exit code" >&2
  exit 1
}
publish_wave_result "$PAIR_EXIT_CODE" || {
  echo "ERROR: failed to publish wave process result" >&2
  exit 1
}
if [ -n "${DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_ROLE:-}" ] &&
  [ "$DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_ROLE" = "$WAVE_ROLE" ]; then
  if [ -n "${DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_MARKER_PREFIX:-}" ]; then
    : > "$DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_MARKER_PREFIX.$WAVE_ROLE"
  fi
  if [ -n "${DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_DELAY_SECONDS:-}" ]; then
    sleep "$DEEP_REVIEW_TEST_PAIR_FINAL_RESULT_DELAY_SECONDS"
  fi
fi
exit "$PAIR_EXIT_CODE"
