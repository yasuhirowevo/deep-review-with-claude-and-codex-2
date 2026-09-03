#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd -P "$TEST_DIR/.." && pwd -P)"
PREFLIGHT="$SKILL_DIR/scripts/run-review-preflight.sh"
T=$(mktemp -d /tmp/deep-review-preflight.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/temp" "$T/fake-cwd"

pass=0
fail=0
ok() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
ng() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

printf '%s\n' \
  'CLAUDE_REVIEW_MODEL=preflight-claude-model' \
  'CLAUDE_REVIEW_EFFORT=preflight-claude-effort' \
  'CODEX_REVIEW_MODEL=preflight-codex-model' \
  'CODEX_REVIEW_REASONING_EFFORT=preflight-codex-effort' \
  > "$T/reviewer.env"

cat > "$T/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'unexpected claude launch\n' > "$REVIEWER_MARKER"
exit 99
SH
cat > "$T/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'unexpected codex launch\n' > "$REVIEWER_MARKER"
exit 99
SH
chmod +x "$T/bin/claude" "$T/bin/codex"

git_fixture() {
  local repo="$1"
  shift
  git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid "$@"
}

create_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# fixture\n' > "$repo/README.md"
  git_fixture "$repo" add README.md
  git_fixture "$repo" commit -qm base
}

add_head_with_untrusted_runner() {
  local repo="$1"
  mkdir -p "$repo/.agents/skills/deep-review-with-claude-and-codex/scripts"
  cat > "$repo/.agents/skills/deep-review-with-claude-and-codex/scripts/run-review-preflight.sh" <<'SH'
#!/usr/bin/env bash
printf 'untrusted target runner executed\n' > "$UNTRUSTED_MARKER"
exit 99
SH
  printf 'changed\n' >> "$repo/README.md"
  git_fixture "$repo" add README.md .agents
  git_fixture "$repo" commit -qm head
}

run_preflight() {
  (
    cd "$T/fake-cwd"
    PATH="$T/bin:$PATH" \
      DEEP_REVIEW_CONFIG_FILE="$T/reviewer.env" \
      DEEP_REVIEW_TEMP_ROOT="$T/temp" \
      REVIEWER_MARKER="$T/reviewer-launched" \
      UNTRUSTED_MARKER="$T/untrusted-runner-executed" \
      bash "$PREFLIGHT" "$@"
  )
}

cleanup_result() {
  local result="$1" context skill
  context=$(printf '%s' "$result" | jq -er .contextPath)
  skill=$(jq -er .skillDir "$context")
  bash "$skill/scripts/cleanup-review-run.sh" "$context" >/dev/null
}

cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
args="$*"
case "$args" in
  "pr view 42 --json number,baseRefOid,headRefOid,url --jq "*)
    printf '42\t%s\t%s\thttps://github.example.com/owner/repo/pull/42\n' \
      "$FAKE_BASE_SHA" "$FAKE_HEAD_SHA"
    ;;
  "pr view 42 --repo github.example.com/owner/repo --json number,headRefOid")
    if [ "${FAKE_PR_CONTEXT_FAIL:-0}" = "1" ]; then
      echo "fixture PR context failure" >&2
      exit 7
    fi
    printf '{"number":42,"headRefOid":"%s"}\n' "$FAKE_HEAD_SHA"
    ;;
  *issues/42/comments*|*pulls/42/reviews*|*pulls/42/comments*)
    printf '[]\n'
    ;;
  *graphql*)
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
    ;;
  *)
    echo "unexpected gh invocation: $args" >&2
    exit 8
    ;;
esac
SH
chmod +x "$T/bin/gh"
if [ "$(node -p process.platform)" = "win32" ]; then
  NODE_EXE=$(node -p process.execPath)
  if command -v cygpath >/dev/null 2>&1; then
    NODE_EXE=$(cygpath -u "$NODE_EXE")
  fi
  cp "$NODE_EXE" "$T/bin/gh.exe"
  cat > "$T/fake-cwd/pr" <<'NODE'
const args = process.argv.slice(2);
if (args[0] !== "view" || args[1] !== "42") process.exit(8);
if (args.includes("--repo")) {
  if (process.env.FAKE_PR_CONTEXT_FAIL === "1") {
    process.stderr.write("fixture PR context failure\n");
    process.exit(7);
  }
  process.stdout.write(
    JSON.stringify({number: 42, headRefOid: process.env.FAKE_HEAD_SHA}) + "\n",
  );
} else {
  process.stdout.write(
    `42\t${process.env.FAKE_BASE_SHA}\t${process.env.FAKE_HEAD_SHA}` +
      "\thttps://github.example.com/owner/repo/pull/42\n",
  );
}
NODE
  cat > "$T/fake-cwd/api" <<'NODE'
const args = process.argv.slice(2);
if (args.includes("graphql")) {
  process.stdout.write(JSON.stringify({
    data: {repository: {pullRequest: {reviewThreads: {
      totalCount: 0,
      pageInfo: {hasNextPage: false, endCursor: null},
      nodes: [],
    }}}},
  }) + "\n");
} else {
  process.stdout.write("[]\n");
}
NODE
fi

echo "== PF01: branch preflight fixes inputs without executing target or reviewer tooling =="
BRANCH_REPO="$T/branch-repo"
create_repo "$BRANCH_REPO"
BRANCH_BASE=$(git -C "$BRANCH_REPO" rev-parse HEAD)
add_head_with_untrusted_runner "$BRANCH_REPO"
BRANCH_HEAD=$(git -C "$BRANCH_REPO" rev-parse HEAD)
BRANCH_RESULT=$(run_preflight --project "$BRANCH_REPO" --host codex \
  --branch "$BRANCH_HEAD" --base "$BRANCH_BASE")
BRANCH_CONTEXT=$(printf '%s' "$BRANCH_RESULT" | jq -r .contextPath)
BRANCH_PREFLIGHT=$(printf '%s' "$BRANCH_RESULT" | jq -r .preflightPath)
if printf '%s' "$BRANCH_RESULT" | jq -e \
  --arg base "$BRANCH_BASE" --arg head "$BRANCH_HEAD" '
  .schema == "deep-review-preflight/v1" and
  .status == "passed" and
  .host == "codex" and
  .target.mode == "branch" and
  .target.baseSha == $base and
  .target.headSha == $head and
  .target.mergeBaseSha == $base and
  .prReviewContext.status == "skipped" and
  .prReviewContext.path == null and
  (.inputs.toolingDigest | test("^[0-9a-f]{64}$")) and
  (.inputs.diffSha256 | test("^[0-9a-f]{64}$")) and
  (.inputs.snapshotMetadataSha256 | test("^[0-9a-f]{64}$")) and
  (.inputs.baseGuidanceSha256 | test("^[0-9a-f]{64}$")) and
  .timing.reviewStartedAtMs <= .timing.inputsPreparedAtMs and
  .timing.inputsPreparedAtMs <= .timing.prContextCompletedAtMs and
  .timing.prContextCompletedAtMs <= .timing.preflightCompletedAtMs and
  .timing.totalMs == (.timing.preflightCompletedAtMs - .timing.reviewStartedAtMs) and
  .nextAction == "build-threat-model-and-start-primary-reviewers"
' >/dev/null &&
  [ "$(jq -r .reviewStartedAtMs "$BRANCH_CONTEXT")" = \
    "$(printf '%s' "$BRANCH_RESULT" | jq -r .timing.reviewStartedAtMs)" ] &&
  jq -e '
    (.controlPathsChanged |
      index(".agents/skills/deep-review-with-claude-and-codex/scripts/run-review-preflight.sh")) != null
  ' "$BRANCH_CONTEXT" >/dev/null &&
  cmp -s <(printf '%s\n' "$BRANCH_RESULT") "$BRANCH_PREFLIGHT" &&
  [ ! -e "$T/reviewer-launched" ] && [ ! -e "$T/untrusted-runner-executed" ]; then
  ok "branch preflight preserves fixed-input quality gates and stops at the semantic handoff"
else
  ng "branch preflight preserves fixed-input quality gates and stops at the semantic handoff"
fi
cleanup_result "$BRANCH_RESULT"

echo "== PF02: PR preflight binds the checked initial comment snapshot =="
PR_REPO="$T/pr-repo"
create_repo "$PR_REPO"
PR_BASE=$(git -C "$PR_REPO" rev-parse HEAD)
printf 'pull request change\n' >> "$PR_REPO/README.md"
git_fixture "$PR_REPO" add README.md
git_fixture "$PR_REPO" commit -qm head
PR_HEAD=$(git -C "$PR_REPO" rev-parse HEAD)
PR_RESULT=$(FAKE_BASE_SHA="$PR_BASE" FAKE_HEAD_SHA="$PR_HEAD" \
  run_preflight --project "$PR_REPO" --host claude --pr 42)
PR_CONTEXT=$(printf '%s' "$PR_RESULT" | jq -r .contextPath)
PR_CONTEXT_PATH=$(printf '%s' "$PR_RESULT" | jq -r .prReviewContext.path)
if printf '%s' "$PR_RESULT" | jq -e \
  --arg base "$PR_BASE" --arg head "$PR_HEAD" '
  .status == "passed" and
  .host == "claude" and
  .target.mode == "pr" and
  .target.baseSha == $base and
  .target.headSha == $head and
  .prReviewContext.status == "checked" and
  (.prReviewContext.path | type == "string" and length > 0) and
  .prReviewContext.reasons == []
' >/dev/null &&
  jq -e '
    .snapshotRole == "initial" and
    .status == "checked" and
    .repositoryHost == "github.example.com" and
    .repository == "owner/repo" and
    .prNumber == 42 and
    .counts.issueComments.raw == 0 and
    .counts.reviews.raw == 0 and
    .counts.inlineComments.raw == 0 and
    .counts.reviewThreads.raw == 0
  ' "$PR_CONTEXT_PATH" >/dev/null &&
  [ -f "$PR_CONTEXT_PATH.receipt.json" ] &&
  [ "$(jq -r .prReviewContextPath "$PR_CONTEXT")" = "$PR_CONTEXT_PATH" ] &&
  [ ! -e "$T/reviewer-launched" ]; then
  ok "PR preflight completes the existing bounded initial context contract"
else
  ng "PR preflight completes the existing bounded initial context contract"
fi
cleanup_result "$PR_RESULT"

echo "== PF03: unavailable PR context degrades explicitly without blocking fixed-SHA review =="
PR_NOT_CHECKED=$(FAKE_BASE_SHA="$PR_BASE" FAKE_HEAD_SHA="$PR_HEAD" \
  FAKE_PR_CONTEXT_FAIL=1 run_preflight \
  --project "$PR_REPO" --host codex --pr 42)
if printf '%s' "$PR_NOT_CHECKED" | jq -e '
  .status == "passed" and
  .prReviewContext.status == "not-checked" and
  (.prReviewContext.reasons | length) > 0 and
  .nextAction == "build-threat-model-and-start-primary-reviewers"
' >/dev/null && [ ! -e "$T/reviewer-launched" ]; then
  ok "PR context failure remains fail-open only for comment exclusion, not input integrity"
else
  ng "PR context failure remains fail-open only for comment exclusion, not input integrity"
fi
cleanup_result "$PR_NOT_CHECKED"

echo "== PF04: invalid target and host fail before reviewer launch =="
run_preflight --project "$BRANCH_REPO" --host invalid \
  --branch "$BRANCH_HEAD" --base "$BRANCH_BASE" \
  >"$T/invalid-host.out" 2>"$T/invalid-host.err"
invalid_host_rc=$?
run_preflight --project "$BRANCH_REPO" --host codex \
  --branch refs/heads/does-not-exist --base "$BRANCH_BASE" \
  >"$T/invalid-target.out" 2>"$T/invalid-target.err"
invalid_target_rc=$?
if [ "$invalid_host_rc" -eq 2 ] && [ "$invalid_target_rc" -ne 0 ] &&
  [ ! -s "$T/invalid-host.out" ] && [ ! -s "$T/invalid-target.out" ] &&
  [ ! -e "$T/reviewer-launched" ]; then
  ok "preflight propagates preparation failures and never manufactures passed output"
else
  ng "preflight propagates preparation failures and never manufactures passed output"
fi

echo "== PF05: an injected future start time is rejected by the existing preparer =="
future_ms=$(node -e 'process.stdout.write(String(Date.now() + 60000))')
DEEP_REVIEW_CONFIG_FILE="$T/reviewer.env" DEEP_REVIEW_TEMP_ROOT="$T/temp" \
  bash "$SKILL_DIR/scripts/prepare-review-run.sh" \
  --project "$BRANCH_REPO" --branch "$BRANCH_HEAD" --base "$BRANCH_BASE" \
  --started-at-ms "$future_ms" >"$T/future.out" 2>"$T/future.err"
future_rc=$?
if [ "$future_rc" -eq 2 ] && [ ! -s "$T/future.out" ] &&
  rg -q --fixed-strings 'must be a positive epoch millisecond not in the future' \
    "$T/future.err"; then
  ok "preflight timing cannot inject a future review start"
else
  ng "preflight timing cannot inject a future review start"
fi

echo "== PF06: final stdout failure still cleans the completed preflight =="
STDOUT_REPO="$T/stdout-repo"
create_repo "$STDOUT_REPO"
STDOUT_BASE=$(git -C "$STDOUT_REPO" rev-parse HEAD)
printf 'stdout failure change\n' >> "$STDOUT_REPO/README.md"
git_fixture "$STDOUT_REPO" add README.md
git_fixture "$STDOUT_REPO" commit -qm head
STDOUT_HEAD=$(git -C "$STDOUT_REPO" rev-parse HEAD)
run_preflight --project "$STDOUT_REPO" --host codex \
  --branch "$STDOUT_HEAD" --base "$STDOUT_BASE" \
  >/dev/full 2>"$T/stdout-failure.err"
stdout_failure_rc=$?
failed_context=$(find "$STDOUT_REPO/_tmp/reviews/runs" \
  -type f -name context.json -print -quit 2>/dev/null || true)
failed_run_root=$(jq -r .reviewRunRoot "$failed_context")
failed_snapshot=$(jq -r .reviewSnapshotDir "$failed_context")
if [ "$stdout_failure_rc" -ne 0 ] && [ -n "$failed_context" ] &&
  [ ! -e "$failed_run_root" ] && [ ! -e "$failed_snapshot" ] &&
  [ ! -e "$T/reviewer-launched" ]; then
  ok "nonzero exit after preflight publication still cleans temporary run inputs"
else
  ng "nonzero exit after preflight publication still cleans temporary run inputs"
fi

printf '\nResult: %d pass / %d fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
