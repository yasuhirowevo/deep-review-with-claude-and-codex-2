#!/usr/bin/env bash

set -euo pipefail

REVIEW_STARTED_AT_MS=$(node -e 'process.stdout.write(String(Date.now()))')
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
CODEX_LAUNCHER_PATH="$SCRIPT_DIR/launch-run-codex.sh"
REVIEWER_LAUNCHER_PATH="$SCRIPT_DIR/launch-run-reviewer.sh"
PROJECT_INPUT=""
PR_INPUT=""
BRANCH_INPUT=""
BASE_INPUT=""
RUN_CONTEXT=""
REVIEW_RUN_ROOT=""
REVIEW_TEMP_ROOT=""
REVIEW_ARTIFACT_DIR=""
REVIEW_SNAPSHOT_DIR=""
PR_REPOSITORY=""
PR_REPOSITORY_HOST=""
PR_REVIEW_CONTEXT_PATH=""
PREPARED=0

usage() {
  cat >&2 <<'USAGE'
Usage:
  prepare-review-run.sh --project <repo> --pr <number-or-url> [--started-at-ms <epoch-ms>]
  prepare-review-run.sh --project <repo> --branch <ref> [--base <ref>] [--started-at-ms <epoch-ms>]
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT_INPUT="${2:-}"; shift 2 ;;
    --pr) PR_INPUT="${2:-}"; shift 2 ;;
    --branch) BRANCH_INPUT="${2:-}"; shift 2 ;;
    --base) BASE_INPUT="${2:-}"; shift 2 ;;
    --started-at-ms) REVIEW_STARTED_AT_MS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$PROJECT_INPUT" ] || { [ -z "$PR_INPUT" ] && [ -z "$BRANCH_INPUT" ]; } \
  || { [ -n "$PR_INPUT" ] && [ -n "$BRANCH_INPUT" ]; }; then
  usage
  exit 2
fi

node -e '
const value = Number(process.argv[1]);
if (!Number.isSafeInteger(value) || value <= 0 || value > Date.now()) {
  process.stderr.write("ERROR: --started-at-ms must be a positive epoch millisecond not in the future\n");
  process.exit(2);
}
' "$REVIEW_STARTED_AT_MS"

REVIEWER_CONFIG_RESOLVED=$(bash "$SCRIPT_DIR/resolve-reviewer-config.sh")
IFS=$'\t' read -r \
  CLAUDE_REVIEW_MODEL_FIXED CLAUDE_REVIEW_EFFORT_FIXED \
  CODEX_REVIEW_MODEL_FIXED CODEX_REVIEW_REASONING_EFFORT_FIXED \
  CLAUDE_REVIEW_MODEL_SOURCE CLAUDE_REVIEW_EFFORT_SOURCE \
  CODEX_REVIEW_MODEL_SOURCE CODEX_REVIEW_REASONING_EFFORT_SOURCE <<< "$(
    printf '%s' "$REVIEWER_CONFIG_RESOLVED" | jq -r '[
      .reviewerConfig.claude.model,
      .reviewerConfig.claude.effort,
      .reviewerConfig.codex.model,
      .reviewerConfig.codex.reasoningEffort,
      .reviewerConfigSources.claude.model,
      .reviewerConfigSources.claude.effort,
      .reviewerConfigSources.codex.model,
      .reviewerConfigSources.codex.reasoningEffort
    ] | @tsv'
  )"
printf '%s\n' \
  "INFO: reviewer config: Claude=$CLAUDE_REVIEW_MODEL_FIXED/$CLAUDE_REVIEW_EFFORT_FIXED ($CLAUDE_REVIEW_MODEL_SOURCE/$CLAUDE_REVIEW_EFFORT_SOURCE), Codex=$CODEX_REVIEW_MODEL_FIXED/$CODEX_REVIEW_REASONING_EFFORT_FIXED ($CODEX_REVIEW_MODEL_SOURCE/$CODEX_REVIEW_REASONING_EFFORT_SOURCE)" \
  >&2

PROJECT_ROOT=$(git -C "$PROJECT_INPUT" rev-parse --show-toplevel)
PROJECT_ROOT=$(cd "$PROJECT_ROOT" && pwd -P)

cleanup_on_error() {
  local rc=$?
  if [ "$rc" -eq 0 ] || [ "$PREPARED" = "1" ]; then
    return "$rc"
  fi
  set +e
  if [ -n "$REVIEW_SNAPSHOT_DIR" ] && [ -n "$REVIEW_TEMP_ROOT" ]; then
    bash "$SCRIPT_DIR/cleanup-review-snapshot.sh" \
      --temp-root "$REVIEW_TEMP_ROOT" "$REVIEW_SNAPSHOT_DIR" >/dev/null 2>&1
  fi
  if [ -n "$REVIEW_RUN_ROOT" ] && [ -n "$REVIEW_TEMP_ROOT" ]; then
    case "$REVIEW_RUN_ROOT" in
      "$REVIEW_TEMP_ROOT"/deep-review.*) rm -rf -- "$REVIEW_RUN_ROOT" ;;
    esac
  fi
  if [ -n "$REVIEW_ARTIFACT_DIR" ]; then
    rmdir "$REVIEW_ARTIFACT_DIR/phase4/waves" \
      "$REVIEW_ARTIFACT_DIR/phase5" "$REVIEW_ARTIFACT_DIR/phase4" \
      "$REVIEW_ARTIFACT_DIR" 2>/dev/null
  fi
  return "$rc"
}
trap cleanup_on_error EXIT INT TERM HUP

if [ -n "$PR_INPUT" ]; then
  PR_SNAPSHOT=$(
    cd "$PROJECT_ROOT"
    gh pr view "$PR_INPUT" --json number,baseRefOid,headRefOid,url \
      --jq '[.number,.baseRefOid,.headRefOid,.url] | @tsv'
  )
  IFS=$'\t' read -r PR_NUMBER BASE_SHA HEAD_SHA PR_URL <<< "$PR_SNAPSHOT"
  case "$PR_NUMBER" in ""|*[!0-9]*) echo "ERROR: invalid PR number" >&2; exit 1 ;; esac
  if [[ "$PR_URL" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/$PR_NUMBER$ ]]; then
    PR_REPOSITORY_HOST="${BASH_REMATCH[1]}"
    PR_REPOSITORY="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
  else
    echo "ERROR: canonical PR repository could not be resolved from gh pr view" >&2
    exit 1
  fi
  TARGET_SLUG="$PR_NUMBER"
  TARGET_ID="pr:$PR_NUMBER"
  REVIEW_MODE="pr"
  BASE_REF=""
  HEAD_REF=""
else
  HEAD_SHA=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$PROJECT_ROOT" \
    rev-parse --verify "${BRANCH_INPUT}^{commit}")
  if [ -n "$BASE_INPUT" ]; then
    BASE_REF="$BASE_INPUT"
  else
    BASE_REF=""
    REMOTE_HEAD_REF=$(
      git -C "$PROJECT_ROOT" symbolic-ref --quiet --short \
        refs/remotes/origin/HEAD 2>/dev/null || true
    )
    for CANDIDATE in "$REMOTE_HEAD_REF" origin/main origin/master main master; do
      [ -n "$CANDIDATE" ] || continue
      if GIT_NO_REPLACE_OBJECTS=1 git -C "$PROJECT_ROOT" \
        rev-parse --verify "${CANDIDATE}^{commit}" >/dev/null 2>&1; then
        BASE_REF="$CANDIDATE"
        break
      fi
    done
    if [ -z "$BASE_REF" ]; then
      echo "ERROR: default base refを解決できません。--base <ref>を指定してください" >&2
      exit 1
    fi
  fi
  BASE_SHA=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$PROJECT_ROOT" \
    rev-parse --verify "${BASE_REF}^{commit}")
  # shellcheck disable=SC2016 # The Node source is intentionally literal.
  TARGET_SLUG=$(node -e '
    const { createHash } = require("node:crypto");
    const ref = process.argv[1];
    const readable = ref
      .replace(/[^A-Za-z0-9._-]+/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 140) || "ref";
    const digest = createHash("sha256").update(ref).digest("hex").slice(0, 12);
    process.stdout.write(`branch-${readable}-${digest}`);
  ' "$BRANCH_INPUT")
  TARGET_ID="branch:$BRANCH_INPUT"
  REVIEW_MODE="branch"
  PR_NUMBER=""
  HEAD_REF="$BRANCH_INPUT"
fi

for sha in "$BASE_SHA" "$HEAD_SHA"; do
  if ! GIT_NO_REPLACE_OBJECTS=1 git -C "$PROJECT_ROOT" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    git -C "$PROJECT_ROOT" fetch --no-tags origin "$sha"
  fi
  GIT_NO_REPLACE_OBJECTS=1 git -C "$PROJECT_ROOT" cat-file -e "${sha}^{commit}"
done
MERGE_BASE_SHA=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$PROJECT_ROOT" \
  merge-base "$BASE_SHA" "$HEAD_SHA")

RUN_CONTEXT=$(bash "$SCRIPT_DIR/init-review-run.sh" \
  --tooling-root "$PROJECT_ROOT" --target "$TARGET_SLUG")
REVIEW_RUN_ID=$(printf '%s' "$RUN_CONTEXT" | jq -r .reviewRunId)
REVIEW_TEMP_ROOT=$(printf '%s' "$RUN_CONTEXT" | jq -r .reviewTempRoot)
REVIEW_RUN_ROOT=$(printf '%s' "$RUN_CONTEXT" | jq -r .reviewRunRoot)
REVIEW_ARTIFACT_DIR=$(printf '%s' "$RUN_CONTEXT" | jq -r .reviewArtifactDir)
if [ "$REVIEW_MODE" = "pr" ]; then
  PR_REVIEW_CONTEXT_PATH="$REVIEW_ARTIFACT_DIR/pr-review-context.json"
fi

TOOLING_CONTEXT=$(node "$SCRIPT_DIR/snapshot-tooling.mjs" \
  --source "$SKILL_DIR" --destination "$REVIEW_RUN_ROOT/tooling")
TOOLING_ROOT=$(printf '%s' "$TOOLING_CONTEXT" | jq -r .toolingRoot)
TOOLING_DIGEST=$(printf '%s' "$TOOLING_CONTEXT" | jq -r .toolingDigest)
TOOLING_SCRIPTS="$TOOLING_ROOT/scripts"

bash "$TOOLING_SCRIPTS/cleanup-review-snapshot.sh" \
  --temp-root "$REVIEW_TEMP_ROOT" --stale >/dev/null 2>&1 || true

DIFF_FILE="$REVIEW_RUN_ROOT/review.diff"
(
  cd "$PROJECT_ROOT"
  node "$TOOLING_SCRIPTS/build-review-diff.mjs" \
    --temp-root "$REVIEW_TEMP_ROOT" \
    --base-sha "$BASE_SHA" --head-sha "$HEAD_SHA" > "$DIFF_FILE"
)
DIFF_SHA256=$(node "$TOOLING_SCRIPTS/verify-review-diff.mjs" \
  --diff "$DIFF_FILE" --print-sha256)

REVIEW_SNAPSHOT_DIR=$(
  cd "$PROJECT_ROOT"
  node "$TOOLING_SCRIPTS/build-review-snapshot.mjs" \
    --temp-root "$REVIEW_TEMP_ROOT" \
    --base-sha "$BASE_SHA" --head-sha "$HEAD_SHA"
)
SNAPSHOT_METADATA_SHA256=$(node "$TOOLING_SCRIPTS/verify-review-snapshot.mjs" \
  --snapshot "$REVIEW_SNAPSHOT_DIR" --head-sha "$HEAD_SHA" \
  --print-metadata-sha256)

GUIDANCE_FILE="$REVIEW_RUN_ROOT/base-guidance.md"
GUIDANCE_CONTEXT=$(
  cd "$PROJECT_ROOT"
  node "$TOOLING_SCRIPTS/build-base-guidance.mjs" \
    --base-sha "$BASE_SHA" --output "$GUIDANCE_FILE"
)
BASE_GUIDANCE_SHA256=$(printf '%s' "$GUIDANCE_CONTEXT" | jq -r .baseGuidanceSha256)

CONTROL_PATHS_CHANGED=$(
  GIT_NO_REPLACE_OBJECTS=1 git -C "$PROJECT_ROOT" diff \
    --name-only --no-ext-diff --no-textconv "$MERGE_BASE_SHA" "$HEAD_SHA" -- \
    ':(glob)**/AGENTS.md' ':(glob)**/AGENTS.override.md' \
    ':(glob)**/CLAUDE.md' ':(glob)**/CLAUDE.local.md' \
    '.claude' '.agents' '.codex' '.Codex' '.mcp.json' \
    ':(glob)**/.gitattributes' | sed '/^$/d'
)

FINAL_CONTEXT=$(node -e '
const base = JSON.parse(process.argv[1]);
const extra = JSON.parse(process.argv[2]);
process.stdout.write(`${JSON.stringify({...base, ...extra})}\n`);
' "$RUN_CONTEXT" "$(jq -n \
  --argjson reviewStartedAtMs "$REVIEW_STARTED_AT_MS" \
  --arg skillDir "$TOOLING_ROOT" \
  --arg toolingDigest "$TOOLING_DIGEST" \
  --arg codexLauncherPath "$CODEX_LAUNCHER_PATH" \
  --arg reviewerLauncherPath "$REVIEWER_LAUNCHER_PATH" \
  --arg projectRoot "$PROJECT_ROOT" \
  --arg reviewMode "$REVIEW_MODE" \
  --arg target "$TARGET_ID" \
  --arg targetSlug "$TARGET_SLUG" \
  --arg repositoryHost "$PR_REPOSITORY_HOST" \
  --arg repository "$PR_REPOSITORY" \
  --arg prNumber "$PR_NUMBER" \
  --arg prReviewContextPath "$PR_REVIEW_CONTEXT_PATH" \
  --arg baseRef "$BASE_REF" \
  --arg headRef "$HEAD_REF" \
  --arg baseSha "$BASE_SHA" \
  --arg headSha "$HEAD_SHA" \
  --arg mergeBaseSha "$MERGE_BASE_SHA" \
  --arg diffFile "$DIFF_FILE" \
  --arg diffSha256 "$DIFF_SHA256" \
  --arg reviewSnapshotDir "$REVIEW_SNAPSHOT_DIR" \
  --arg snapshotMetadataSha256 "$SNAPSHOT_METADATA_SHA256" \
  --arg baseGuidancePath "$GUIDANCE_FILE" \
  --arg baseGuidanceSha256 "$BASE_GUIDANCE_SHA256" \
  --arg controlPathsChanged "$CONTROL_PATHS_CHANGED" \
  --arg claudeReviewModel "$CLAUDE_REVIEW_MODEL_FIXED" \
  --arg claudeReviewEffort "$CLAUDE_REVIEW_EFFORT_FIXED" \
  --arg codexReviewModel "$CODEX_REVIEW_MODEL_FIXED" \
  --arg codexReviewReasoningEffort "$CODEX_REVIEW_REASONING_EFFORT_FIXED" \
  --arg claudeReviewModelSource "$CLAUDE_REVIEW_MODEL_SOURCE" \
  --arg claudeReviewEffortSource "$CLAUDE_REVIEW_EFFORT_SOURCE" \
  --arg codexReviewModelSource "$CODEX_REVIEW_MODEL_SOURCE" \
  --arg codexReviewReasoningEffortSource "$CODEX_REVIEW_REASONING_EFFORT_SOURCE" \
  '{reviewStartedAtMs:$reviewStartedAtMs,
    skillDir:$skillDir,toolingDigest:$toolingDigest,
    codexLauncherPath:$codexLauncherPath,
    reviewerLauncherPath:$reviewerLauncherPath,projectRoot:$projectRoot,
    reviewMode:$reviewMode,target:$target,targetSlug:$targetSlug,
    repositoryHost:(if $repositoryHost == "" then null else $repositoryHost end),
    repository:(if $repository == "" then null else $repository end),
    prNumber:$prNumber,
    prReviewContextPath:(if $prReviewContextPath == "" then null else $prReviewContextPath end),
    baseRef:$baseRef,headRef:$headRef,
    baseSha:$baseSha,headSha:$headSha,mergeBaseSha:$mergeBaseSha,
    diffFile:$diffFile,diffSha256:$diffSha256,
    reviewSnapshotDir:$reviewSnapshotDir,
    snapshotMetadataSha256:$snapshotMetadataSha256,
    baseGuidancePath:$baseGuidancePath,
    baseGuidanceSha256:$baseGuidanceSha256,
    reviewerConfig:{
      claude:{model:$claudeReviewModel,effort:$claudeReviewEffort},
      codex:{model:$codexReviewModel,reasoningEffort:$codexReviewReasoningEffort}
    },
    reviewerConfigSources:{
      claude:{model:$claudeReviewModelSource,effort:$claudeReviewEffortSource},
      codex:{model:$codexReviewModelSource,reasoningEffort:$codexReviewReasoningEffortSource}
    },
    controlPathsChanged:($controlPathsChanged|split("\n")|map(select(length>0)))}'
)")

CONTEXT_PATH="$REVIEW_ARTIFACT_DIR/context.json"
printf '%s\n' "$FINAL_CONTEXT" > "$CONTEXT_PATH"
chmod 400 "$CONTEXT_PATH" 2>/dev/null || true
PREPARED=1
printf '%s\n' "$FINAL_CONTEXT"
