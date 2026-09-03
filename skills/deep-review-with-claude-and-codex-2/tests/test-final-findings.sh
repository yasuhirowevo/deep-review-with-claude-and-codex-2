#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd -P "$TEST_DIR/.." && pwd -P)"
FINALIZER="$SKILL_DIR/scripts/review-final-findings.mjs"
ADJUDICATION_MODULE="$SKILL_DIR/scripts/review-adjudication.mjs"
PR_CONTEXT_MODULE="$SKILL_DIR/scripts/review-pr-context.mjs"
T=$(mktemp -d /tmp/deep-review-final-findings.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM

pass=0
fail=0
ok() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
ng() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }
expect_fail() {
  if "$@" >/dev/null 2>&1; then ng "$label"; else ok "$label"; fi
}
write_receipt() {
  node --input-type=module - "$PR_CONTEXT_MODULE" "$1" <<'NODE'
const [modulePath, contextPath] = process.argv.slice(2);
const { pathToFileURL } = await import("node:url");
const { writePrReviewContextReceipt } = await import(pathToFileURL(modulePath));
writePrReviewContextReceipt(contextPath);
NODE
}

RUN_ID=11111111-1111-4111-8111-111111111111
HEAD_SHA=2222222222222222222222222222222222222222
PHASE4_DIGEST=$(node --input-type=module - "$ADJUDICATION_MODULE" <<'NODE'
const modulePath = process.argv[2];
const { pathToFileURL } = await import("node:url");
const { findingSetSha256 } = await import(pathToFileURL(modulePath));
process.stdout.write(findingSetSha256([
  { id: "F1", severity: "High", title: "authentication bypass" },
  { id: "F2", severity: "Medium", title: "retry duplication" },
]));
NODE
)

cat > "$T/context.json" <<JSON
{
  "reviewRunId":"$RUN_ID",
  "reviewMode":"pr",
  "repositoryHost":"github.example.com",
  "repository":"owner/repo",
  "prNumber":"42",
  "headSha":"$HEAD_SHA"
}
JSON
cat > "$T/adjudication.json" <<JSON
{
  "schema":"deep-review-adjudication/v1",
  "reviewRunId":"$RUN_ID",
  "after":{
    "sha256":"$PHASE4_DIGEST",
    "findings":[
      {"id":"F1","severity":"High","title":"authentication bypass"},
      {"id":"F2","severity":"Medium","title":"retry duplication"}
    ]
  }
}
JSON
cat > "$T/pr-context.json" <<JSON
{
  "schema":"deep-review-pr-review-context/v1",
  "snapshotRole":"final",
  "supersedesSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "reviewRunId":"$RUN_ID",
  "repositoryHost":"github.example.com",
  "repository":"owner/repo",
  "prNumber":42,
  "expectedHeadSha":"$HEAD_SHA",
  "status":"checked",
  "records":{
    "issueComments":[{
      "stableId":"issueComments:123",
      "apiId":123,
      "url":"https://github.example.com/owner/repo/pull/42#issuecomment-123",
      "body":"fixed on the reviewed HEAD",
      "author":"alice",
      "createdAt":null,
      "updatedAt":null
    }],
    "reviews":[{
      "stableId":"reviews:456",
      "apiId":456,
      "url":"https://github.example.com/owner/repo/pull/42#pullrequestreview-456",
      "body":"approved after the fix",
      "author":"bob",
      "createdAt":null,
      "updatedAt":null,
      "state":"APPROVED",
      "submittedAt":null,
      "commitId":"$HEAD_SHA"
    }],
    "inlineComments":[],
    "reviewThreads":[]
  }
}
JSON
write_receipt "$T/pr-context.json"
cat > "$T/draft.json" <<'JSON'
{
  "decisions":[
    {
      "findingId":"F1",
      "outcome":"addressed",
      "handling":"addressed",
      "handlingRationale":"reviewed HEAD contains the fix",
      "evidence":[{"source":"reviews","stableId":"reviews:456"}],
      "rationale":"fixed on the reviewed HEAD"
    },
    {
      "findingId":"F2",
      "outcome":"not-judged",
      "handling":"this-pr-candidate",
      "handlingRationale":"the changed retry path directly causes the issue",
      "evidence":[],
      "rationale":"no matching PR comment"
    }
  ]
}
JSON

echo "== FF01: Phase 5 decisions derive the public finding set =="
node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/pr-context.json" \
  --draft "$T/draft.json" \
  --output "$T/final-findings.json" >/dev/null
if jq -e '
  .schema == "deep-review-final-findings/v3" and
  .summary.phase4 == 2 and
  .summary.addressed == 1 and
  .summary.notJudged == 1 and
  .summary.excluded == 1 and
  .summary.final == 1 and
  .summary.handling.addressed == 1 and
  .summary.handling["this-pr-candidate"] == 1 and
  (.handling.sha256 | test("^[0-9a-f]{64}$")) and
  .decisions[0].handlingLabel == "対応済み" and
  .decisions[1].handlingLabel == "このPRでの対応候補" and
  (.inputs.prReviewContext.sha256 | test("^[0-9a-f]{64}$")) and
  (.inputs.prReviewContext.receiptSha256 | test("^[0-9a-f]{64}$")) and
  .decisions[0].evidence == [{
    "source":"reviews",
    "stableId":"reviews:456",
    "recordSha256":.decisions[0].evidence[0].recordSha256,
    "url":"https://github.example.com/owner/repo/pull/42#pullrequestreview-456",
    "commitId":"2222222222222222222222222222222222222222",
    "state":"APPROVED",
    "isResolved":null,
    "isOutdated":null
  }] and
  (.decisions[0].evidence[0].recordSha256 | test("^[0-9a-f]{64}$")) and
  .final.findings == [{"id":"F2","severity":"Medium","title":"retry duplication"}]
' "$T/final-findings.json" >/dev/null; then
  ok "final artifact retains exactly the non-excluded canonical finding"
else
  ng "final artifact retains exactly the non-excluded canonical finding"
fi

jq '.records.issueComments[0].body = "edited after Phase 5"' \
  "$T/pr-context.json" > "$T/edited-pr-context.json"
write_receipt "$T/edited-pr-context.json"
if node --input-type=module - \
  "$FINALIZER" "$T/final-findings.json" "$T/context.json" \
  "$T/adjudication.json" "$T/edited-pr-context.json" <<'NODE' >/dev/null 2>&1
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [modulePath, artifactPath, contextPath, adjudicationPath, prContextPath] =
  process.argv.slice(2);
const { validateFinalFindingSetFile } = await import(pathToFileURL(modulePath));
const { readPrReviewContextArtifacts } = await import(
  new URL("./review-pr-context.mjs", pathToFileURL(modulePath))
);
const read = (filePath) => JSON.parse(readFileSync(filePath, "utf8"));
const prArtifacts = readPrReviewContextArtifacts(prContextPath);
validateFinalFindingSetFile({
  finalFindingSetPath: artifactPath,
  context: read(contextPath),
  adjudication: read(adjudicationPath),
  prReviewContext: prArtifacts.reviewContext,
  prReviewContextReceipt: prArtifacts.receipt,
});
NODE
then
  ng "final finding set is bound to the exact Phase 5 PR snapshot"
else
  ok "final finding set is bound to the exact Phase 5 PR snapshot"
fi

echo "== FF02: every finding and cited record are required =="
jq '.decisions = [.decisions[0]]' "$T/draft.json" > "$T/missing-decision.json"
label="missing Phase 5 finding decision is rejected"
expect_fail node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/pr-context.json" \
  --draft "$T/missing-decision.json" \
  --output "$T/missing-output.json"
jq '.decisions[0].evidence[0].stableId = "issueComments:999"' \
  "$T/draft.json" > "$T/unknown-evidence.json"
label="unavailable PR comment evidence is rejected"
expect_fail node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/pr-context.json" \
  --draft "$T/unknown-evidence.json" \
  --output "$T/unknown-output.json"
jq '.records.reviews += [.records.reviews[0]]' \
  "$T/pr-context.json" > "$T/duplicate-record.json"
label="duplicate PR record identity is rejected before finalization"
expect_fail write_receipt "$T/duplicate-record.json"

echo "== FF03: incomplete PR context cannot exclude findings =="
jq '.status = "not-checked"' "$T/pr-context.json" > "$T/not-checked.json"
write_receipt "$T/not-checked.json"
label="not-checked PR context cannot support an exclusion"
expect_fail node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/not-checked.json" \
  --draft "$T/draft.json" \
  --output "$T/not-checked-output.json"

echo "== FF04: persisted final fields are re-derived =="
jq '.final.findings[0].title = "substituted finding"' \
  "$T/final-findings.json" > "$T/forged-final.json"
if node --input-type=module - \
  "$FINALIZER" "$T/forged-final.json" "$T/context.json" \
  "$T/adjudication.json" "$T/pr-context.json" <<'NODE' >/dev/null 2>&1
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [modulePath, artifactPath, contextPath, adjudicationPath, prContextPath] =
  process.argv.slice(2);
const { validateFinalFindingSetFile } = await import(pathToFileURL(modulePath));
const { readPrReviewContextArtifacts } = await import(
  new URL("./review-pr-context.mjs", pathToFileURL(modulePath))
);
const read = (filePath) => JSON.parse(readFileSync(filePath, "utf8"));
const prArtifacts = readPrReviewContextArtifacts(prContextPath);
validateFinalFindingSetFile({
  finalFindingSetPath: artifactPath,
  context: read(contextPath),
  adjudication: read(adjudicationPath),
  prReviewContext: prArtifacts.reviewContext,
  prReviewContextReceipt: prArtifacts.receipt,
});
NODE
then
  ng "forged final finding content is rejected"
else
  ok "forged final finding content is rejected"
fi

echo "== FF05: importance and handling remain separate =="
jq '.decisions[1].handling = "unknown"' "$T/draft.json" \
  > "$T/unknown-handling.json"
label="unknown handling is rejected"
expect_fail node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/pr-context.json" \
  --draft "$T/unknown-handling.json" \
  --output "$T/unknown-handling-output.json"
jq '.decisions[1].handling = "user-decision"' "$T/draft.json" \
  > "$T/user-decision-without-question.json"
label="user decision handling requires a concrete question and decision impact"
expect_fail node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/pr-context.json" \
  --draft "$T/user-decision-without-question.json" \
  --output "$T/user-decision-without-question-output.json"
jq '.decisions[1].handlingRationale = "first line\nsecond line"' \
  "$T/draft.json" > "$T/multiline-handling.json"
label="report-bound handling fields reject multiline values during finalization"
expect_fail node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/pr-context.json" \
  --draft "$T/multiline-handling.json" \
  --output "$T/multiline-handling-output.json"

echo "== FF06: accepted decisions need genuinely new evidence before reopening =="
jq '
  .decisions[1] = {
    findingId:"F2",
    outcome:"dismissed-but-rechallenge",
    handling:"user-decision",
    handlingRationale:"scope decision is required",
    userDecisionRequest:"Include the newly requested trust boundary in this PR or track it separately",
    userDecisionImpact:"Including it requires an authorization redesign; tracking it separately preserves the current local-only boundary",
    evidence:[{source:"issueComments",stableId:"issueComments:123"}],
    rationale:"the code still exists"
  }
' "$T/draft.json" > "$T/rechallenge-without-new-evidence.json"
label="mere continued existence cannot reopen an accepted finding"
expect_fail node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/pr-context.json" \
  --draft "$T/rechallenge-without-new-evidence.json" \
  --output "$T/rechallenge-without-new-evidence-output.json"
jq '
  .decisions[1].rechallengeEvidence = {
    kind:"user-scope-change",
    detail:"the user explicitly added the new trust boundary to this PR"
  }
' "$T/rechallenge-without-new-evidence.json" > "$T/rechallenge-with-evidence.json"
if node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/pr-context.json" \
  --draft "$T/rechallenge-with-evidence.json" \
  --output "$T/rechallenge-with-evidence-output.json" >/dev/null; then
  ok "an explicit scope change can reopen a prior decision"
else
  ng "an explicit scope change can reopen a prior decision"
fi

jq '
  .decisions[1] = {
    findingId:"F2",
    outcome:"not-judged",
    handling:"additional-verification",
    handlingRationale:"the success record conflicts with the reachable code path",
    evidence:[],
    rationale:"keep the finding until the conflict is resolved"
  }
' "$T/draft.json" > "$T/verification-without-request.json"
label="additional verification handling requires a concrete verification request"
expect_fail node "$FINALIZER" \
  --context "$T/context.json" \
  --adjudication "$T/adjudication.json" \
  --pr-review-context "$T/pr-context.json" \
  --draft "$T/verification-without-request.json" \
  --output "$T/verification-without-request-output.json"

echo ""
printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
exit "$fail"
