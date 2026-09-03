#!/bin/bash
# run-codex-core.sh - shared Codex CLI invocation and supervision logic
#
# Do not call this script directly from Claude Code. Use one of the fixed-mode
# review entrypoints instead:
#   .claude/skills/deep-review-with-claude-and-codex/scripts/run-codex.sh
#
# Usage:
#   run-codex-core.sh read-only <stdout|file> \
#     <inherit|disable-multi-agent> <project_dir> <prompt_file> [thread_id]
#
# The entrypoints fix the sandbox, result mode, model, reasoning effort, and
# timeout ceiling. This review-only bundle rejects workspace-write even when
# the shared core is called directly.
#
# Exit code 3 is reserved for an outer execution sandbox that prevents the
# read-only external Codex reviewer from starting.

set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "Usage: $0 read-only <stdout|file> <inherit|disable-multi-agent> <project_dir> <prompt_file> [thread_id]" >&2
  exit 1
fi

SANDBOX="$1"
RESULT_MODE="$2"
MULTI_AGENT_POLICY="$3"
PROJECT_DIR="$4"
PROMPT_FILE="$5"
THREAD_ID="${6:-}"

if [ "$SANDBOX" != "read-only" ]; then
  echo "ERROR: unsupported sandbox: $SANDBOX (allowed: read-only)" >&2
  exit 1
fi

case "$RESULT_MODE" in
  stdout|file) ;;
  *)
    echo "ERROR: unsupported result mode: $RESULT_MODE (allowed: stdout, file)" >&2
    exit 1
    ;;
esac

case "$MULTI_AGENT_POLICY" in
  inherit)
    CODEX_DISABLE_MULTI_AGENT=0
    ;;
  disable-multi-agent)
    CODEX_DISABLE_MULTI_AGENT=1
    ;;
  *)
    echo "ERROR: unsupported multi-agent policy: $MULTI_AGENT_POLICY (allowed: inherit, disable-multi-agent)" >&2
    exit 1
    ;;
esac

# Globals referenced by cleanup(). Initialize them before installing traps.
WORK_DIR=""
RUN_DIR=""
RUN_ID=""
STATUS_FILE=""
RESULT_FILE=""
STATUS_FILE_OUT=""
RESULT_FILE_OUT=""
FLAG_FILE=""
CODEX_PID=""
CODEX_WINPID=""
WATCHDOG_PID=""
PROMPT_DELETE=0
tid=""
exit_code=0
STARTED_AT=""
TERMINAL_STATUS=""
STATUS_FINALIZED=0
CLEANUP_DONE=0
CODEX_REVIEW_VERIFIED=0

pgroup_alive() {
  [ -n "${1:-}" ] || return 1
  # Probe the process group directly. Merely finding a pgrep binary is not
  # enough: some sandboxed macOS environments deny process-list access, which
  # would make pgrep report a live group as absent and disarm the watchdog.
  kill -0 -- "-$1" 2>/dev/null
}

kill_codex_tree() {
  # Negative PID targets the process group created by `set -m` below.
  kill "-$1" -- "-$CODEX_PID" 2>/dev/null || true
  case "$OSTYPE" in
    msys*|cygwin*)
      if [ -n "$CODEX_WINPID" ]; then
        taskkill //F //T //PID "$CODEX_WINPID" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

display_path() {
  case "$OSTYPE" in
    msys*|cygwin*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1" 2>/dev/null && return 0
      fi
      ;;
  esac
  printf '%s\n' "$1"
}

codex_cli_path() {
  case "$OSTYPE" in
    msys*|cygwin*)
      if ! command -v cygpath >/dev/null 2>&1; then
        echo "ERROR: cygpath is required to invoke the Windows Codex CLI." >&2
        return 1
      fi
      cygpath -am -- "$1" 2>/dev/null || {
        echo "ERROR: Could not convert path for the Windows Codex CLI: $1" >&2
        return 1
      }
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

write_status() {
  [ "$RESULT_MODE" = "file" ] || return 0
  [ -n "$STATUS_FILE" ] || return 0

  local updated_at
  updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg status "$1" \
    --arg mode "$SANDBOX" \
    --arg model "$CODEX_MODEL" \
    --arg reasoning_effort "$CODEX_REASONING_EFFORT" \
    --arg project_dir "$PROJECT_DIR" \
    --arg status_path "$STATUS_FILE_OUT" \
    --arg result_path "$RESULT_FILE_OUT" \
    --arg thread_id "$tid" \
    --arg started_at "$STARTED_AT" \
    --arg updated_at "$updated_at" \
    --argjson exit_code "${2:-null}" \
    --argjson wrapper_pid "$$" \
    '{run_id:$run_id,status:$status,mode:$mode,model:$model,reasoning_effort:$reasoning_effort,project_dir:$project_dir,status_path:$status_path,result_path:$result_path,thread_id:$thread_id,exit_code:$exit_code,wrapper_pid:$wrapper_pid,started_at:$started_at,updated_at:$updated_at}' \
    > "$STATUS_FILE.tmp" 2>/dev/null && mv "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null
  return 0
}

emit_start_sentinel() {
  [ "$RESULT_MODE" = "file" ] || return 0
  printf 'RUN_ID: %s\nSTATUS_FILE: %s\nRESULT_FILE: %s\nSTATUS: running\n' \
    "$RUN_ID" "$STATUS_FILE_OUT" "$RESULT_FILE_OUT"
}

emit_terminal_sentinel() {
  [ "$RESULT_MODE" = "file" ] || return 0
  printf 'RUN_ID: %s\n' "$RUN_ID"
  if [ -n "$tid" ]; then
    printf 'THREAD_ID: %s\n' "$tid"
  fi
  printf 'STATUS_FILE: %s\nRESULT_FILE: %s\nSTATUS: %s\n' \
    "$STATUS_FILE_OUT" "$RESULT_FILE_OUT" "$1"
}

emit_timeout_sentinel() {
  if [ "$RESULT_MODE" = "file" ]; then
    emit_terminal_sentinel "timed_out"
    return 0
  fi
  if [ -n "$tid" ]; then
    printf 'THREAD_ID: %s\n' "$tid"
  fi
  printf 'STATUS: timed_out\n'
}

resolve_thread_id() {
  if [ -z "$tid" ] && [ -n "${TMPFILE:-}" ] && [ -s "$TMPFILE" ]; then
    # Parse records independently: a killed process may leave its final JSONL
    # line incomplete, but an earlier thread.started record is still valid.
    tid=$(jq -Rr 'fromjson? | select(.type == "thread.started") | .thread_id // empty' \
      "$TMPFILE" 2>/dev/null | head -1 || true)
  fi
  if [ -z "$tid" ] && [ -n "$THREAD_ID" ]; then
    tid="$THREAD_ID"
  fi
}

cleanup() {
  trap '' INT TERM
  trap - EXIT
  [ "$CLEANUP_DONE" = "1" ] && return 0
  CLEANUP_DONE=1
  set +e

  if [ -n "$WATCHDOG_PID" ] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    kill -TERM -- "-$WATCHDOG_PID" 2>/dev/null
    wait "$WATCHDOG_PID" 2>/dev/null
  fi

  if [ -n "$CODEX_PID" ] && pgroup_alive "$CODEX_PID"; then
    kill_codex_tree TERM
    sleep 2
    pgroup_alive "$CODEX_PID" && kill_codex_tree KILL
  fi

  if [ "$STATUS_FINALIZED" != "1" ] && [ -n "$TERMINAL_STATUS" ]; then
    write_status "$TERMINAL_STATUS" "${SIGNAL_EXIT_CODE:-null}"
    STATUS_FINALIZED=1
  fi

  if [ "$PROMPT_DELETE" = "1" ] && [ -n "$PROMPT_FILE" ]; then
    rm -f "$PROMPT_FILE" 2>/dev/null
  fi
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR" 2>/dev/null

  return 0
}

on_signal() {
  SIGNAL_EXIT_CODE="$1"
  TERMINAL_STATUS="interrupted"
  cleanup
  emit_terminal_sentinel "interrupted"
  exit "$1"
}

trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

is_temporary_prompt() {
  local prompt_parent root root_real
  prompt_parent=$(cd "$(dirname "$PROMPT_FILE")" 2>/dev/null && pwd -P) || return 1

  # Callers in these skills use /tmp prompt files. Do not trust an arbitrary
  # TMPDIR value for deletion, because it could point at a normal directory.
  for root in /tmp /c/tmp; do
    [ -n "$root" ] || continue
    [ -d "$root" ] || continue
    root_real=$(cd "$root" 2>/dev/null && pwd -P) || continue
    case "$prompt_parent/" in
      "$root_real/"*) return 0 ;;
    esac
  done
  return 1
}

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi
if is_temporary_prompt; then
  PROMPT_DELETE=1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: project dir not found: $PROJECT_DIR" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&2
  exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex CLI is required but not installed. Run: npm install -g @openai/codex" >&2
  exit 1
fi

CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-}"
CODEX_TIMEOUT_MAX="${CODEX_TIMEOUT_MAX:-540}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-540}"
CODEX_KILL_GRACE="${CODEX_KILL_GRACE:-30}"
REVIEW_CONTROL_FILE="${CODEX_REVIEW_CONTROL_FILE:-}"
REVIEW_OUTPUT_VERIFIER="${CODEX_REVIEW_OUTPUT_VERIFIER:-}"
# The control contains the receipt and expected random-probe hash. Keep it out
# of the child Codex environment so the reviewer must read the fixed diff.
unset CODEX_REVIEW_CONTROL_FILE CODEX_REVIEW_OUTPUT_VERIFIER

if [ -z "$CODEX_MODEL" ]; then
  echo "ERROR: CODEX_MODEL must be set by the entrypoint." >&2
  exit 2
fi
if [ -z "$CODEX_REASONING_EFFORT" ]; then
  echo "ERROR: CODEX_REASONING_EFFORT must be set by the entrypoint." >&2
  exit 2
fi

case "$CODEX_TIMEOUT_MAX" in
  ''|*[!0-9]*)
    echo "ERROR: invalid CODEX_TIMEOUT_MAX: '$CODEX_TIMEOUT_MAX'" >&2
    exit 2
    ;;
esac
case "$CODEX_TIMEOUT" in
  ''|*[!0-9]*)
    echo "ERROR: invalid CODEX_TIMEOUT: '$CODEX_TIMEOUT' (must be a positive integer)" >&2
    exit 2
    ;;
esac
if [ "$CODEX_TIMEOUT" -lt 1 ] || [ "$CODEX_TIMEOUT" -gt "$CODEX_TIMEOUT_MAX" ]; then
  echo "ERROR: CODEX_TIMEOUT=$CODEX_TIMEOUT out of range (1..$CODEX_TIMEOUT_MAX for this entrypoint)" >&2
  exit 2
fi

case "$CODEX_KILL_GRACE" in
  ''|*[!0-9]*)
    echo "ERROR: invalid CODEX_KILL_GRACE: '$CODEX_KILL_GRACE'" >&2
    exit 2
    ;;
esac
if [ "$CODEX_KILL_GRACE" -lt 1 ] || [ "$CODEX_KILL_GRACE" -gt 60 ]; then
  echo "ERROR: CODEX_KILL_GRACE=$CODEX_KILL_GRACE out of range (1..60)" >&2
  exit 2
fi

if [ -n "$REVIEW_CONTROL_FILE" ] || [ -n "$REVIEW_OUTPUT_VERIFIER" ]; then
  if [ -z "$REVIEW_CONTROL_FILE" ] || [ -z "$REVIEW_OUTPUT_VERIFIER" ]; then
    echo "ERROR: Codex review control and output verifier must be set together." >&2
    exit 2
  fi
  if [ "$SANDBOX" != "read-only" ] || [ "$RESULT_MODE" != "stdout" ]; then
    echo "ERROR: Codex review attestation is only valid for read-only stdout mode." >&2
    exit 2
  fi
  if [ ! -f "$REVIEW_CONTROL_FILE" ] || [ -L "$REVIEW_CONTROL_FILE" ]; then
    echo "ERROR: Codex review control must be a regular non-symlink file." >&2
    exit 2
  fi
  if [ ! -f "$REVIEW_OUTPUT_VERIFIER" ] || [ -L "$REVIEW_OUTPUT_VERIFIER" ]; then
    echo "ERROR: Codex review output verifier must be a regular non-symlink file." >&2
    exit 2
  fi
fi

PROMPT=$(cat "$PROMPT_FILE")
if [ -z "$PROMPT" ]; then
  echo "ERROR: prompt file is empty: $PROMPT_FILE" >&2
  exit 1
fi

resolve_codex_cmd() {
  if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    local cmd_path codex_js
    # Two backslashes are the intended tr input.
    # shellcheck disable=SC1003
    cmd_path=$(mise which codex 2>/dev/null | tr '\\' '/') || {
      echo "ERROR: Could not resolve codex path via mise." >&2
      exit 1
    }
    codex_js="$(dirname "$cmd_path")/node_modules/@openai/codex/bin/codex.js"
    if [ ! -f "$codex_js" ]; then
      echo "ERROR: codex.js not found at $codex_js" >&2
      exit 1
    fi
    CODEX_CMD=(mise exec -- node "$codex_js")
  else
    CODEX_CMD=(codex)
  fi
}
resolve_codex_cmd

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TMP_BASE="${TMPDIR:-/tmp}"
ARTIFACT_ROOT="$TMP_BASE/deep-review-codex-runs"
mkdir -p "$ARTIFACT_ROOT"
chmod 700 "$ARTIFACT_ROOT" 2>/dev/null || true
# Only prune this runner's private artifact namespace.
find "$ARTIFACT_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

WORK_DIR=$(mktemp -d "$TMP_BASE/deep-review-codex-work.XXXXXX")
chmod 700 "$WORK_DIR"
TMPFILE="$WORK_DIR/jsonl"
ERRFILE="$WORK_DIR/err"
MSGFILE="$WORK_DIR/msg"
BODYFILE="$WORK_DIR/body"
FLAG_FILE="$WORK_DIR/timeout-flag"

if [ "$RESULT_MODE" = "file" ]; then
  RUN_DIR=$(mktemp -d "$ARTIFACT_ROOT/run.XXXXXX")
  chmod 700 "$RUN_DIR"
  RUN_ID="$(basename "$RUN_DIR")"
  STATUS_FILE="$RUN_DIR/status.json"
  RESULT_FILE="$RUN_DIR/result.txt"
  STATUS_FILE_OUT=$(display_path "$STATUS_FILE")
  RESULT_FILE_OUT=$(display_path "$RESULT_FILE")
fi

TERMINAL_STATUS="failed"
write_status "created"

finalize_failed() {
  local code="$1"
  write_status "failed" "$code"
  STATUS_FINALIZED=1
  emit_terminal_sentinel "failed"
}

outer_sandbox_blocked_review_startup() {
  [ "$SANDBOX" = "read-only" ] || return 1
  [ "$RESULT_MODE" = "stdout" ] || return 1
  [ "$CODEX_DISABLE_MULTI_AGENT" = "1" ] || return 1
  [ "$exit_code" -ne 0 ] || return 1
  [ -s "$ERRFILE" ] || return 1

  # The known outer-sandbox failure happens before Codex emits any JSONL.
  # Once it emits even a failed turn, normal reviewer failure handling owns it.
  [ ! -s "$TMPFILE" ] || return 1

  if grep -qF '.codex/state_' "$ERRFILE" &&
    grep -qF 'attempt to write a readonly database' "$ERRFILE"; then
    return 0
  fi
  grep -qF 'failed to initialize in-process app-server client' "$ERRFILE" &&
    grep -qF 'Operation not permitted' "$ERRFILE"
}

fail_outer_sandbox_review_startup() {
  {
    echo "ERROR: outer Codex sandbox blocked external Codex startup."
    echo "This is an execution infrastructure failure, not reviewer evidence and not missing user consent."
    echo "Re-run the same fixed review input through the managed runner outside the sandbox."
    echo "If the execution layer still refuses it, report that infrastructure refusal without reinterpreting it as a review result."
    cat "$ERRFILE"
  } >&2
  finalize_failed 3
  exit 3
}

CODEX_EXEC_ARGS=(exec --json --sandbox "$SANDBOX" --model "$CODEX_MODEL" -c "model_reasoning_effort=$CODEX_REASONING_EFFORT")
CODEX_CWD="$PROJECT_DIR"
if [ "$CODEX_DISABLE_MULTI_AGENT" = "1" ]; then
  # Codex 0.144 exposes both the legacy and v2 collaboration engines as
  # independent feature flags. Disable both so a leaf review cannot fan out
  # through whichever engine is active in the installed CLI.
  # Project AGENTS.md files belong to the checkout being reviewed and are
  # therefore untrusted review data. The orchestrator embeds the BASE_SHA
  # review criteria in the prompt instead of letting the CLI auto-load them.
  CODEX_EXEC_ARGS+=(
    --skip-git-repo-check
    -c "features.multi_agent=false"
    -c "features.multi_agent_v2=false"
    -c "project_doc_max_bytes=0"
  )
  # Run from a private non-repository directory so project .codex config,
  # hooks, rules, and skills from the reviewed checkout are not discovered.
  # Review inputs are passed as absolute paths in the orchestrator prompt.
  CODEX_CWD="$WORK_DIR/reviewer-cwd"
  mkdir -p "$CODEX_CWD"
  chmod 700 "$CODEX_CWD"
fi
CODEX_CWD_ARG=$(codex_cli_path "$CODEX_CWD")
MSGFILE_ARG=$(codex_cli_path "$MSGFILE")
CODEX_EXEC_ARGS+=(--cd "$CODEX_CWD_ARG" -o "$MSGFILE_ARG")
if [ -n "$THREAD_ID" ]; then
  CODEX_EXEC_ARGS+=(resume "$THREAD_ID" "$PROMPT")
else
  CODEX_EXEC_ARGS+=("$PROMPT")
fi

set -m
"${CODEX_CMD[@]}" "${CODEX_EXEC_ARGS[@]}" \
  </dev/null >"$TMPFILE" 2>"$ERRFILE" &
CODEX_PID=$!
set +m

case "$OSTYPE" in
  msys*|cygwin*)
    CODEX_WINPID=$(cat "/proc/$CODEX_PID/winpid" 2>/dev/null) || CODEX_WINPID=""
    ;;
esac

write_status "codex_running"
emit_start_sentinel

set -m
(
  set +e
  remaining="$CODEX_TIMEOUT"
  while [ "$remaining" -gt 0 ]; do
    interval=5
    if [ "$remaining" -lt "$interval" ]; then
      interval="$remaining"
    fi
    sleep "$interval"
    remaining=$((remaining - interval))
    pgroup_alive "$CODEX_PID" || exit 0
  done
  touch "$FLAG_FILE" 2>/dev/null || true
  pgroup_alive "$CODEX_PID" && kill_codex_tree TERM
  sleep "$CODEX_KILL_GRACE"
  pgroup_alive "$CODEX_PID" && kill_codex_tree KILL
  exit 0
) &
WATCHDOG_PID=$!
set +m

if wait "$CODEX_PID"; then
  exit_code=0
else
  exit_code=$?
fi

resolve_thread_id

if [ -f "$FLAG_FILE" ]; then
  wait "$WATCHDOG_PID" 2>/dev/null || true
else
  if kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    kill -TERM -- "-$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
fi

if [ -f "$FLAG_FILE" ]; then
  write_status "timed_out" "$exit_code"
  STATUS_FINALIZED=1
  echo "ERROR: Codex execution exceeded ${CODEX_TIMEOUT}s and was terminated by the watchdog." >&2
  echo "Hint: override with CODEX_TIMEOUT=<seconds> (max ${CODEX_TIMEOUT_MAX} for this entrypoint)." >&2
  [ -s "$ERRFILE" ] && cat "$ERRFILE" >&2
  emit_timeout_sentinel
  exit 124
fi

if outer_sandbox_blocked_review_startup; then
  fail_outer_sandbox_review_startup
fi

if [ ! -s "$TMPFILE" ]; then
  echo "ERROR: Codex produced no output." >&2
  [ -s "$ERRFILE" ] && cat "$ERRFILE" >&2
  failure_code="$exit_code"
  [ "$failure_code" -ne 0 ] || failure_code=1
  finalize_failed "$failure_code"
  exit 1
fi

if ! jq -c . "$TMPFILE" >/dev/null 2>&1; then
  echo "ERROR: Codex produced malformed JSONL output." >&2
  [ -s "$ERRFILE" ] && cat "$ERRFILE" >&2
  failure_code="$exit_code"
  [ "$failure_code" -ne 0 ] || failure_code=1
  finalize_failed "$failure_code"
  exit 1
fi

write_status "postprocessing"
fatal_msg=$(jq -r 'select(.type=="turn.failed") | .error.message // "unknown error"' "$TMPFILE" 2>/dev/null | tail -1 || true)

if [ -n "$fatal_msg" ] || [ "$exit_code" -ne 0 ]; then
  [ -n "$fatal_msg" ] && echo "ERROR: $fatal_msg" >&2
  if [ "$exit_code" -ne 0 ] && [ -z "$fatal_msg" ]; then
    echo "ERROR: Codex exited with status $exit_code." >&2
  fi
  [ -s "$ERRFILE" ] && cat "$ERRFILE" >&2
  failure_code="$exit_code"
  [ "$failure_code" -ne 0 ] || failure_code=1
  finalize_failed "$failure_code"
  exit 1
fi

resolve_thread_id
if [ -z "$tid" ]; then
  echo "ERROR: THREAD_ID was not emitted." >&2
  finalize_failed 1
  exit 1
fi

if [ -s "$MSGFILE" ]; then
  cat "$MSGFILE" > "$BODYFILE"
else
  jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text // empty' "$TMPFILE" 2>/dev/null > "$BODYFILE" || true
fi
if [ ! -s "$BODYFILE" ]; then
  echo "ERROR: Codex emitted no final agent message." >&2
  finalize_failed 1
  exit 1
fi

if [ -n "$REVIEW_CONTROL_FILE" ]; then
  VERIFIED_BODYFILE="$WORK_DIR/body.verified"
  if ! node "$REVIEW_OUTPUT_VERIFIER" \
    --control "$REVIEW_CONTROL_FILE" \
    --prompt "$PROMPT_FILE" \
    --input "$BODYFILE" \
    --output "$VERIFIED_BODYFILE"; then
    echo "ERROR: Codex review output failed input attestation or result-contract verification." >&2
    if [ "$RESULT_MODE" = "stdout" ]; then
      if [ -n "$tid" ]; then
        printf 'THREAD_ID: %s\n' "$tid"
      fi
      printf 'STATUS: output_contract_failed\n'
    fi
    finalize_failed 1
    exit 1
  fi
  BODYFILE="$VERIFIED_BODYFILE"
  CODEX_REVIEW_VERIFIED=1
fi

if [ "$RESULT_MODE" = "file" ]; then
  {
    printf 'THREAD_ID: %s\n---\n' "$tid"
    cat "$BODYFILE"
  } > "$RESULT_FILE.tmp"
  mv "$RESULT_FILE.tmp" "$RESULT_FILE"
  write_status "result_ready" 0
  STATUS_FINALIZED=1
  emit_terminal_sentinel "result_ready"
else
  printf 'THREAD_ID: %s\n' "$tid"
  if [ "$CODEX_REVIEW_VERIFIED" != "1" ]; then
    printf '%s\n' "---"
  fi
  cat "$BODYFILE"
fi

TERMINAL_STATUS=""
