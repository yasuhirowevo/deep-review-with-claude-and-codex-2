#!/usr/bin/env bash
# Start one canonical convergence round and its successor concurrently.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONTEXT_PATH=""
FIRST_ROUND=""
CLAUDE_LEAD_PROMPT=""
CODEX_LEAD_PROMPT=""
CLAUDE_SPECULATIVE_PROMPT=""
CODEX_SPECULATIVE_PROMPT=""
WAVE_STATUS_PATH=""
LEAD_PID=""
SPECULATIVE_PID=""
LEAD_NATIVE_PID=""
SPECULATIVE_NATIVE_PID=""
LEAD_RECORDED=false
SPECULATIVE_RECORDED=false
LAUNCH_BOOKKEEPING=false
ROLE_CLAIMS_PENDING=false
ROLE_CLAIM_TERMINATION_GRACE_SECONDS=5
ROLE_CLAIM_FORCE_KILL_GRACE_SECONDS=1
PAIR_PID_HANDOFF_MAX_ATTEMPTS=2
ROLE_CLAIM_TERMINATION_DEADLINE=""
WAVE_RECOVERY_WAIT_SECONDS="${WAVE_RECOVERY_WAIT_SECONDS:-1200}"
WAVE_RECOVERY_STARTED_AT=$SECONDS
PENDING_SIGNAL_CODE=""
PENDING_SIGNAL_NAME=""
if [ -n "${DEEP_REVIEW_TEST_ROLE_CLAIM_TERMINATION_GRACE_SECONDS:-}" ]; then
  ROLE_CLAIM_TERMINATION_GRACE_SECONDS="$DEEP_REVIEW_TEST_ROLE_CLAIM_TERMINATION_GRACE_SECONDS"
fi
if ! [[ "$ROLE_CLAIM_TERMINATION_GRACE_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  [ "$ROLE_CLAIM_TERMINATION_GRACE_SECONDS" -gt 60 ]; then
  echo "ERROR: wave role claim termination grace must be 1 to 60 seconds" >&2
  exit 2
fi
if ! [[ "$WAVE_RECOVERY_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  [ "$WAVE_RECOVERY_WAIT_SECONDS" -gt 1200 ]; then
  echo "ERROR: wave recovery wait must be 1 to 1200 seconds" >&2
  exit 2
fi

usage() {
  cat >&2 <<'USAGE'
Usage: run-review-wave.sh \
  --context <context.json> --first-round <1..19> \
  --claude-lead-prompt <path> --codex-lead-prompt <path> \
  --claude-speculative-prompt <path> --codex-speculative-prompt <path>
USAGE
}

require_value() {
  if [ "$#" -lt 2 ]; then
    echo "ERROR: $1 requires a value" >&2
    usage
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context) require_value "$@"; CONTEXT_PATH="$2"; shift 2 ;;
    --first-round) require_value "$@"; FIRST_ROUND="$2"; shift 2 ;;
    --claude-lead-prompt) require_value "$@"; CLAUDE_LEAD_PROMPT="$2"; shift 2 ;;
    --codex-lead-prompt) require_value "$@"; CODEX_LEAD_PROMPT="$2"; shift 2 ;;
    --claude-speculative-prompt)
      require_value "$@"
      CLAUDE_SPECULATIVE_PROMPT="$2"
      shift 2
      ;;
    --codex-speculative-prompt)
      require_value "$@"
      CODEX_SPECULATIVE_PROMPT="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

for required in \
  "$CONTEXT_PATH" "$FIRST_ROUND" \
  "$CLAUDE_LEAD_PROMPT" "$CODEX_LEAD_PROMPT" \
  "$CLAUDE_SPECULATIVE_PROMPT" "$CODEX_SPECULATIVE_PROMPT"; do
  if [ -z "$required" ]; then
    usage
    exit 2
  fi
done
if ! [[ "$FIRST_ROUND" =~ ^[1-9][0-9]*$ ]] || [ "$FIRST_ROUND" -gt 19 ]; then
  echo "ERROR: --first-round must be an integer from 1 to 19" >&2
  exit 2
fi
if [ ! -f "$CONTEXT_PATH" ] || [ -L "$CONTEXT_PATH" ]; then
  echo "ERROR: review context must be a regular non-symlink file" >&2
  exit 2
fi
for prompt in \
  "$CLAUDE_LEAD_PROMPT" "$CODEX_LEAD_PROMPT" \
  "$CLAUDE_SPECULATIVE_PROMPT" "$CODEX_SPECULATIVE_PROMPT"; do
  if [ ! -f "$prompt" ] || [ -L "$prompt" ]; then
    echo "ERROR: wave prompt must be a regular non-symlink file: $prompt" >&2
    exit 2
  fi
done

SKILL_DIR=$(jq -er .skillDir "$CONTEXT_PATH") || exit 2
REVIEW_TEMP_ROOT=$(jq -er .reviewTempRoot "$CONTEXT_PATH") || exit 2
SKILL_DIR_REAL=$(cd -P "$SKILL_DIR" 2>/dev/null && pwd -P) || {
  echo "ERROR: run-specific skill directory is unavailable" >&2
  exit 2
}
if [ "$SCRIPT_DIR" != "$SKILL_DIR_REAL/scripts" ]; then
  echo "ERROR: wave runner must execute from the context's tooling snapshot" >&2
  exit 1
fi
STATE_TOOL="$SCRIPT_DIR/review-wave-state.mjs"
PAIR_RUNNER="$SCRIPT_DIR/run-review-pair.sh"
for tool in "$STATE_TOOL" "$PAIR_RUNNER"; do
  if [ ! -f "$tool" ] || [ -L "$tool" ]; then
    echo "ERROR: required wave tool is unavailable: $tool" >&2
    exit 1
  fi
done

SPECULATIVE_ROUND=$((FIRST_ROUND + 1))
WAVE_SUPERVISOR_PID=$$
case "$OSTYPE" in
  msys*|cygwin*)
    WAVE_SUPERVISOR_PID=$(sed -n '1p' "/proc/$$/winpid" 2>/dev/null) ||
      WAVE_SUPERVISOR_PID=""
    ;;
esac
if ! [[ "$WAVE_SUPERVISOR_PID" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: native wave supervisor PID is unavailable" >&2
  exit 2
fi
RESERVATION=$(node "$STATE_TOOL" reserve \
  --context "$CONTEXT_PATH" \
  --first-round "$FIRST_ROUND" \
  --supervisor-pid "$WAVE_SUPERVISOR_PID" \
  --claude-lead-prompt "$CLAUDE_LEAD_PROMPT" \
  --codex-lead-prompt "$CODEX_LEAD_PROMPT" \
  --claude-speculative-prompt "$CLAUDE_SPECULATIVE_PROMPT" \
  --codex-speculative-prompt "$CODEX_SPECULATIVE_PROMPT") || exit 2
WAVE_STATUS_PATH=$(printf '%s' "$RESERVATION" | jq -er .statusPath) || exit 2
WAVE_SUPERVISOR_NONCE=$(printf '%s' "$RESERVATION" |
  jq -er .status.supervisor.nonce) || exit 2
LAUNCH_LEAD=$(printf '%s' "$RESERVATION" | jq -r .launch.lead) || exit 2
LAUNCH_SPECULATIVE=$(printf '%s' "$RESERVATION" |
  jq -r .launch.speculative) || exit 2
for launch in "$LAUNCH_LEAD" "$LAUNCH_SPECULATIVE"; do
  if [ "$launch" != "true" ] && [ "$launch" != "false" ]; then
    echo "ERROR: wave reservation returned an invalid launch plan" >&2
    exit 2
  fi
done

record_result() {
  local role="$1" rc="$2" signal="${3:-}"
  local -a args
  args=(
    record-result
    --context "$CONTEXT_PATH"
    --status "$WAVE_STATUS_PATH"
    --role "$role"
    --exit-code "$rc"
  )
  if [ -n "$signal" ]; then args+=(--signal "$signal"); fi
  node "$STATE_TOOL" "${args[@]}" >/dev/null || return 1
  if [ "$role" = "lead" ]; then
    LEAD_RECORDED=true
  else
    SPECULATIVE_RECORDED=true
  fi
}

recover_attached_role() {
  local role="$1" recovered
  while true; do
    recovered=$(node "$STATE_TOOL" recover-role \
      --context "$CONTEXT_PATH" \
      --status "$WAVE_STATUS_PATH" \
      --role "$role" \
      --supervisor-nonce "$WAVE_SUPERVISOR_NONCE") || return 1
    if [ "$(printf '%s' "$recovered" |
      jq -r --arg role "$role" '.[$role].process.finishedAt != null')" = "true" ]; then
      RECOVERED_RC=$(printf '%s' "$recovered" |
        jq -er --arg role "$role" '.[$role].process.exitCode') || return 1
      return 0
    fi
    if [ "$((SECONDS - WAVE_RECOVERY_STARTED_AT))" -ge \
      "$WAVE_RECOVERY_WAIT_SECONDS" ]; then
      echo "ERROR: attached wave role did not reach a terminal process state: $role" >&2
      return 1
    fi
    sleep 1
  done
}

request_wave_termination() {
  local signal="$1"
  node "$STATE_TOOL" request-termination \
    --context "$CONTEXT_PATH" \
    --status "$WAVE_STATUS_PATH" \
    --signal "$signal" \
    --supervisor-nonce "$WAVE_SUPERVISOR_NONCE" >/dev/null
}

mark_wave_reviewers_ready() {
  node "$STATE_TOOL" mark-reviewers-ready \
    --context "$CONTEXT_PATH" \
    --status "$WAVE_STATUS_PATH" \
    --supervisor-nonce "$WAVE_SUPERVISOR_NONCE" >/dev/null
}

load_wave_stop_request() {
  WAVE_STOP_SIGNAL=""
  WAVE_STOP_EXIT_CODE=1
  if [ -n "$PENDING_SIGNAL_NAME" ]; then
    WAVE_STOP_SIGNAL="$PENDING_SIGNAL_NAME"
    WAVE_STOP_EXIT_CODE="$PENDING_SIGNAL_CODE"
    return 0
  fi
  WAVE_STOP_SIGNAL=$(jq -er '.termination.signal // empty' \
    "$WAVE_STATUS_PATH") || return 1
  case "$WAVE_STOP_SIGNAL" in
    INT) WAVE_STOP_EXIT_CODE=130 ;;
    HUP) WAVE_STOP_EXIT_CODE=129 ;;
    TERM) WAVE_STOP_EXIT_CODE=143 ;;
  esac
}

ensure_role_termination_deadline() {
  if [ -z "$ROLE_CLAIM_TERMINATION_DEADLINE" ]; then
    ROLE_CLAIM_TERMINATION_DEADLINE=$((
      SECONDS + ROLE_CLAIM_TERMINATION_GRACE_SECONDS
    ))
  fi
}

create_pair_pid_handoff() {
  local role="$1"
  mktemp "$REVIEW_TEMP_ROOT/wave-$role-native-pid.XXXXXX"
}

read_pair_pid_handoff() {
  local handoff_path="$1" child_pid="$2" deadline native_pid signal_pid
  deadline=$((SECONDS + 5))
  while [ ! -s "$handoff_path" ] && [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  read -r native_pid signal_pid < "$handoff_path" || {
    rm -f "$handoff_path"
    return 1
  }
  rm -f "$handoff_path"
  if ! [[ "$native_pid" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "$signal_pid" =~ ^[1-9][0-9]*$ ]] ||
    [ "$signal_pid" -ne "$child_pid" ]; then
    return 1
  fi
  PAIR_HANDOFF_NATIVE_PID="$native_pid"
}

role_launch_is_unclaimed() {
  local role="$1" state
  state=$(node "$STATE_TOOL" role-state \
    --context "$CONTEXT_PATH" \
    --status "$WAVE_STATUS_PATH" \
    --role "$role") || return 1
  [ "$(printf '%s' "$state" | jq -r \
    '.process.startedAt == null and .process.reviewersAuthorizedAt == null')" = \
    "true" ]
}

stop_failed_pid_handoff_child() {
  local role="$1" child_pid="$2" signal="$3" deadline persisted_signal
  if [ -n "${DEEP_REVIEW_TEST_PID_HANDOFF_CLEANUP_MARKER:-}" ]; then
    : > "$DEEP_REVIEW_TEST_PID_HANDOFF_CLEANUP_MARKER.$role"
  fi
  if [ -n "${DEEP_REVIEW_TEST_PID_HANDOFF_CLEANUP_DELAY_SECONDS:-}" ]; then
    sleep "$DEEP_REVIEW_TEST_PID_HANDOFF_CLEANUP_DELAY_SECONDS"
  fi
  if [ -n "$PENDING_SIGNAL_NAME" ]; then
    signal="$PENDING_SIGNAL_NAME"
  else
    persisted_signal=$(jq -er '.termination.signal // empty' \
      "$WAVE_STATUS_PATH") || persisted_signal=""
    if [ -n "$persisted_signal" ]; then signal="$persisted_signal"; fi
  fi
  if process_group_is_alive "$child_pid"; then
    kill -"$signal" -- "-$child_pid" 2>/dev/null ||
      kill -"$signal" "$child_pid" 2>/dev/null ||
      true
  fi
  deadline=$((SECONDS + ROLE_CLAIM_TERMINATION_GRACE_SECONDS))
  while process_group_is_alive "$child_pid" &&
    [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.05
  done
  if process_group_is_alive "$child_pid" &&
    role_has_no_authorized_reviewers "$role"; then
    kill -KILL -- "-$child_pid" 2>/dev/null ||
      kill -KILL "$child_pid" 2>/dev/null ||
      true
  fi
  wait "$child_pid" 2>/dev/null
  HANDOFF_CHILD_RC=$?
  if process_group_is_alive "$child_pid"; then
    echo "ERROR: failed PID handoff child group is still alive: $role" >&2
    return 1
  fi
}

record_pid_handoff_failure() {
  local role="$1" rc="$2" signal="$3" signal_pid="$4"
  node "$STATE_TOOL" record-handoff-failure \
    --context "$CONTEXT_PATH" \
    --status "$WAVE_STATUS_PATH" \
    --role "$role" \
    --exit-code "$rc" \
    --signal "$signal" \
    --supervisor-nonce "$WAVE_SUPERVISOR_NONCE" \
    --signal-pid "$signal_pid" >/dev/null || return 1
  if [ "$role" = "lead" ]; then
    LEAD_RECORDED=true
  else
    SPECULATIVE_RECORDED=true
  fi
}

handle_pair_pid_handoff_failure() {
  local role="$1" child_pid="$2" attempt="$3"
  local cleanup_signal="${PENDING_SIGNAL_NAME:-TERM}"
  local signal exit_code=1 internal_termination=false
  stop_failed_pid_handoff_child "$role" "$child_pid" "$cleanup_signal" ||
    terminate_wave 1 "$cleanup_signal"
  if [ "$role" = "lead" ]; then
    LEAD_PID=""
  else
    SPECULATIVE_PID=""
  fi
  if ! role_launch_is_unclaimed "$role"; then
    signal="${PENDING_SIGNAL_NAME:-$cleanup_signal}"
    record_result "$role" "$HANDOFF_CHILD_RC" "$signal" || true
    case "$signal" in
      INT) exit_code=130 ;;
      HUP) exit_code=129 ;;
      TERM) exit_code="${PENDING_SIGNAL_CODE:-1}" ;;
    esac
    terminate_wave "$exit_code" "$signal"
  fi
  if [ "$attempt" -lt "$PAIR_PID_HANDOFF_MAX_ATTEMPTS" ] &&
    [ -z "$PENDING_SIGNAL_NAME" ] &&
    [ "$(jq -r '.termination == null' "$WAVE_STATUS_PATH")" = "true" ]; then
    if [ -n "${DEEP_REVIEW_TEST_PID_HANDOFF_RETRY_MARKER:-}" ]; then
      : > "$DEEP_REVIEW_TEST_PID_HANDOFF_RETRY_MARKER.$role"
    fi
    if [ -n "${DEEP_REVIEW_TEST_PID_HANDOFF_RETRY_DELAY_SECONDS:-}" ]; then
      sleep "$DEEP_REVIEW_TEST_PID_HANDOFF_RETRY_DELAY_SECONDS"
    fi
    echo "WARN: $role native PID handoff failed; retrying pair startup once" >&2
    return 0
  fi
  if [ "$(jq -r '.termination == null' "$WAVE_STATUS_PATH")" = "true" ] &&
    request_wave_termination TERM; then
    internal_termination=true
  fi
  signal=$(jq -er .termination.signal "$WAVE_STATUS_PATH") || signal=TERM
  if ! $internal_termination; then
    case "$signal" in
      INT) exit_code=130 ;;
      HUP) exit_code=129 ;;
      TERM) exit_code=143 ;;
    esac
  fi
  record_pid_handoff_failure \
    "$role" "$HANDOFF_CHILD_RC" "$signal" "$child_pid" ||
    terminate_wave "$exit_code" "$signal"
  echo "ERROR: $role native PID handoff failed after one retry" >&2
  terminate_wave "$exit_code" "$signal"
}

process_group_is_alive() {
  kill -0 -- "-$1" 2>/dev/null
}

role_has_no_authorized_reviewers() {
  local role="$1" state
  state=$(node "$STATE_TOOL" role-state \
    --context "$CONTEXT_PATH" \
    --status "$WAVE_STATUS_PATH" \
    --role "$role") || return 1
  [ "$(printf '%s' "$state" | jq -r \
    '.process.reviewersAuthorizedAt == null')" = "true" ]
}

abort_local_role() {
  local role="$1" rc="$2" signal="$3" native_pid="$4" signal_pid="$5"
  node "$STATE_TOOL" abort-unclaimed \
    --context "$CONTEXT_PATH" \
    --status "$WAVE_STATUS_PATH" \
    --role "$role" \
    --exit-code "$rc" \
    --signal "$signal" \
    --supervisor-nonce "$WAVE_SUPERVISOR_NONCE" \
    --process-pid "$native_pid" \
    --signal-pid "$signal_pid" >/dev/null || return 1
  if [ "$role" = "lead" ]; then
    LEAD_RECORDED=true
    LEAD_PID=""
  else
    SPECULATIVE_RECORDED=true
    SPECULATIVE_PID=""
  fi
}

finish_terminated_local_role() {
  local role="$1" child_pid="$2" native_pid="$3" signal="$4"
  local child_rc force_kill_deadline
  ensure_role_termination_deadline
  while kill -0 "$child_pid" 2>/dev/null &&
    [ "$SECONDS" -lt "$ROLE_CLAIM_TERMINATION_DEADLINE" ]; do
    sleep 0.05
  done
  if process_group_is_alive "$child_pid"; then
    kill -"$signal" -- "-$child_pid" 2>/dev/null ||
      kill -"$signal" "$child_pid" 2>/dev/null ||
      true
  fi
  force_kill_deadline=$((SECONDS + ROLE_CLAIM_FORCE_KILL_GRACE_SECONDS))
  while process_group_is_alive "$child_pid" &&
    [ "$SECONDS" -lt "$force_kill_deadline" ]; do
    sleep 0.05
  done
  if process_group_is_alive "$child_pid" &&
    role_has_no_authorized_reviewers "$role"; then
    kill -KILL -- "-$child_pid" 2>/dev/null ||
      kill -KILL "$child_pid" 2>/dev/null ||
      true
  fi
  wait "$child_pid" 2>/dev/null
  child_rc=$?
  abort_local_role "$role" "$child_rc" "$signal" \
    "$native_pid" "$child_pid"
}

wait_for_role_claim() {
  local role="$1" child_pid="$2" native_pid="$3" state child_rc
  while true; do
    state=$(node "$STATE_TOOL" role-state \
      --context "$CONTEXT_PATH" \
      --status "$WAVE_STATUS_PATH" \
      --role "$role") || return 1
    if [ "$(printf '%s' "$state" | jq -r '.process.startedAt != null')" = "true" ]; then
      return 0
    fi
    if ! kill -0 "$child_pid" 2>/dev/null; then
      wait "$child_pid" 2>/dev/null
      child_rc=$?
      if [ -n "$PENDING_SIGNAL_NAME" ]; then
        abort_local_role "$role" "$child_rc" "$PENDING_SIGNAL_NAME" \
          "$native_pid" "$child_pid" || return 1
        return 0
      fi
      echo "ERROR: wave $role exited before claiming its launch: $child_rc" >&2
      return 1
    fi
    if [ -n "$PENDING_SIGNAL_NAME" ]; then
      ensure_role_termination_deadline
      if [ "$SECONDS" -ge "$ROLE_CLAIM_TERMINATION_DEADLINE" ]; then
        finish_terminated_local_role \
          "$role" "$child_pid" "$native_pid" "$PENDING_SIGNAL_NAME" ||
          return 1
        return 0
      fi
    fi
    sleep 0.05
  done
}

terminate_wave() {
  local exit_code="$1" signal="$2"
  trap '' INT TERM HUP
  set +m 2>/dev/null || true
  if [ -z "$PENDING_SIGNAL_NAME" ]; then
    PENDING_SIGNAL_CODE="$exit_code"
    PENDING_SIGNAL_NAME="$signal"
  fi
  ensure_role_termination_deadline
  request_wave_termination "$signal" || true
  if [ -n "$LEAD_PID" ] && ! $LEAD_RECORDED; then
    finish_terminated_local_role \
      lead "$LEAD_PID" "$LEAD_NATIVE_PID" "$signal" || true
  fi
  if [ -n "$SPECULATIVE_PID" ] && ! $SPECULATIVE_RECORDED; then
    finish_terminated_local_role \
      speculative "$SPECULATIVE_PID" "$SPECULATIVE_NATIVE_PID" "$signal" ||
      true
  fi
  if [ "$LAUNCH_LEAD" = "false" ] && ! $LEAD_RECORDED; then
    recover_attached_role lead || true
    LEAD_RECORDED=true
  fi
  if [ "$LAUNCH_SPECULATIVE" = "false" ] && ! $SPECULATIVE_RECORDED; then
    recover_attached_role speculative || true
    SPECULATIVE_RECORDED=true
  fi
  exit "$exit_code"
}

handle_wave_signal() {
  local exit_code="$1" signal="$2"
  if $LAUNCH_BOOKKEEPING || $ROLE_CLAIMS_PENDING; then
    if [ -z "$PENDING_SIGNAL_NAME" ]; then
      PENDING_SIGNAL_CODE="$exit_code"
      PENDING_SIGNAL_NAME="$signal"
      ensure_role_termination_deadline
      request_wave_termination "$signal" || true
    fi
    return
  fi
  terminate_wave "$exit_code" "$signal"
}

finish_launch_bookkeeping() {
  LAUNCH_BOOKKEEPING=false
  if ! $ROLE_CLAIMS_PENDING && [ -n "$PENDING_SIGNAL_NAME" ]; then
    terminate_wave "$PENDING_SIGNAL_CODE" "$PENDING_SIGNAL_NAME"
  fi
}

finish_role_claims() {
  ROLE_CLAIMS_PENDING=false
  if [ -n "$PENDING_SIGNAL_NAME" ]; then
    terminate_wave "$PENDING_SIGNAL_CODE" "$PENDING_SIGNAL_NAME"
  fi
}

pause_after_fork_for_test() {
  if [ -n "${DEEP_REVIEW_TEST_POST_FORK_DELAY_SECONDS:-}" ]; then
    sleep "$DEEP_REVIEW_TEST_POST_FORK_DELAY_SECONDS"
  fi
}

if [ "$LAUNCH_LEAD" = "true" ] || [ "$LAUNCH_SPECULATIVE" = "true" ]; then
  ROLE_CLAIMS_PENDING=true
fi
trap 'handle_wave_signal 130 INT' INT
trap 'handle_wave_signal 143 TERM' TERM
trap 'handle_wave_signal 129 HUP' HUP

set -m
if [ "$LAUNCH_LEAD" = "true" ]; then
  LEAD_HANDOFF_ATTEMPT=1
  while true; do
    if load_wave_stop_request; then
      terminate_wave "$WAVE_STOP_EXIT_CODE" "$WAVE_STOP_SIGNAL"
    fi
    LAUNCH_BOOKKEEPING=true
    LEAD_PID_HANDOFF=$(create_pair_pid_handoff lead) || {
      echo "ERROR: cannot create the lead native PID handoff" >&2
      exit 1
    }
    exec 3> "$LEAD_PID_HANDOFF" || {
      rm -f "$LEAD_PID_HANDOFF"
      echo "ERROR: cannot open the lead native PID handoff" >&2
      exit 1
    }
    if load_wave_stop_request; then
      exec 3>&-
      rm -f "$LEAD_PID_HANDOFF"
      terminate_wave "$WAVE_STOP_EXIT_CODE" "$WAVE_STOP_SIGNAL"
    fi
    DEEP_REVIEW_WAVE_NATIVE_PID_FD=3 \
    WAVE_REVIEWER_AUTHORIZATION_WAIT_SECONDS="$WAVE_RECOVERY_WAIT_SECONDS" \
      bash "$PAIR_RUNNER" \
      --context "$CONTEXT_PATH" \
      --claude-prompt "$CLAUDE_LEAD_PROMPT" \
      --codex-prompt "$CODEX_LEAD_PROMPT" \
      --phase convergence \
      --round "$FIRST_ROUND" \
      --reviewer both \
      --attempt 1 \
      --wave-status "$WAVE_STATUS_PATH" \
      --wave-role lead \
      --wave-supervisor-nonce "$WAVE_SUPERVISOR_NONCE" 3>&3 &
    LEAD_PID=$!
    exec 3>&-
    pause_after_fork_for_test
    PAIR_HANDOFF_NATIVE_PID=""
    if read_pair_pid_handoff "$LEAD_PID_HANDOFF" "$LEAD_PID"; then
      LEAD_NATIVE_PID="$PAIR_HANDOFF_NATIVE_PID"
      finish_launch_bookkeeping
      break
    fi
    handle_pair_pid_handoff_failure \
      lead "$LEAD_PID" "$LEAD_HANDOFF_ATTEMPT"
    LEAD_HANDOFF_ATTEMPT=$((LEAD_HANDOFF_ATTEMPT + 1))
  done
fi

if [ "$LAUNCH_SPECULATIVE" = "true" ]; then
  SPECULATIVE_HANDOFF_ATTEMPT=1
  while true; do
    if load_wave_stop_request; then
      terminate_wave "$WAVE_STOP_EXIT_CODE" "$WAVE_STOP_SIGNAL"
    fi
    LAUNCH_BOOKKEEPING=true
    SPECULATIVE_PID_HANDOFF=$(create_pair_pid_handoff speculative) || {
      echo "ERROR: cannot create the speculative native PID handoff" >&2
      exit 1
    }
    exec 3> "$SPECULATIVE_PID_HANDOFF" || {
      rm -f "$SPECULATIVE_PID_HANDOFF"
      echo "ERROR: cannot open the speculative native PID handoff" >&2
      exit 1
    }
    if load_wave_stop_request; then
      exec 3>&-
      rm -f "$SPECULATIVE_PID_HANDOFF"
      terminate_wave "$WAVE_STOP_EXIT_CODE" "$WAVE_STOP_SIGNAL"
    fi
    DEEP_REVIEW_WAVE_NATIVE_PID_FD=3 \
    WAVE_REVIEWER_AUTHORIZATION_WAIT_SECONDS="$WAVE_RECOVERY_WAIT_SECONDS" \
      bash "$PAIR_RUNNER" \
      --context "$CONTEXT_PATH" \
      --claude-prompt "$CLAUDE_SPECULATIVE_PROMPT" \
      --codex-prompt "$CODEX_SPECULATIVE_PROMPT" \
      --phase convergence \
      --round "$SPECULATIVE_ROUND" \
      --reviewer both \
      --attempt 1 \
      --wave-status "$WAVE_STATUS_PATH" \
      --wave-role speculative \
      --wave-supervisor-nonce "$WAVE_SUPERVISOR_NONCE" 3>&3 &
    SPECULATIVE_PID=$!
    exec 3>&-
    pause_after_fork_for_test
    PAIR_HANDOFF_NATIVE_PID=""
    if read_pair_pid_handoff \
      "$SPECULATIVE_PID_HANDOFF" "$SPECULATIVE_PID"; then
      SPECULATIVE_NATIVE_PID="$PAIR_HANDOFF_NATIVE_PID"
      finish_launch_bookkeeping
      break
    fi
    handle_pair_pid_handoff_failure \
      speculative "$SPECULATIVE_PID" "$SPECULATIVE_HANDOFF_ATTEMPT"
    SPECULATIVE_HANDOFF_ATTEMPT=$((SPECULATIVE_HANDOFF_ATTEMPT + 1))
  done
fi
set +m

if [ -n "$LEAD_PID" ]; then
  wait_for_role_claim lead "$LEAD_PID" "$LEAD_NATIVE_PID" ||
    terminate_wave 1 TERM
fi
if [ -n "$SPECULATIVE_PID" ]; then
  wait_for_role_claim \
    speculative "$SPECULATIVE_PID" "$SPECULATIVE_NATIVE_PID" ||
    terminate_wave 1 TERM
fi
if [ -z "$PENDING_SIGNAL_NAME" ]; then
  if [ -n "${DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER:-}" ]; then
    : > "$DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_MARKER"
  fi
  if [ -n "${DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS:-}" ]; then
    sleep "$DEEP_REVIEW_TEST_PRE_REVIEWERS_READY_DELAY_SECONDS"
  fi
  mark_wave_reviewers_ready || {
    if [ -n "$PENDING_SIGNAL_NAME" ]; then
      terminate_wave "$PENDING_SIGNAL_CODE" "$PENDING_SIGNAL_NAME"
    fi
    terminate_wave 1 TERM
  }
fi
finish_role_claims

printf 'WAVE_STATUS_PATH: %s\n' "$WAVE_STATUS_PATH"
printf 'WAVE_LEAD_ROUND: %s\n' "$FIRST_ROUND"
printf 'WAVE_SPECULATIVE_ROUND: %s\n' "$SPECULATIVE_ROUND"

if [ -n "$LEAD_PID" ]; then
  wait "$LEAD_PID" 2>/dev/null
  LEAD_RC=$?
  LEAD_PID=""
  record_result lead "$LEAD_RC" || terminate_wave 1 TERM
else
  recover_attached_role lead || terminate_wave 1 TERM
  LEAD_RC=$RECOVERED_RC
fi
printf 'WAVE_LEAD_READY: round-%s exit=%s\n' "$FIRST_ROUND" "$LEAD_RC"

SPECULATIVE_SIGNAL=""
while true; do
  CONTROL_STATE=$(node "$STATE_TOOL" control-state \
    --context "$CONTEXT_PATH" \
    --status "$WAVE_STATUS_PATH") || terminate_wave 1 TERM
  if [ "$(printf '%s' "$CONTROL_STATE" | jq -r .terminal)" = "true" ]; then
    break
  fi
  if [ "$(printf '%s' "$CONTROL_STATE" | jq -r .pairFinished)" = "true" ]; then
    break
  fi
  if [ -n "$SPECULATIVE_PID" ] && ! kill -0 "$SPECULATIVE_PID" 2>/dev/null; then
    break
  fi
  WAVE_DECISION=$(printf '%s' "$CONTROL_STATE" | jq -r \
    '.decision.action // "pending"')
  case "$WAVE_DECISION" in
    converge|prior-failure)
      if [ -n "$SPECULATIVE_PID" ] &&
        { kill -TERM -- "-$SPECULATIVE_PID" 2>/dev/null ||
          kill -TERM "$SPECULATIVE_PID" 2>/dev/null; }; then
        SPECULATIVE_SIGNAL="TERM"
        node "$STATE_TOOL" record-signal \
          --context "$CONTEXT_PATH" \
          --status "$WAVE_STATUS_PATH" \
          --signal TERM >/dev/null || true
      fi
      break
      ;;
    pending) sleep 1 ;;
    promote)
      if [ -z "$SPECULATIVE_PID" ]; then
        recover_attached_role speculative || terminate_wave 1 TERM
        break
      fi
      sleep 1
      ;;
    *) echo "ERROR: speculative round has an invalid wave decision" >&2
       terminate_wave 1 TERM ;;
  esac
done
if [ -n "$SPECULATIVE_PID" ]; then
  wait "$SPECULATIVE_PID" 2>/dev/null
  SPECULATIVE_RC=$?
  SPECULATIVE_PID=""
  record_result speculative "$SPECULATIVE_RC" "$SPECULATIVE_SIGNAL" ||
    terminate_wave 1 TERM
else
  recover_attached_role speculative || terminate_wave 1 TERM
  SPECULATIVE_RC=$RECOVERED_RC
fi
printf 'WAVE_SPECULATIVE_FINISHED: round-%s exit=%s\n' \
  "$SPECULATIVE_ROUND" "$SPECULATIVE_RC"

if [ "$LEAD_RC" -ne 0 ]; then
  LEAD_ARTIFACT_DIR=$(jq -er .lead.artifactDir "$WAVE_STATUS_PATH") || exit 1
  LEAD_STATUS_PATH="$LEAD_ARTIFACT_DIR/status.json"
  while true; do
    if [ -f "$LEAD_STATUS_PATH" ] && [ ! -L "$LEAD_STATUS_PATH" ] &&
      jq -e '
        .schema == "deep-review-pair/v6" and
        .phase == "convergence" and
        .complete == true and
        .canonical.claude.exitCode == 0 and
        .canonical.codex.exitCode == 0
      ' "$LEAD_STATUS_PATH" >/dev/null; then
      exit 0
    fi
    WAVE_DECISION=$(jq -er '.decision.action // "pending"' \
      "$WAVE_STATUS_PATH") || exit 1
    case "$WAVE_DECISION" in
      pending) sleep 1 ;;
      prior-failure) exit "$LEAD_RC" ;;
      *)
        echo "ERROR: incomplete lead round has an invalid wave decision" >&2
        exit 1
        ;;
    esac
  done
fi
exit 0
