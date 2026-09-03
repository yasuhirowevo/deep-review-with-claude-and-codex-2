#!/usr/bin/env bash

set -euo pipefail

REVIEW_STARTED_AT_MS=$(node -e 'process.stdout.write(String(Date.now()))')
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_INPUT=""
HOST=""
PR_INPUT=""
BRANCH_INPUT=""
BASE_INPUT=""
CONTEXT_PATH=""
SKILL_DIR=""
PREFLIGHT_SUCCEEDED=0

usage() {
  cat >&2 <<'USAGE'
Usage:
  run-review-preflight.sh --project <repo> --host <claude|codex> --pr <number-or-url>
  run-review-preflight.sh --project <repo> --host <claude|codex> --branch <ref> [--base <ref>]
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT_INPUT="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --pr) PR_INPUT="${2:-}"; shift 2 ;;
    --branch) BRANCH_INPUT="${2:-}"; shift 2 ;;
    --base) BASE_INPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$PROJECT_INPUT" ] || [ -z "$HOST" ] \
  || { [ -z "$PR_INPUT" ] && [ -z "$BRANCH_INPUT" ]; } \
  || { [ -n "$PR_INPUT" ] && [ -n "$BRANCH_INPUT" ]; }; then
  usage
  exit 2
fi
if [ -n "$PR_INPUT" ] && [ -n "$BASE_INPUT" ]; then
  echo "ERROR: --base is only valid with --branch" >&2
  exit 2
fi
case "$HOST" in
  claude|codex) ;;
  *) echo "ERROR: --host must be claude or codex" >&2; exit 2 ;;
esac

for command_name in git jq node; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: required command is unavailable: $command_name" >&2
    exit 1
  }
done
if [ -n "$PR_INPUT" ]; then
  command -v gh >/dev/null 2>&1 || {
    echo "ERROR: required command is unavailable: gh" >&2
    exit 1
  }
fi

cleanup_on_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ] && [ "$PREFLIGHT_SUCCEEDED" = "1" ]; then
    return 0
  fi
  set +e
  if [ -n "$CONTEXT_PATH" ] && [ -n "$SKILL_DIR" ] \
    && [ -f "$CONTEXT_PATH" ]; then
    if ! bash "$SKILL_DIR/scripts/cleanup-review-run.sh" "$CONTEXT_PATH"; then
      echo "WARN: failed to clean an incomplete review preflight" >&2
    fi
  fi
  return "$rc"
}
trap cleanup_on_exit EXIT
trap 'trap - INT TERM HUP; exit 130' INT
trap 'trap - INT TERM HUP; exit 143' TERM HUP

PREPARE_ARGS=(
  --project "$PROJECT_INPUT"
  --started-at-ms "$REVIEW_STARTED_AT_MS"
)
if [ -n "$PR_INPUT" ]; then
  PREPARE_ARGS+=(--pr "$PR_INPUT")
else
  PREPARE_ARGS+=(--branch "$BRANCH_INPUT")
  if [ -n "$BASE_INPUT" ]; then
    PREPARE_ARGS+=(--base "$BASE_INPUT")
  fi
fi

RUN_CONTEXT_JSON=$(bash "$SCRIPT_DIR/prepare-review-run.sh" "${PREPARE_ARGS[@]}")
CONTEXT_PATH=$(printf '%s' "$RUN_CONTEXT_JSON" | jq -er \
  '.reviewArtifactDir + "/context.json"')
SKILL_DIR=$(jq -er .skillDir "$CONTEXT_PATH")
REVIEW_ARTIFACT_DIR=$(jq -er .reviewArtifactDir "$CONTEXT_PATH")
REVIEW_RUN_ID=$(jq -er .reviewRunId "$CONTEXT_PATH")
CONTEXT_STARTED_AT_MS=$(jq -er .reviewStartedAtMs "$CONTEXT_PATH")
if [ "$CONTEXT_STARTED_AT_MS" != "$REVIEW_STARTED_AT_MS" ]; then
  echo "ERROR: prepared context did not retain the preflight start time" >&2
  exit 1
fi
INPUTS_PREPARED_AT_MS=$(node -e 'process.stdout.write(String(Date.now()))')

if [ -n "$PR_INPUT" ]; then
  PR_REVIEW_CONTEXT_PATH=$(jq -er .prReviewContextPath "$CONTEXT_PATH")
  PR_REPOSITORY_HOST=$(jq -er .repositoryHost "$CONTEXT_PATH")
  PR_REPOSITORY=$(jq -er .repository "$CONTEXT_PATH")
  PR_NUMBER=$(jq -er .prNumber "$CONTEXT_PATH")
  HEAD_SHA=$(jq -er .headSha "$CONTEXT_PATH")
  PR_CONTEXT_JSON=$(node "$SKILL_DIR/scripts/fetch-pr-review-context.mjs" \
    --repo-host "$PR_REPOSITORY_HOST" \
    --repo "$PR_REPOSITORY" \
    --pr "$PR_NUMBER" \
    --expected-head-sha "$HEAD_SHA" \
    --review-run-id "$REVIEW_RUN_ID" \
    --snapshot-role initial \
    --output "$PR_REVIEW_CONTEXT_PATH")
  PR_CONTEXT_STATUS=$(printf '%s' "$PR_CONTEXT_JSON" | jq -er \
    '.status | select(. == "checked" or . == "not-checked")')
  PR_CONTEXT_REASONS=$(printf '%s' "$PR_CONTEXT_JSON" | jq -c '.reasons // []')
else
  PR_REVIEW_CONTEXT_PATH=""
  PR_CONTEXT_STATUS="skipped"
  PR_CONTEXT_REASONS='[]'
fi
PR_CONTEXT_COMPLETED_AT_MS=$(node -e 'process.stdout.write(String(Date.now()))')

bash "$SKILL_DIR/scripts/verify-review-run.sh" "$CONTEXT_PATH" >/dev/null
PREFLIGHT_COMPLETED_AT_MS=$(node -e 'process.stdout.write(String(Date.now()))')

PREFLIGHT_PATH="$REVIEW_ARTIFACT_DIR/preflight.json"
if [ -e "$PREFLIGHT_PATH" ] || [ -L "$PREFLIGHT_PATH" ]; then
  echo "ERROR: preflight artifact already exists" >&2
  exit 1
fi

REVIEW_MODE=$(jq -er .reviewMode "$CONTEXT_PATH")
TARGET=$(jq -er .target "$CONTEXT_PATH")
BASE_SHA=$(jq -er .baseSha "$CONTEXT_PATH")
HEAD_SHA=$(jq -er .headSha "$CONTEXT_PATH")
MERGE_BASE_SHA=$(jq -er .mergeBaseSha "$CONTEXT_PATH")
TOOLING_DIGEST=$(jq -er .toolingDigest "$CONTEXT_PATH")
DIFF_SHA256=$(jq -er .diffSha256 "$CONTEXT_PATH")
SNAPSHOT_METADATA_SHA256=$(jq -er .snapshotMetadataSha256 "$CONTEXT_PATH")
BASE_GUIDANCE_SHA256=$(jq -er .baseGuidanceSha256 "$CONTEXT_PATH")

PREFLIGHT_JSON=$(jq -n \
  --arg schema "deep-review-preflight/v1" \
  --arg status "passed" \
  --arg host "$HOST" \
  --arg contextPath "$CONTEXT_PATH" \
  --arg preflightPath "$PREFLIGHT_PATH" \
  --arg skillDir "$SKILL_DIR" \
  --arg reviewRunId "$REVIEW_RUN_ID" \
  --arg reviewMode "$REVIEW_MODE" \
  --arg target "$TARGET" \
  --arg baseSha "$BASE_SHA" \
  --arg headSha "$HEAD_SHA" \
  --arg mergeBaseSha "$MERGE_BASE_SHA" \
  --arg toolingDigest "$TOOLING_DIGEST" \
  --arg diffSha256 "$DIFF_SHA256" \
  --arg snapshotMetadataSha256 "$SNAPSHOT_METADATA_SHA256" \
  --arg baseGuidanceSha256 "$BASE_GUIDANCE_SHA256" \
  --arg prReviewContextPath "$PR_REVIEW_CONTEXT_PATH" \
  --arg prReviewContextStatus "$PR_CONTEXT_STATUS" \
  --argjson prReviewContextReasons "$PR_CONTEXT_REASONS" \
  --argjson reviewStartedAtMs "$REVIEW_STARTED_AT_MS" \
  --argjson inputsPreparedAtMs "$INPUTS_PREPARED_AT_MS" \
  --argjson prContextCompletedAtMs "$PR_CONTEXT_COMPLETED_AT_MS" \
  --argjson preflightCompletedAtMs "$PREFLIGHT_COMPLETED_AT_MS" \
  '{
    schema:$schema,
    status:$status,
    host:$host,
    contextPath:$contextPath,
    preflightPath:$preflightPath,
    skillDir:$skillDir,
    reviewRunId:$reviewRunId,
    target:{
      mode:$reviewMode,
      id:$target,
      baseSha:$baseSha,
      headSha:$headSha,
      mergeBaseSha:$mergeBaseSha
    },
    inputs:{
      toolingDigest:$toolingDigest,
      diffSha256:$diffSha256,
      snapshotMetadataSha256:$snapshotMetadataSha256,
      baseGuidanceSha256:$baseGuidanceSha256
    },
    prReviewContext:{
      status:$prReviewContextStatus,
      path:(if $prReviewContextPath == "" then null else $prReviewContextPath end),
      reasons:$prReviewContextReasons
    },
    timing:{
      reviewStartedAtMs:$reviewStartedAtMs,
      inputsPreparedAtMs:$inputsPreparedAtMs,
      prContextCompletedAtMs:$prContextCompletedAtMs,
      preflightCompletedAtMs:$preflightCompletedAtMs,
      inputPreparationMs:($inputsPreparedAtMs - $reviewStartedAtMs),
      prContextMs:($prContextCompletedAtMs - $inputsPreparedAtMs),
      verificationMs:($preflightCompletedAtMs - $prContextCompletedAtMs),
      totalMs:($preflightCompletedAtMs - $reviewStartedAtMs)
    },
    nextAction:"build-threat-model-and-start-primary-reviewers"
  }')

(
  set -C
  umask 077
  printf '%s\n' "$PREFLIGHT_JSON" > "$PREFLIGHT_PATH"
)
chmod 400 "$PREFLIGHT_PATH" 2>/dev/null || true

PREFLIGHT_SUCCEEDED=1
printf '%s\n' "$PREFLIGHT_JSON"
