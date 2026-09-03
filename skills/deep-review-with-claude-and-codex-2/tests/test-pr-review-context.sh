#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FETCHER="$TEST_DIR/../scripts/fetch-pr-review-context.mjs"
PR_CONTEXT_MODULE="$TEST_DIR/../scripts/review-pr-context.mjs"
T=$(mktemp -d /tmp/deep-review-pr-context.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir "$T/bin"
cp "$PR_CONTEXT_MODULE" "$T/review-pr-context.mjs"

pass=0
fail=0
ok() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
ng() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RUN_ID=11111111-1111-4111-8111-111111111111

run_fetcher() {
  local fixture_case="$1" output="$2" fetcher="${3:-$FETCHER}"
  local repository="${4:-owner/repo}"
  local snapshot_role="${5:-initial}" supersedes="${6:-}"
  local -a snapshot_args=(--snapshot-role "$snapshot_role")
  if [ -n "$supersedes" ]; then
    snapshot_args+=(--supersedes "$supersedes")
  fi
  PATH="$T/bin:$PATH" \
    FAKE_CASE="$fixture_case" \
    GH_EXPECTED_REPOSITORY="$repository" \
    GH_IDENTITY_COUNT_FILE="$output.identity-count" \
    GH_CALL_LOG="$output.calls" \
    node "$fetcher" \
    --repo-host github.example.com \
    --repo "$repository" \
    --pr 42 \
    --expected-head-sha "$HEAD_A" \
    --review-run-id "$RUN_ID" \
    "${snapshot_args[@]}" \
    --output "$output"
}
read_artifacts() {
  node --input-type=module - "$PR_CONTEXT_MODULE" "$1" <<'NODE'
const [modulePath, contextPath] = process.argv.slice(2);
const { pathToFileURL } = await import("node:url");
const { readPrReviewContextArtifacts } = await import(pathToFileURL(modulePath));
readPrReviewContextArtifacts(contextPath);
NODE
}

cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
args="$*"
if [ "${1:-}" = "api" ]; then
  case "$args" in
    *"--hostname github.example.com"*) ;;
    *) echo "missing repository hostname: $args" >&2; exit 8 ;;
  esac
  if [ -n "${GH_CALL_LOG:-}" ]; then
    printf '%s\n' "$args" >> "$GH_CALL_LOG"
  fi
  if [ "${FAKE_CASE:-ok}" = "overall-timeout" ]; then
    exec sleep 60
  fi
fi
case "$args" in
  *"pr view 42 --repo github.example.com/${GH_EXPECTED_REPOSITORY:-owner/repo} --json number,headRefOid"*)
    if [ "${FAKE_CASE:-ok}" = "identity-failure" ]; then
      echo "identity fixture failure" >&2
      exit 7
    fi
    count=0
    if [ -f "$GH_IDENTITY_COUNT_FILE" ]; then
      count=$(cat "$GH_IDENTITY_COUNT_FILE")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$GH_IDENTITY_COUNT_FILE"
    number=42
    head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    if [ "${FAKE_CASE:-ok}" = "pr-mismatch" ]; then number=43; fi
    if [ "${FAKE_CASE:-ok}" = "before-mismatch" ]; then
      head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    fi
    if [ "${FAKE_CASE:-ok}" = "head-change" ] && [ "$count" -gt 1 ]; then
      head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    fi
    printf '{"number":%s,"headRefOid":"%s"}\n' "$number" "$head"
    ;;
  *issues/42/comments*)
    if [ "${FAKE_CASE:-ok}" = "rest-failure" ]; then
      echo "fixture failure" >&2
      exit 9
    fi
    if [ "${FAKE_CASE:-ok}" = "combined-cap" ]; then
      node -e '
        const body = "x".repeat(65 * 1024 * 1024);
        process.stdout.write(JSON.stringify([{id:1,body,user:{login:"alice",type:"User"}}]));
      '
      exit 0
    fi
    if [ "${FAKE_CASE:-ok}" = "timeout" ]; then
      exec sleep 60
    fi
    if [ "${FAKE_CASE:-ok}" = "rest-two-pages" ]; then
      page="${args##*&page=}"
      if [ "$page" = 1 ]; then
        PAGE="$page" node -e '
          const start = Number(process.env.PAGE) * 1000;
          const records = Array.from({length: 100}, (_, index) => ({
            id: start + index,
            body: `page-1-${index}`,
            user: {login: "alice", type: "User"},
          }));
          process.stdout.write(JSON.stringify(records));
        '
      else
        printf '%s\n' '[{"id":2001,"body":"page-2","user":{"login":"alice","type":"User"}}]'
      fi
      exit 0
    fi
    if [ "${FAKE_CASE:-ok}" = "source-cap" ]; then
      page="${args##*&page=}"
      PAGE="$page" node -e '
        const page = Number(process.env.PAGE);
        const start = (page - 1) * 100;
        const records = Array.from({length: 100}, (_, index) => ({
          id: start + index + 1,
          body: "bounded",
          user: {login: "alice", type: "User"},
        }));
        process.stdout.write(JSON.stringify(records));
      '
      exit 0
    fi
    printf '%s\n' '[{"id":1,"html_url":"https://example/issue/1","body":"human","user":{"login":"alice","type":"User"}},{"id":2,"body":"bot","user":{"login":"ci[bot]","type":"Bot"}}]'
    ;;
  *pulls/42/reviews*)
    printf '%s\n' '[{"id":3,"html_url":"https://example/review/3","body":"review","state":"APPROVED","user":{"login":"bob","type":"User"}}]'
    ;;
  *pulls/42/comments*)
    printf '%s\n' '[{"id":4,"html_url":"https://example/inline/4","body":"inline","path":"src/a.ts","line":9,"user":{"login":"carol","type":"User"}}]'
    ;;
  *graphql*)
    if [ "${FAKE_CASE:-ok}" = "graphql-errors" ]; then
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":"cursor-1"},"nodes":[{"id":"T-PARTIAL","isResolved":false,"isOutdated":false,"path":"src/partial.ts","line":7,"comments":{"totalCount":1,"nodes":[{"id":"TC-PARTIAL","databaseId":99,"url":"https://example/thread/partial","body":"must not be retained","author":{"login":"partial-user","__typename":"User"},"commit":{"oid":"partial"}}]}}]}}}},"errors":[{"message":"sensitive upstream detail","path":["repository","pullRequest","reviewThreads"]}]}'
    elif [ "${FAKE_CASE:-ok}" = "cursor-partial" ]; then
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"},"nodes":[{"id":"T1","isResolved":false,"isOutdated":false,"path":"src/a.ts","line":9,"comments":{"totalCount":1,"nodes":[{"id":"TC1","databaseId":5,"url":"https://example/thread/5","body":"thread","author":{"login":"dave"},"commit":{"oid":"abc"}}]}}]}}}}}'
    elif [ "${FAKE_CASE:-ok}" = "graphql-two-pages" ]; then
      case "$args" in
        *"endCursor=cursor-1"*)
          printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"pageInfo":{"hasNextPage":false,"endCursor":"cursor-2"},"nodes":[{"id":"T2","isResolved":true,"isOutdated":false,"path":"src/b.ts","line":3,"comments":{"totalCount":1,"nodes":[{"id":"TC2","databaseId":6,"url":"https://example/thread/6","body":"second","author":{"login":"erin","__typename":"User"},"commit":{"oid":"def"}}]}}]}}}}}'
          ;;
        *)
          printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"},"nodes":[{"id":"T1","isResolved":false,"isOutdated":false,"path":"src/a.ts","line":9,"comments":{"totalCount":1,"nodes":[{"id":"TC1","databaseId":5,"url":"https://example/thread/5","body":"first","author":{"login":"dave","__typename":"User"},"commit":{"oid":"abc"}}]}}]}}}}}'
          ;;
      esac
    else
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"pageInfo":{"hasNextPage":false,"endCursor":"cursor-1"},"nodes":[{"id":"T1","isResolved":true,"isOutdated":false,"path":"src/a.ts","line":9,"comments":{"totalCount":1,"nodes":[{"id":"TC1","databaseId":5,"url":"https://example/thread/5","body":"thread","author":{"login":"dave","__typename":"User"},"commit":{"oid":"abc"}}]}},{"id":"T2","isResolved":false,"isOutdated":false,"path":"src/b.ts","line":3,"comments":{"totalCount":1,"nodes":[{"id":"TC2","databaseId":6,"url":"https://example/thread/6","body":"bot thread","author":{"login":"ci[bot]","__typename":"Bot"},"commit":{"oid":"def"}}]}}]}}}}}'
    fi
    ;;
  *)
    echo "unexpected gh invocation: $args" >&2
    exit 8
    ;;
esac
SH
chmod +x "$T/bin/gh"

echo "== PR01: four fully paginated sources are checked =="
run_fetcher ok "$T/checked.json" >/dev/null
if jq -e '
  .schema == "deep-review-pr-review-context/v1" and
  .snapshotRole == "initial" and
  .supersedesSha256 == null and
  .reviewRunId == "11111111-1111-4111-8111-111111111111" and
  .repositoryHost == "github.example.com" and
  .repository == "owner/repo" and
  .prNumber == 42 and
  .expectedHeadSha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .headShaBefore == .expectedHeadSha and
  .headShaAfter == .expectedHeadSha and
  .status == "checked" and
  .counts.issueComments.raw == 2 and
  .counts.issueComments.nonBot == 1 and
  .counts.reviewThreads.raw == 2 and
  .counts.reviewThreads.nonBot == 1 and
  .counts.reviewThreads.deduped == 1 and
  (.records.issueComments | length) == 1 and
  .records.reviewThreads[0].isResolved == true
' "$T/checked.json" >/dev/null; then
  ok "all four sources, bot exclusion including bot-only threads, and thread state are preserved"
else
  ng "all four sources, bot exclusion including bot-only threads, and thread state are preserved"
fi
if jq -e '
  .schema == "deep-review-pr-review-context-receipt/v1" and
  .reviewRunId == "11111111-1111-4111-8111-111111111111" and
  .snapshotRole == "initial" and
  .supersedesSha256 == null and
  .status == "checked" and
  (.sha256 | test("^[0-9a-f]{64}$")) and
  (.size > 0)
' "$T/checked.json.receipt.json" >/dev/null &&
  read_artifacts "$T/checked.json"; then
  ok "fetch-time receipt binds the immutable initial snapshot bytes and identity"
else
  ng "fetch-time receipt binds the immutable initial snapshot bytes and identity"
fi

echo "== PR02: cursor termination mismatch is not checked =="
run_fetcher cursor-partial "$T/cursor.json" >/dev/null
if jq -e '
  .status == "not-checked" and
  any(.reasons[]; contains("repeated cursor")) and
  any(.unfetched[]; .source == "reviewThreads")
' "$T/cursor.json" >/dev/null; then
  ok "GraphQL partial pagination records the reason and unfetched range"
else
  ng "GraphQL partial pagination records the reason and unfetched range"
fi

echo "== PR03: one REST failure does not discard other evidence =="
run_fetcher rest-failure "$T/failure.json" >/dev/null
if jq -e '
  .status == "not-checked" and
  .counts.issueComments.raw == 0 and
  .counts.reviews.raw == 1 and
  .counts.inlineComments.raw == 1 and
  .counts.reviewThreads.raw == 2 and
  .counts.reviewThreads.nonBot == 1 and
  any(.unfetched[]; .source == "issueComments")
' "$T/failure.json" >/dev/null; then
  ok "partial failure is explicit while other source records remain available"
else
  ng "partial failure is explicit while other source records remain available"
fi

echo "== PR04: existing output is never overwritten =="
if ! run_fetcher ok "$T/checked.json" >/dev/null 2>"$T/existing.err" &&
  rg -q 'must not already exist' "$T/existing.err"; then
  ok "immutable output path fails closed"
else
  ng "immutable output path fails closed"
fi

echo "== PR05: combined raw response cap stops retention before parsing =="
run_fetcher combined-cap "$T/cap.json" >/dev/null
if jq -e '
  .status == "not-checked" and
  .rawBytes == .limits.combinedRawBytes and
  any(.reasons[]; contains("combined raw response cap")) and
  (.records.issueComments | length) == 0 and
  (.records.reviews | length) == 0 and
  (.records.inlineComments | length) == 0 and
  (.records.reviewThreads | length) == 0 and
  any(.unfetched[]; .source == "issueComments") and
  any(.unfetched[]; .source == "reviewThreads")
' "$T/cap.json" >/dev/null; then
  ok "combined cap prevents oversized and later responses from being retained"
else
  ng "combined cap prevents oversized and later responses from being retained"
fi

echo "== PR06: HEAD change during retrieval fails closed =="
run_fetcher head-change "$T/head-change.json" >/dev/null
if jq -e '
  .status == "not-checked" and
  .headShaBefore == .expectedHeadSha and
  .headShaAfter == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
  any(.reasons[]; contains("changed during comment retrieval")) and
  .counts.issueComments.deduped == 1
' "$T/head-change.json" >/dev/null; then
  ok "a moving PR HEAD is recorded without discarding the fetched evidence"
else
  ng "a moving PR HEAD is recorded without discarding the fetched evidence"
fi

echo "== PR07: mismatched HEAD before retrieval skips all comment sources =="
run_fetcher before-mismatch "$T/before-mismatch.json" >/dev/null
if jq -e '
  .status == "not-checked" and
  .headShaBefore == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
  .headShaAfter == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
  (.records[] | length == 0) and
  ([.unfetched[].source] | unique | length) == 4
' "$T/before-mismatch.json" >/dev/null; then
  ok "comments are not fetched for a different PR generation"
else
  ng "comments are not fetched for a different PR generation"
fi

echo "== PR08: mismatched PR identity is not accepted =="
run_fetcher pr-mismatch "$T/pr-mismatch.json" >/dev/null
if jq -e '
  .status == "not-checked" and
  .headShaBefore == null and
  .headShaAfter == null and
  any(.reasons[]; contains("does not match PR 42")) and
  (.records[] | length == 0)
' "$T/pr-mismatch.json" >/dev/null; then
  ok "unexpected PR identity fails closed before comment retrieval"
else
  ng "unexpected PR identity fails closed before comment retrieval"
fi

echo "== PR09: identity lookup failure is explicit and skips evidence =="
run_fetcher identity-failure "$T/identity-failure.json" >/dev/null
if jq -e '
  .status == "not-checked" and
  .headShaBefore == null and
  .headShaAfter == null and
  any(.reasons[]; contains("gh pr view failed")) and
  (.records[] | length == 0)
' "$T/identity-failure.json" >/dev/null; then
  ok "identity lookup failure cannot produce checked evidence"
else
  ng "identity lookup failure cannot produce checked evidence"
fi

echo "== PR10: REST pagination fetches one page at a time =="
run_fetcher rest-two-pages "$T/rest-two-pages.json" >/dev/null
if jq -e '
  .status == "checked" and
  .counts.issueComments.pages == 2 and
  .counts.issueComments.raw == 101 and
  .counts.issueComments.deduped == 101 and
  (.records.issueComments | length) == 101
' "$T/rest-two-pages.json" >/dev/null; then
  ok "REST sources continue page by page until a short terminal page"
else
  ng "REST sources continue page by page until a short terminal page"
fi

echo "== PR11: GraphQL pagination advances one cursor at a time =="
run_fetcher graphql-two-pages "$T/graphql-two-pages.json" >/dev/null
if jq -e '
  .status == "checked" and
  .counts.reviewThreads.pages == 2 and
  .counts.reviewThreads.raw == 2 and
  .counts.reviewThreads.deduped == 2 and
  (.records.reviewThreads | length) == 2
' "$T/graphql-two-pages.json" >/dev/null &&
  rg -q --fixed-strings -- '-f endCursor=cursor-1' \
    "$T/graphql-two-pages.json.calls"; then
  ok "GraphQL sources continue only with the previous raw-string cursor"
else
  ng "GraphQL sources continue only with the previous raw-string cursor"
fi

echo "== PR11a: GraphQL partial success fails closed =="
run_fetcher graphql-errors "$T/graphql-errors.json" >/dev/null
if jq -e '
  .status == "not-checked" and
  .counts.issueComments.raw == 2 and
  .counts.reviews.raw == 1 and
  .counts.inlineComments.raw == 1 and
  .counts.reviewThreads.pages == 0 and
  .counts.reviewThreads.raw == 0 and
  (.records.reviewThreads | length) == 0 and
  any(.reasons[]; contains("reviewThreads: page 1 returned GraphQL errors")) and
  any(.unfetched[]; .source == "reviewThreads" and .range == "page 1+")
' "$T/graphql-errors.json" >/dev/null &&
  ! rg -q --fixed-strings 'sensitive upstream detail' "$T/graphql-errors.json"; then
  ok "GraphQL errors reject the partial page while preserving complete sources"
else
  ng "GraphQL errors reject the partial page while preserving complete sources"
fi

echo "== PR11b: GraphQL string variables never use typed field conversion =="
run_fetcher ok "$T/numeric-repository.json" "$FETCHER" owner/123 >/dev/null
if jq -e '
  .status == "checked" and
  .repository == "owner/123" and
  .prNumber == 42 and
  .counts.reviewThreads.raw == 2
' "$T/numeric-repository.json" >/dev/null &&
  rg -q --fixed-strings -- \
    '-f owner=owner -f name=123 -F number=42 -f endCursor=' \
    "$T/numeric-repository.json.calls" &&
  ! rg -q --fixed-strings -- '-F name=123' \
    "$T/numeric-repository.json.calls"; then
  ok "numeric repository names remain strings while PR numbers remain integers"
else
  ng "numeric repository names remain strings while PR numbers remain integers"
fi

echo "== PR12: source record cap stops before requesting another page =="
run_fetcher source-cap "$T/source-cap.json" >/dev/null
if jq -e '
  .status == "not-checked" and
  .counts.issueComments.pages == 100 and
  .counts.issueComments.raw == .limits.sourceRecords and
  .apiRequests <= .limits.apiRequests and
  any(.reasons[]; contains("source cap 10000 reached")) and
  any(.unfetched[]; .source == "issueComments" and .range == "10001+")
' "$T/source-cap.json" >/dev/null &&
  ! rg -q 'issues/42/comments.*page=101' "$T/source-cap.json.calls"; then
  ok "the source cap prevents a page 101 API request"
else
  ng "the source cap prevents a page 101 API request"
fi

echo "== PR13: a non-responsive API call times out and degrades safely =="
timeout_fetcher="$T/fetch-pr-review-context-timeout.mjs"
sed 's/const GH_REQUEST_TIMEOUT_MS = 30_000;/const GH_REQUEST_TIMEOUT_MS = 100;/' \
  "$FETCHER" > "$timeout_fetcher"
run_fetcher timeout "$T/timeout.json" "$timeout_fetcher" >/dev/null
if jq -e '
  .status == "not-checked" and
  .limits.ghRequestTimeoutMs == 100 and
  .counts.issueComments.raw == 0 and
  .counts.reviews.raw == 1 and
  any(.reasons[]; contains("timed out after 100ms")) and
  any(.unfetched[]; .source == "issueComments" and .range == "page 1+")
' "$T/timeout.json" >/dev/null; then
  ok "a timed-out source is not treated as checked and later sources continue"
else
  ng "a timed-out source is not treated as checked and later sources continue"
fi

echo "== PR14: the global API request cap prevents later source calls =="
api_cap_fetcher="$T/fetch-pr-review-context-api-cap.mjs"
sed 's/const MAX_API_REQUESTS = 2 + 4 \* Math.ceil(SOURCE_RECORD_LIMIT \/ PAGE_SIZE);/const MAX_API_REQUESTS = 3;/' \
  "$FETCHER" > "$api_cap_fetcher"
run_fetcher ok "$T/api-cap.json" "$api_cap_fetcher" >/dev/null
if jq -e '
  .status == "not-checked" and
  .limits.apiRequests == 3 and
  .apiRequests == .limits.apiRequests and
  .counts.issueComments.raw == 2 and
  .counts.reviews.raw == 1 and
  .counts.inlineComments.raw == 0 and
  .counts.reviewThreads.raw == 0 and
  any(.reasons[]; contains("API request cap 3 reached")) and
  any(.unfetched[]; .source == "inlineComments" and .range == "page 1+")
' "$T/api-cap.json" >/dev/null &&
  ! rg -q 'pulls/42/comments|graphql' "$T/api-cap.json.calls"; then
  ok "the API request cap blocks every call after the configured maximum"
else
  ng "the API request cap blocks every call after the configured maximum"
fi

echo "== PR15: the overall fetch deadline prevents later source calls =="
overall_timeout_fetcher="$T/fetch-pr-review-context-overall-timeout.mjs"
sed \
  -e 's/const GH_REQUEST_TIMEOUT_MS = 30_000;/const GH_REQUEST_TIMEOUT_MS = 1_000;/' \
  -e 's/const FETCH_TIMEOUT_MS = 120_000;/const FETCH_TIMEOUT_MS = 150;/' \
  "$FETCHER" > "$overall_timeout_fetcher"
run_fetcher overall-timeout "$T/overall-timeout.json" \
  "$overall_timeout_fetcher" >/dev/null
if jq -e '
  .status == "not-checked" and
  .limits.fetchTimeoutMs == 150 and
  .apiRequests == 2 and
  .headShaBefore == .expectedHeadSha and
  .headShaAfter == null and
  all(.counts[]; .raw == 0) and
  any(.reasons[]; contains("overall fetch timeout 150ms reached")) and
  any(.unfetched[]; .source == "reviewThreads" and .range == "page 1+")
' "$T/overall-timeout.json" >/dev/null &&
  [ "$(wc -l < "$T/overall-timeout.json.calls" | tr -d ' ')" = 1 ]; then
  ok "the overall deadline stops all API calls after the timed-out request"
else
  ng "the overall deadline stops all API calls after the timed-out request"
fi

echo "== PR16: a final snapshot is bound to the initial snapshot bytes =="
run_fetcher ok "$T/final.json" "$FETCHER" owner/repo final "$T/checked.json" >/dev/null
initial_sha=$(jq -r .sha256 "$T/checked.json.receipt.json")
if jq -e --arg initialSha "$initial_sha" '
  .snapshotRole == "final" and
  .supersedesSha256 == $initialSha and
  .status == "checked"
' "$T/final.json" >/dev/null &&
  jq -e --arg initialSha "$initial_sha" '
    .snapshotRole == "final" and
    .supersedesSha256 == $initialSha and
    .status == "checked" and
    (.sha256 | test("^[0-9a-f]{64}$"))
  ' "$T/final.json.receipt.json" >/dev/null &&
  read_artifacts "$T/final.json"; then
  ok "the final snapshot records the exact initial snapshot digest"
else
  ng "the final snapshot records the exact initial snapshot digest"
fi

echo "== PR18: receipt verification rejects snapshot mutation =="
cp "$T/checked.json" "$T/checked-original.json"
chmod u+w "$T/checked.json" 2>/dev/null || true
jq '.records.issueComments[0].body = "mutated after fetch"' \
  "$T/checked-original.json" > "$T/checked.json"
if ! read_artifacts "$T/checked.json" >/dev/null 2>&1; then
  ok "a fetched PR comment record cannot be changed behind its receipt"
else
  ng "a fetched PR comment record cannot be changed behind its receipt"
fi
cp "$T/checked-original.json" "$T/checked.json"
chmod 400 "$T/checked.json" 2>/dev/null || true

echo "== PR19: receipt verification rejects a missing receipt =="
mv "$T/checked.json.receipt.json" "$T/checked-receipt.json"
if ! read_artifacts "$T/checked.json" >/dev/null 2>&1; then
  ok "a PR context without its fetch receipt is unusable"
else
  ng "a PR context without its fetch receipt is unusable"
fi
mv "$T/checked-receipt.json" "$T/checked.json.receipt.json"

echo "== PR17: a final snapshot cannot omit its initial snapshot binding =="
if ! run_fetcher ok "$T/final-without-initial.json" "$FETCHER" owner/repo final \
  >/dev/null 2>"$T/final-without-initial.err" &&
  rg -q 'final PR context requires --supersedes' "$T/final-without-initial.err"; then
  ok "final retrieval fails closed without the initial snapshot"
else
  ng "final retrieval fails closed without the initial snapshot"
fi

echo ""
printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
exit "$fail"
