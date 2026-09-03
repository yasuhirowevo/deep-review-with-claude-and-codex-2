#!/bin/bash
# Functional regression tests for generation-bound Claude review inputs.
# Uses fake claude/curl binaries. No external model or network is invoked.
# shellcheck disable=SC2016

set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPTS/.." && pwd)"
RUNNER="$SKILL_DIR/scripts/run-claude-attested.sh"

T=$(mktemp -d /tmp/deep-review-claude-attestation-test.XXXXXX)
MANAGED_TEMP="$T/managed-temp"
STALE_DIR="$MANAGED_TEMP/claude-review-input.StaleH4$$"
UNSAFE_STALE_DIR="$MANAGED_TEMP/claude-review-input.UnsafeH4$$"
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/repo" "$T/snapshot/src" "$MANAGED_TEMP"
MANAGED_TEMP_REAL=$(cd "$MANAGED_TEMP" && pwd -P)

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
contains() {
  if printf '%s' "$1" | grep -qF "$2"; then
    ok "$3"
  else
    ng "$3 (missing [$2])"
  fi
}
not_contains() {
  if printf '%s' "$1" | grep -qF "$2"; then
    ng "$3 (unexpected [$2])"
  else
    ok "$3"
  fi
}
sha256_file() {
  node -e '
    const fs = require("node:fs");
    const crypto = require("node:crypto");
    process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
  ' "$1"
}

cat > "$T/bin/curl" <<'FAKE'
#!/bin/bash
printf '200'
FAKE
chmod +x "$T/bin/curl"

cat > "$T/bin/claude" <<'FAKE'
#!/bin/bash
set -u

: "${FAKE_MODE:=success}"
: "${FAKE_PROMPT_FILE:?}"
: "${FAKE_INPUT_DIRS:?}"
: "${FAKE_ARGS_FILE:?}"
: "${FAKE_LAUNCH_COUNT:?}"
: "${FAKE_CONTROL_CAPTURE:?}"

printf '%s\n' "$@" > "$FAKE_ARGS_FILE"
cat > "$FAKE_PROMPT_FILE"
attestation_path=$(sed -n 's/^- 最初に Read で `\([^`]*\)`.*/\1/p' "$FAKE_PROMPT_FILE" | sed -n '1p')
if [ -n "$attestation_path" ] && [ -f "$attestation_path" ]; then
  receipt=$(jq -r '.receiptLine' "$attestation_path")
  diff_path=$(jq -r '.diffFile' "$attestation_path")
  repository_path=$(jq -r '.repositoryDir' "$attestation_path")
  probe_line_number=$(jq -r '.diffProbeLineNumber' "$attestation_path")
  diff_probe="DIFF_PROBE: $(sed -n "${probe_line_number}p" "$diff_path")"
  dirname "$attestation_path" >> "$FAKE_INPUT_DIRS"
  control_path=$(find "${CLAUDE_REVIEW_TEMP_ROOT:?}" \
    -maxdepth 2 -type f -name control.json -print -quit)
  [ -n "$control_path" ] && cp "$control_path" "$FAKE_CONTROL_CAPTURE"
else
  receipt=""
  diff_path=""
  repository_path=""
  diff_probe=""
fi
launches=$(cat "$FAKE_LAUNCH_COUNT")
printf '%s\n' $((launches + 1)) > "$FAKE_LAUNCH_COUNT"

case "$FAKE_MODE" in
  success)
    [ "$(sed -n '1p' "$diff_path")" = "diff --git a/src/example.ts b/src/example.ts" ] || exit 8
    [ "$(cat "$repository_path/src/example.ts")" = "export const example = 1;" ] || exit 9
    result=$(printf '%s\n%s\n\nNO_FINDINGS\nscope: fixed diff and HEAD snapshot\nreason: no actionable issue in fixture\n' "$receipt" "$diff_probe")
    ;;
  finding)
    result=$(printf '%s\n%s\n\nHigh: fixture finding\n' "$receipt" "$diff_probe")
    ;;
  finding_with_quoted_no_findings)
    result=$(printf '%s\n%s\n\nHigh: NO_FINDINGSの判定が正当な指摘を拒否する\n\n```text\nNO_FINDINGS\n```\n' "$receipt" "$diff_probe")
    ;;
  clean_with_quoted_finding)
    result=$(printf '%s\n%s\n\nNO_FINDINGS\n\n```md\nHigh: example finding format\n```\n' "$receipt" "$diff_probe")
    ;;
  clean_with_list_quoted_finding)
    result=$(printf '%s\n%s\n\n- ```md\n  High: example finding format\n  ```\n' "$receipt" "$diff_probe")
    ;;
  clean_with_nested_list_quoted_finding)
    result=$(printf '%s\n%s\n\n- - ```md\n    High: example finding format\n    ```\n' "$receipt" "$diff_probe")
    ;;
  clean_with_parent_list_quoted_finding)
    result=$(printf '%s\n%s\n\n- - item\n  ```md\n  High: example finding format\n  ```\n' "$receipt" "$diff_probe")
    ;;
  clean_with_tab_list_quoted_finding)
    result=$(printf '%s\n%s\n\n-\t```md\n\tHigh: example finding format\n\t```\n' "$receipt" "$diff_probe")
    ;;
  list_container_then_root_fence)
    result=$(printf '%s\n%s\n\n- ```text\nfoo\n```\nHigh: example finding format\n' "$receipt" "$diff_probe")
    ;;
  finding_with_unquoted_no_findings)
    result=$(printf '%s\n%s\n\nHigh: fixture finding\n\nNO_FINDINGS\n' "$receipt" "$diff_probe")
    ;;
  finding_with_no_findings_reference)
    result=$(printf '%s\n%s\n\nHigh: output contract rejects valid review\n\nNO_FINDINGS handling rejects this valid finding\n' "$receipt" "$diff_probe")
    ;;
  finding_with_list_quoted_no_findings)
    result=$(printf '%s\n%s\n\nHigh: fixture finding\n\n- ```text\n  NO_FINDINGS\n  ```\n' "$receipt" "$diff_probe")
    ;;
  finding_with_nested_list_quoted_no_findings)
    result=$(printf '%s\n%s\n\nHigh: fixture finding\n\n- - ```text\n    NO_FINDINGS\n    ```\n' "$receipt" "$diff_probe")
    ;;
  finding_with_parent_list_quoted_no_findings)
    result=$(printf '%s\n%s\n\nHigh: fixture finding\n\n- - item\n  ```text\n  NO_FINDINGS\n  ```\n' "$receipt" "$diff_probe")
    ;;
  finding_with_tab_list_quoted_no_findings)
    result=$(printf '%s\n%s\n\nHigh: fixture finding\n\n-\t```text\n\tNO_FINDINGS\n\t```\n' "$receipt" "$diff_probe")
    ;;
  finding_with_indented_list_quoted_no_findings)
    result=$(printf '%s\n%s\n\nHigh: fixture finding\n\n10. item\n    ```text\n    NO_FINDINGS\n    ```\n' "$receipt" "$diff_probe")
    ;;
  finding_after_unclosed_list_fence)
    result=$(printf '%s\n%s\n\n- ```text\nHigh: fixture finding\n' "$receipt" "$diff_probe")
    ;;
  finding_after_invalid_backtick_info)
    result=$(printf '%s\n%s\n\n```md`not-a-fence\nHigh: fixture finding\n' "$receipt" "$diff_probe")
    ;;
  followup)
    result=$(printf '%s\n%s\n\nThe requested finding is reproducible at src/example.ts:1.\n' "$receipt" "$diff_probe")
    ;;
  missing_receipt)
    result='NO_FINDINGS
scope: claimed
reason: claimed clean without receipt'
    ;;
  wrong_receipt)
    result='INPUT_RECEIPT: {"schema":"stale-generation"}

NO_FINDINGS
scope: stale
    reason: wrong receipt'
    ;;
  missing_diff_probe)
    result=$(printf '%s\n\nNO_FINDINGS\nscope: claimed\nreason: diff probe omitted\n' "$receipt")
    ;;
  empty_body)
    result=$(printf '%s\n%s\n' "$receipt" "$diff_probe")
    ;;
  invalid_clean_body)
    result=$(printf '%s\n%s\n\nNO_FINDINGS\n' "$receipt" "$diff_probe")
    ;;
  invalid_clean_with_severity)
    result=$(printf '%s\n%s\n\nNO_FINDINGS\nreason: No Critical issues were found\n' "$receipt" "$diff_probe")
    ;;
  empty_scope)
    result=$(printf '%s\n%s\n\nNO_FINDINGS\nscope:\nreason: reviewed the fixed diff\n' "$receipt" "$diff_probe")
    ;;
  empty_reason)
    result=$(printf '%s\n%s\n\nNO_FINDINGS\nscope: fixed diff and HEAD snapshot\nreason:\n' "$receipt" "$diff_probe")
    ;;
  confidence_only)
    result=$(printf '%s\n%s\n\nReviewed the fixed diff. confidence: high\n' "$receipt" "$diff_probe")
    ;;
  status_review_complete)
    result=$(printf '%s\n%s\n\nHigh: Review complete\n' "$receipt" "$diff_probe")
    ;;
  status_reviewed_field)
    result=$(printf '%s\n%s\n\nseverity: low\nfinding: reviewed\n' "$receipt" "$diff_probe")
    ;;
  status_with_no_findings)
    result=$(printf '%s\n%s\n\nHigh: Review complete with no actionable issues\n' "$receipt" "$diff_probe")
    ;;
  review_completed_with_no_findings)
    result=$(printf '%s\n%s\n\nHigh: Review completed with no actionable issues\n' "$receipt" "$diff_probe")
    ;;
  review_has_been_completed_with_no_findings)
    result=$(printf '%s\n%s\n\nHigh: Review has been completed; no issues were found\n' "$receipt" "$diff_probe")
    ;;
  review_completed_successfully_with_no_findings)
    result=$(printf '%s\n%s\n\nHigh: Review completed successfully with no issues found\n' "$receipt" "$diff_probe")
    ;;
  review_successfully_completed_with_no_findings)
    result=$(printf '%s\n%s\n\nHigh: Review successfully completed with no issues found\n' "$receipt" "$diff_probe")
    ;;
  review_completed_without_issues)
    result=$(printf '%s\n%s\n\nHigh: Review completed without any issues\n' "$receipt" "$diff_probe")
    ;;
  review_found_no_issues)
    result=$(printf '%s\n%s\n\nMedium: The review found no actionable issues\n' "$receipt" "$diff_probe")
    ;;
  there_were_no_issues)
    result=$(printf '%s\n%s\n\nLow: There were no issues identified\n' "$receipt" "$diff_probe")
    ;;
  review_did_not_find_issues)
    result=$(printf '%s\n%s\n\nHigh: The review did not find any actionable issues\n' "$receipt" "$diff_probe")
    ;;
  review_uncovered_no_issues)
    result=$(printf '%s\n%s\n\nHigh: The review uncovered no issues\n' "$receipt" "$diff_probe")
    ;;
  no_problems_emerged)
    result=$(printf '%s\n%s\n\nHigh: No problems emerged during the review\n' "$receipt" "$diff_probe")
    ;;
  no_issues_while_reviewing)
    result=$(printf '%s\n%s\n\nHigh: No issues were found while reviewing the diff\n' "$receipt" "$diff_probe")
    ;;
  no_findings_because_review_passed)
    result=$(printf '%s\n%s\n\nHigh: No findings were identified because the review passed\n' "$receipt" "$diff_probe")
    ;;
  no_issues_when_review_completed)
    result=$(printf '%s\n%s\n\nHigh: There were no issues when the review completed\n' "$receipt" "$diff_probe")
    ;;
  no_issues_or_failures)
    result=$(printf '%s\n%s\n\nHigh: No issues or failures were detected\n' "$receipt" "$diff_probe")
    ;;
  no_errors_or_failures)
    result=$(printf '%s\n%s\n\nHigh: No errors or failures were found\n' "$receipt" "$diff_probe")
    ;;
  no_bugs_errors_or_failures)
    result=$(printf '%s\n%s\n\nHigh: No bugs, errors, or failures were identified\n' "$receipt" "$diff_probe")
    ;;
  no_issues_or_failures_then_status)
    result=$(printf '%s\n%s\n\nHigh: No issues or failures were detected; review completed successfully\n' "$receipt" "$diff_probe")
    ;;
  repeated_no_findings)
    result=$(printf '%s\n%s\n\nHigh: No issues were found; no errors were detected\n' "$receipt" "$diff_probe")
    ;;
  repeated_no_findings_with_connector)
    result=$(printf '%s\n%s\n\nHigh: No issues were found, and no failures were identified\n' "$receipt" "$diff_probe")
    ;;
  qualified_review_no_findings)
    result=$(printf '%s\n%s\n\nHigh: The code review did not find any issues\n' "$receipt" "$diff_probe")
    ;;
  possessive_review_no_findings)
    result=$(printf '%s\n%s\n\nHigh: Our review did not find any issues\n' "$receipt" "$diff_probe")
    ;;
  qualified_analysis_no_findings)
    result=$(printf '%s\n%s\n\nMedium: This analysis did not identify failures\n' "$receipt" "$diff_probe")
    ;;
  nothing_of_note)
    result=$(printf '%s\n%s\n\nMedium: nothing of note but flagging anyway\n' "$receipt" "$diff_probe")
    ;;
  no_issues_to_report)
    result=$(printf '%s\n%s\n\nLow: No issues to report\n' "$receipt" "$diff_probe")
    ;;
  no_issues_in_reviewed_changes)
    result=$(printf '%s\n%s\n\nHigh: No actionable issues identified in the reviewed changes\n' "$receipt" "$diff_probe")
    ;;
  grouped_no_findings_token)
    result=$(printf '%s\n%s\n\n## High\n- NO_FINDINGS\n' "$receipt" "$diff_probe")
    ;;
  inline_no_finding)
    result=$(printf '%s\n%s\n\nHigh: 該当なし\n' "$receipt" "$diff_probe")
    ;;
  inline_no_finding_english)
    result=$(printf '%s\n%s\n\nHigh: No actionable issues were found.\n' "$receipt" "$diff_probe")
    ;;
  inline_no_finding_problem)
    result=$(printf '%s\n%s\n\nHigh: 問題は見つかりませんでした\n' "$receipt" "$diff_probe")
    ;;
  inline_no_finding_location)
    result=$(printf '%s\n%s\n\nHigh: 該当箇所なし\n' "$receipt" "$diff_probe")
    ;;
  grouped_no_finding)
    result=$(printf '%s\n%s\n\n## High\n- 該当なし\n' "$receipt" "$diff_probe")
    ;;
  table_no_finding)
    result=$(printf '%s\n%s\n\n| Severity | Finding |\n| --- | --- |\n| High | 該当なし |\n' "$receipt" "$diff_probe")
    ;;
  field_no_finding)
    result=$(printf '%s\n%s\n\n### レビュー結果\n- severity: high\n- evidence: 問題は見つかりませんでした\n' "$receipt" "$diff_probe")
    ;;
  tamper_owner)
    printf 'not-the-owner\n' > "$(dirname "$attestation_path")/.claude-review-owner"
    result=$(printf '%s\n%s\n\nHigh: fixture finding\n' "$receipt" "$diff_probe")
    ;;
  compact_finding)
    result=$(printf '%s\n%s\n\n### H1. fixture finding\n' "$receipt" "$diff_probe")
    ;;
  short_inline_finding)
    result=$(printf '%s\n%s\n\nHigh: auth fails\n' "$receipt" "$diff_probe")
    ;;
  short_grouped_finding)
    result=$(printf '%s\n%s\n\n## High\n- 保存できない\n' "$receipt" "$diff_probe")
    ;;
  short_field_finding)
    result=$(printf '%s\n%s\n\nseverity: low\nfinding: publish path mismatch\n' "$receipt" "$diff_probe")
    ;;
  negative_context_finding)
    result=$(printf '%s\n%s\n\nHigh: no issues are reported when authentication fails\n' "$receipt" "$diff_probe")
    ;;
  hidden_failure_finding)
    result=$(printf '%s\n%s\n\nHigh: No issues are reported; authentication failures remain hidden\n' "$receipt" "$diff_probe")
    ;;
  causing_failure_finding)
    result=$(printf '%s\n%s\n\nHigh: No issues are reported, causing authentication failures to go unnoticed\n' "$receipt" "$diff_probe")
    ;;
  http_error_finding)
    result=$(printf '%s\n%s\n\nHigh: No error is reported; the API returns 500\n' "$receipt" "$diff_probe")
    ;;
  thrown_error_finding)
    result=$(printf '%s\n%s\n\nHigh: No issue is shown; the request throws TypeError\n' "$receipt" "$diff_probe")
    ;;
  false_return_finding)
    result=$(printf '%s\n%s\n\nHigh: No error appears; the save operation returns false\n' "$receipt" "$diff_probe")
    ;;
  subjectless_negation_finding)
    result=$(printf '%s\n%s\n\nHigh: Does not handle errors\n' "$receipt" "$diff_probe")
    ;;
  grouped_subjectless_negation_finding)
    result=$(printf '%s\n%s\n\n## High\n- Does not report failures\n' "$receipt" "$diff_probe")
    ;;
  review_subject_defect_finding)
    result=$(printf '%s\n%s\n\nHigh: Review does not handle errors\n' "$receipt" "$diff_probe")
    ;;
  coordinated_negative_context_finding)
    result=$(printf '%s\n%s\n\nHigh: No issues or failures were detected during validation, but the save loses data\n' "$receipt" "$diff_probe")
    ;;
  status_context_finding)
    result=$(printf '%s\n%s\n\nHigh: Review complete but authentication still fails\n' "$receipt" "$diff_probe")
    ;;
  grouped_finding)
    result=$(printf '%s\n%s\n\n## High\n- src/example.ts:1 loses the saved value\n' "$receipt" "$diff_probe")
    ;;
  numbered_finding)
    result=$(printf '%s\n%s\n\n1. **High**: src/example.ts:1 loses the saved value\n' "$receipt" "$diff_probe")
    ;;
  field_finding)
    result=$(printf '%s\n%s\n\n### finding\n- severity: high\n- evidence: src/example.ts:1 accepts an invalid value\n' "$receipt" "$diff_probe")
    ;;
  table_finding)
    result=$(printf '%s\n%s\n\n| Severity | Finding |\n| --- | --- |\n| High | src/example.ts:1 loses the saved value |\n' "$receipt" "$diff_probe")
    ;;
  markdown_clean)
    result=$(printf '%s\n%s\n\n**NO_FINDINGS**\n- **scope**: fixed diff\n- **reason**: no actionable issue\n' "$receipt" "$diff_probe")
    ;;
  *)
    echo "unknown fake mode: $FAKE_MODE" >&2
    exit 2
    ;;
esac

jq -n \
  --arg result "$result" \
  '{
    session_id: "claude-attested-session",
    is_error: false,
    result: $result,
    total_cost_usd: 0.1,
    permission_denials: []
  }'
FAKE
chmod +x "$T/bin/claude"

export PATH="$T/bin:$PATH"
export FAKE_PROMPT_FILE="$T/rendered-prompt"
export FAKE_INPUT_DIRS="$T/input-dirs"
export FAKE_ARGS_FILE="$T/claude-args"
export FAKE_LAUNCH_COUNT="$T/launch-count"
export FAKE_CONTROL_CAPTURE="$T/control-capture.json"
export CLAUDE_REVIEW_TEMP_ROOT="$MANAGED_TEMP"
: > "$FAKE_INPUT_DIRS"
printf '0\n' > "$FAKE_LAUNCH_COUNT"

HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$T/review.diff" <<'EOF'
diff --git a/src/example.ts b/src/example.ts
index 1111111..2222222 100644
--- a/src/example.ts
+++ b/src/example.ts
@@ -1 +1 @@
-export const example = 0;
+export const example = 1;
EOF
printf 'export const example = 1;\n' > "$T/snapshot/src/example.ts"
FILE_SHA=$(sha256_file "$T/snapshot/src/example.ts")
FILE_SIZE=$(wc -c < "$T/snapshot/src/example.ts" | tr -d ' ')
cat > "$T/snapshot.metadata.json" <<EOF
{
  "creator": "deep-review-with-claude-and-codex",
  "state": "complete",
  "headSha": "$HEAD_SHA",
  "manifest": [
    {
      "path": "src/example.ts",
      "size": $FILE_SIZE,
      "sha256": "$FILE_SHA",
      "kind": "blob"
    }
  ]
}
EOF
DIFF_SHA=$(sha256_file "$T/review.diff")
SNAPSHOT_METADATA_SHA=$(sha256_file "$T/snapshot.metadata.json")
cat > "$T/prompt-template.txt" <<'EOF'
## 実行境界（最優先）
Read the fixed review diff at {{CLAUDE_REVIEW_DIFF}}.
Read the fixed HEAD snapshot at {{CLAUDE_REVIEW_REPOSITORY}}.
Return severity-tagged findings or NO_FINDINGS + scope + reason.
EOF
CONTEXT_PATH="$T/context.json"
jq -n '{reviewerConfig:{claude:{model:"context-claude-model",effort:"high"},codex:{model:"context-codex-model",reasoningEffort:"xhigh"}}}' \
  > "$CONTEXT_PATH"

OWNER_TOKEN=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
mkdir -p "$STALE_DIR" "$UNSAFE_STALE_DIR"
printf '%s\n' "$OWNER_TOKEN" > "$STALE_DIR/.claude-review-owner"
cat > "$STALE_DIR/.claude-review-lifecycle.json" <<EOF
{"schema":"deep-review-claude-input/v1","creator":"deep-review-with-claude-and-codex","state":"complete","ownerToken":"$OWNER_TOKEN"}
EOF
printf 'not-owned\n' > "$UNSAFE_STALE_DIR/.claude-review-owner"
cat > "$UNSAFE_STALE_DIR/.claude-review-lifecycle.json" <<EOF
{"schema":"deep-review-claude-input/v1","creator":"deep-review-with-claude-and-codex","state":"complete","ownerToken":"$OWNER_TOKEN"}
EOF
touch -t 200001010000 "$STALE_DIR" "$UNSAFE_STALE_DIR"

run_attested() {
  local mode="$1" contract="$2" run_id="$3"
  shift 3
  FAKE_MODE="$mode" \
  CLAUDE_REVIEW_MODEL=ambient-claude-model \
  CLAUDE_REVIEW_EFFORT=low \
  bash "$RUNNER" \
    --context "$CONTEXT_PATH" \
    --project "$T/repo" \
    --prompt-template "$T/prompt-template.txt" \
    --diff "$T/review.diff" \
    --snapshot "$T/snapshot" \
    --run-id "$run_id" \
    --target pr:42 \
    --head-sha "$HEAD_SHA" \
    --diff-sha256 "$DIFF_SHA" \
    --snapshot-metadata-sha256 "$SNAPSHOT_METADATA_SHA" \
    --result-contract "$contract" \
    "$@"
}

echo "== A01: exact generation receipt is verified and stripped =="
out=$(run_attested success review phase2-claude-a01 2>"$T/a01.err"); rc=$?
check "$rc" "0" "attested clean review exits 0"
contains "$out" "RUN_ID: phase2-claude-a01" "verified output carries the expected run-id"
contains "$out" "INPUT_ATTESTATION: verified" "verified output carries attestation status"
contains "$out" "HEAD_SHA: $HEAD_SHA" "verified output carries the fixed HEAD"
contains "$out" "DIFF_SHA256: $DIFF_SHA" "verified output carries the fixed diff digest"
contains "$out" "NO_FINDINGS" "clean review body is preserved"
not_contains "$out" "INPUT_RECEIPT:" "challenge receipt is stripped from the accepted body"
if rg -q -U --fixed-strings -- $'--model\ncontext-claude-model' "$FAKE_ARGS_FILE" &&
  rg -q -U --fixed-strings -- $'--effort\nhigh' "$FAKE_ARGS_FILE"; then
  ok "attested Claude launch uses the context-fixed reviewer settings"
else
  ng "attested Claude launch uses the context-fixed reviewer settings"
fi
first_input=$(sed -n '1p' "$FAKE_INPUT_DIRS")
case "$first_input" in
  "$MANAGED_TEMP_REAL"/claude-review-input.*) ok "attested input uses the selected temporary root" ;;
  *) ng "attested input uses the selected temporary root (got=[$first_input])" ;;
esac
if [ ! -e "$first_input" ]; then
  ok "owned attested input is cleaned"
else
  ng "owned attested input is cleaned"
fi
contains "$(cat "$FAKE_PROMPT_FILE")" "### 入力世代の受領証" "receipt instruction is injected inside the execution boundary"
contains "$(cat "$FAKE_PROMPT_FILE")" "受領証とDIFF_PROBEの次行以降" "review body placement follows both proof lines"
contains "$(cat "$FAKE_PROMPT_FILE")" "\`Severity\` 列と \`Finding\` 列" "accepted review body grammar is explicit"
not_contains "$(cat "$FAKE_PROMPT_FILE")" "{{CLAUDE_REVIEW_DIFF}}" "diff placeholder is replaced"
not_contains "$(cat "$FAKE_PROMPT_FILE")" "{{CLAUDE_REVIEW_REPOSITORY}}" "snapshot placeholder is replaced"
if jq -e '.diffProbeSha256 | strings | test("^[0-9a-f]{64}$")' \
  "$FAKE_CONTROL_CAPTURE" >/dev/null; then
  ok "control keeps only the diff probe digest"
else
  ng "control keeps only the diff probe digest"
fi
if jq -e 'has("diffProbeLine") | not' "$FAKE_CONTROL_CAPTURE" >/dev/null \
  && ! grep -Fq "DIFF_PROBE:" "$FAKE_CONTROL_CAPTURE"; then
  ok "control does not expose the expected diff probe line"
else
  ng "control does not expose the expected diff probe line"
fi
if [ ! -e "$STALE_DIR" ]; then
  ok "validated stale attested input is cleaned"
else
  ng "validated stale attested input is cleaned"
fi
if [ -e "$UNSAFE_STALE_DIR" ]; then
  ok "stale input with mismatched ownership is preserved"
else
  ng "stale input with mismatched ownership is preserved"
fi

echo "== A02: missing, stale, empty, and malformed clean results fail closed =="
for mode in \
  missing_receipt wrong_receipt missing_diff_probe empty_body \
  invalid_clean_body invalid_clean_with_severity clean_with_quoted_finding \
  clean_with_list_quoted_finding clean_with_nested_list_quoted_finding \
  clean_with_parent_list_quoted_finding \
  clean_with_tab_list_quoted_finding \
  list_container_then_root_fence \
  finding_with_unquoted_no_findings \
  empty_scope empty_reason \
  confidence_only status_review_complete status_reviewed_field \
  status_with_no_findings review_completed_with_no_findings \
  review_has_been_completed_with_no_findings \
  review_completed_successfully_with_no_findings nothing_of_note \
  review_successfully_completed_with_no_findings \
  review_completed_without_issues review_found_no_issues \
  there_were_no_issues review_did_not_find_issues \
  review_uncovered_no_issues no_problems_emerged \
  no_issues_while_reviewing no_findings_because_review_passed \
  no_issues_when_review_completed \
  no_issues_or_failures no_errors_or_failures \
  no_bugs_errors_or_failures \
  no_issues_or_failures_then_status \
  repeated_no_findings repeated_no_findings_with_connector \
  qualified_review_no_findings possessive_review_no_findings \
  qualified_analysis_no_findings \
  no_issues_to_report no_issues_in_reviewed_changes \
  grouped_no_findings_token \
  inline_no_finding inline_no_finding_english \
  inline_no_finding_problem inline_no_finding_location \
  grouped_no_finding table_no_finding field_no_finding; do
  run_attested "$mode" review "phase2-claude-$mode" >"$T/$mode.out" 2>"$T/$mode.err"
  rc=$?
  check "$rc" "1" "$mode exits 1"
  contains "$(cat "$T/$mode.out")" "STATUS: input_attestation_failed" "$mode is surfaced as attestation failure"
done
contains "$(cat "$T/missing_receipt.err")" "receipt is missing" "missing receipt is diagnosed"
contains "$(cat "$T/wrong_receipt.err")" "does not match this review generation" "stale receipt is diagnosed"
contains "$(cat "$T/missing_diff_probe.err")" "diff access probe is missing" "missing diff access proof is diagnosed"
contains "$(cat "$T/empty_body.err")" "empty review body" "receipt-only output is diagnosed"
contains "$(cat "$T/invalid_clean_body.err")" "must include scope + reason" "malformed clean result is diagnosed"
contains "$(cat "$T/invalid_clean_with_severity.err")" "must include scope + reason" "severity words cannot bypass an incomplete clean result"
contains "$(cat "$T/clean_with_quoted_finding.err")" "must include scope + reason" "quoted severity cannot bypass an incomplete clean result"
contains "$(cat "$T/clean_with_list_quoted_finding.err")" "severity-tagged findings" "list-nested quoted severity cannot stand in for a finding"
contains "$(cat "$T/clean_with_nested_list_quoted_finding.err")" "severity-tagged findings" "nested-list quoted severity cannot stand in for a finding"
contains "$(cat "$T/clean_with_parent_list_quoted_finding.err")" "severity-tagged findings" "quoted severity in a parent list cannot stand in for a finding"
contains "$(cat "$T/clean_with_tab_list_quoted_finding.err")" "severity-tagged findings" "tab-indented quoted severity cannot stand in for a finding"
contains "$(cat "$T/list_container_then_root_fence.err")" "severity-tagged findings" "a root fence after an unclosed list fence still hides quoted severity"
contains "$(cat "$T/finding_with_unquoted_no_findings.err")" "must include scope + reason" "unquoted NO_FINDINGS remains fail-closed beside a finding"
contains "$(cat "$T/empty_scope.err")" "must include scope + reason" "empty scope is rejected"
contains "$(cat "$T/empty_reason.err")" "must include scope + reason" "empty reason is rejected"
contains "$(cat "$T/confidence_only.err")" "severity-tagged findings" "confidence wording is not accepted as a finding"
contains "$(cat "$T/status_review_complete.err")" "severity-tagged findings" "review-complete status is not accepted as a finding"
contains "$(cat "$T/status_reviewed_field.err")" "severity-tagged findings" "reviewed status field is not accepted as a finding"
contains "$(cat "$T/status_with_no_findings.err")" "severity-tagged findings" "combined status and no-finding text is not accepted as a finding"
contains "$(cat "$T/review_completed_with_no_findings.err")" "severity-tagged findings" "completed-review wording cannot bypass the finding contract"
contains "$(cat "$T/review_has_been_completed_with_no_findings.err")" "severity-tagged findings" "multi-word completion status cannot bypass the finding contract"
contains "$(cat "$T/review_completed_successfully_with_no_findings.err")" "severity-tagged findings" "completion adverbs cannot bypass the finding contract"
contains "$(cat "$T/review_successfully_completed_with_no_findings.err")" "severity-tagged findings" "pre-completion adverbs cannot bypass the finding contract"
contains "$(cat "$T/review_completed_without_issues.err")" "severity-tagged findings" "without-issue wording cannot bypass the finding contract"
contains "$(cat "$T/review_found_no_issues.err")" "severity-tagged findings" "review-subject wording cannot bypass the finding contract"
contains "$(cat "$T/there_were_no_issues.err")" "severity-tagged findings" "existential no-issue wording cannot bypass the finding contract"
contains "$(cat "$T/review_did_not_find_issues.err")" "severity-tagged findings" "negated review verbs cannot bypass the finding contract"
contains "$(cat "$T/review_uncovered_no_issues.err")" "severity-tagged findings" "post-verb no-issue wording cannot bypass the finding contract"
contains "$(cat "$T/no_problems_emerged.err")" "severity-tagged findings" "no-problem subject wording cannot bypass the finding contract"
contains "$(cat "$T/no_issues_while_reviewing.err")" "severity-tagged findings" "review activity alone is not concrete problem evidence"
contains "$(cat "$T/no_findings_because_review_passed.err")" "severity-tagged findings" "a successful review reason is not concrete problem evidence"
contains "$(cat "$T/no_issues_when_review_completed.err")" "severity-tagged findings" "review completion context is not concrete problem evidence"
contains "$(cat "$T/no_issues_or_failures.err")" "severity-tagged findings" "a coordinated no-issue list is not accepted as a finding"
contains "$(cat "$T/no_errors_or_failures.err")" "severity-tagged findings" "a coordinated no-error list is not accepted as a finding"
contains "$(cat "$T/no_bugs_errors_or_failures.err")" "severity-tagged findings" "a comma-separated no-problem list is not accepted as a finding"
contains "$(cat "$T/no_issues_or_failures_then_status.err")" "severity-tagged findings" "a coordinated no-issue claim followed only by status remains rejected"
contains "$(cat "$T/repeated_no_findings.err")" "severity-tagged findings" "repeated no-finding clauses are not accepted as a finding"
contains "$(cat "$T/repeated_no_findings_with_connector.err")" "severity-tagged findings" "connected no-finding clauses are not accepted as a finding"
contains "$(cat "$T/qualified_review_no_findings.err")" "severity-tagged findings" "a qualified code-review no-finding claim remains rejected"
contains "$(cat "$T/possessive_review_no_findings.err")" "severity-tagged findings" "a possessive review no-finding claim remains rejected"
contains "$(cat "$T/qualified_analysis_no_findings.err")" "severity-tagged findings" "a qualified analysis no-finding claim remains rejected"
contains "$(cat "$T/nothing_of_note.err")" "severity-tagged findings" "vacuous flagging text is not accepted as a finding"
contains "$(cat "$T/no_issues_to_report.err")" "severity-tagged findings" "no-issue reporting status is not accepted as a finding"
contains "$(cat "$T/no_issues_in_reviewed_changes.err")" "severity-tagged findings" "review-scope qualifiers cannot turn a clean result into a finding"
contains "$(cat "$T/grouped_no_findings_token.err")" "severity-tagged findings" "grouped NO_FINDINGS token is not accepted as a finding"
contains "$(cat "$T/inline_no_finding.err")" "severity-tagged findings" "inline no-finding placeholder is rejected"
contains "$(cat "$T/inline_no_finding_english.err")" "severity-tagged findings" "English no-finding placeholder is rejected"
contains "$(cat "$T/inline_no_finding_problem.err")" "severity-tagged findings" "Japanese no-problem sentence is rejected"
contains "$(cat "$T/inline_no_finding_location.err")" "severity-tagged findings" "Japanese no-location sentence is rejected"
contains "$(cat "$T/grouped_no_finding.err")" "severity-tagged findings" "grouped no-finding placeholder is rejected"
contains "$(cat "$T/table_no_finding.err")" "severity-tagged findings" "table no-finding placeholder is rejected"
contains "$(cat "$T/field_no_finding.err")" "severity-tagged findings" "negative field content cannot fall back to a generic heading"

echo "== A03: follow-up keeps generation proof without weakening its body contract =="
out=$(run_attested followup followup phase3-followup-a03 --resume-session-id resume-session-3 2>"$T/a03.err"); rc=$?
check "$rc" "0" "attested follow-up exits 0"
contains "$out" "INPUT_ATTESTATION: verified" "follow-up verifies the new input generation"
contains "$out" "requested finding is reproducible" "free-form follow-up answer is preserved"
contains "$(cat "$FAKE_ARGS_FILE")" "resume-session-3" "resume session is forwarded"

echo "== A04: source digest mismatch stops before Claude launch =="
launches_before=$(cat "$FAKE_LAUNCH_COUNT")
FAKE_MODE=success bash "$RUNNER" \
  --context "$CONTEXT_PATH" \
  --project "$T/repo" \
  --prompt-template "$T/prompt-template.txt" \
  --diff "$T/review.diff" \
  --snapshot "$T/snapshot" \
  --run-id phase2-bad-digest \
  --target pr:42 \
  --head-sha "$HEAD_SHA" \
  --diff-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --snapshot-metadata-sha256 "$SNAPSHOT_METADATA_SHA" \
  --result-contract review >"$T/a04.out" 2>"$T/a04.err"
rc=$?
check "$rc" "1" "wrong expected diff digest exits 1"
check "$(cat "$FAKE_LAUNCH_COUNT")" "$launches_before" "Claude is not launched for a mismatched source generation"
contains "$(cat "$T/a04.err")" "review diff digest mismatch" "source digest mismatch is diagnosed"

echo "== A05: every accepted retry gets a distinct private input bundle =="
out=$(run_attested finding review phase4-round1-retry1 2>"$T/a05.err"); rc=$?
check "$rc" "0" "attested retry review exits 0"
contains "$out" "High: fixture finding" "severity-tagged finding is accepted"
input_count=$(sort -u "$FAKE_INPUT_DIRS" | wc -l | tr -d ' ')
launch_count=$(cat "$FAKE_LAUNCH_COUNT")
check "$input_count" "$launch_count" "every Claude launch used a unique input directory"

echo "== A06: existing Markdown review shapes remain accepted =="
out=$(run_attested compact_finding review phase4-compact-a06 2>"$T/a06-compact.err"); rc=$?
check "$rc" "0" "H1-style finding heading remains accepted"
contains "$out" "### H1. fixture finding" "compact finding body is preserved"
out=$(run_attested short_inline_finding review phase4-short-inline-a06 2>"$T/a06-short-inline.err"); rc=$?
check "$rc" "0" "short inline finding remains accepted"
contains "$out" "High: auth fails" "short inline finding body is preserved"
out=$(run_attested short_grouped_finding review phase4-short-grouped-a06 2>"$T/a06-short-grouped.err"); rc=$?
check "$rc" "0" "short grouped finding remains accepted"
contains "$out" "保存できない" "short grouped finding body is preserved"
out=$(run_attested short_field_finding review phase4-short-field-a06 2>"$T/a06-short-field.err"); rc=$?
check "$rc" "0" "short field finding remains accepted"
contains "$out" "finding: publish path mismatch" "short field finding body is preserved"
out=$(run_attested finding_with_no_findings_reference review phase4-unquoted-reference-a06 2>"$T/a06-unquoted-reference.err"); rc=$?
check "$rc" "0" "a finding may discuss NO_FINDINGS outside a code fence"
contains "$out" "NO_FINDINGS handling" "unquoted NO_FINDINGS reference is preserved"
out=$(run_attested negative_context_finding review phase4-negative-context-a06 2>"$T/a06-negative-context.err"); rc=$?
check "$rc" "0" "a concrete failure described with no-issue wording remains accepted"
contains "$out" "authentication fails" "negative-context finding body is preserved"
out=$(run_attested hidden_failure_finding review phase4-hidden-failure-a06 2>"$T/a06-hidden-failure.err"); rc=$?
check "$rc" "0" "a hidden failure after no-issue wording remains accepted"
contains "$out" "failures remain hidden" "hidden-failure finding body is preserved"
out=$(run_attested causing_failure_finding review phase4-causing-failure-a06 2>"$T/a06-causing-failure.err"); rc=$?
check "$rc" "0" "a causing-failure clause after no-issue wording remains accepted"
contains "$out" "failures to go unnoticed" "causing-failure finding body is preserved"
out=$(run_attested http_error_finding review phase4-http-error-a06 2>"$T/a06-http-error.err"); rc=$?
check "$rc" "0" "an HTTP failure after no-error wording remains accepted"
contains "$out" "returns 500" "HTTP-error finding body is preserved"
out=$(run_attested thrown_error_finding review phase4-thrown-error-a06 2>"$T/a06-thrown-error.err"); rc=$?
check "$rc" "0" "a thrown exception after no-issue wording remains accepted"
contains "$out" "throws TypeError" "thrown-error finding body is preserved"
out=$(run_attested false_return_finding review phase4-false-return-a06 2>"$T/a06-false-return.err"); rc=$?
check "$rc" "0" "a failure return after no-error wording remains accepted"
contains "$out" "returns false" "false-return finding body is preserved"
out=$(run_attested subjectless_negation_finding review phase4-subjectless-negation-a06 2>"$T/a06-subjectless-negation.err"); rc=$?
check "$rc" "0" "a subjectless negated defect title remains accepted"
contains "$out" "Does not handle errors" "subjectless negated finding body is preserved"
out=$(run_attested grouped_subjectless_negation_finding review phase4-grouped-subjectless-negation-a06 2>"$T/a06-grouped-subjectless-negation.err"); rc=$?
check "$rc" "0" "a grouped subjectless negated defect remains accepted"
contains "$out" "Does not report failures" "grouped subjectless negated finding body is preserved"
out=$(run_attested review_subject_defect_finding review phase4-review-subject-defect-a06 2>"$T/a06-review-subject-defect.err"); rc=$?
check "$rc" "0" "a review-subject defect using a non-result verb remains accepted"
contains "$out" "Review does not handle errors" "review-subject defect body is preserved"
out=$(run_attested coordinated_negative_context_finding review phase4-coordinated-negative-context-a06 2>"$T/a06-coordinated-negative-context.err"); rc=$?
check "$rc" "0" "a concrete failure after a coordinated no-issue claim remains accepted"
contains "$out" "save loses data" "coordinated negative-context finding body is preserved"
out=$(run_attested status_context_finding review phase4-status-context-a06 2>"$T/a06-status-context.err"); rc=$?
check "$rc" "0" "status wording followed by a concrete failure remains accepted"
contains "$out" "authentication still fails" "status-context finding body is preserved"
out=$(run_attested grouped_finding review phase4-grouped-a06 2>"$T/a06-grouped.err"); rc=$?
check "$rc" "0" "severity-group heading with finding content remains accepted"
contains "$out" "## High" "grouped severity finding body is preserved"
out=$(run_attested numbered_finding review phase4-numbered-a06 2>"$T/a06-numbered.err"); rc=$?
check "$rc" "0" "numbered severity finding remains accepted"
contains "$out" "1. **High**:" "numbered severity finding body is preserved"
out=$(run_attested field_finding review phase4-field-a06 2>"$T/a06-field.err"); rc=$?
check "$rc" "0" "multi-line severity field finding remains accepted"
contains "$out" "evidence: src/example.ts:1" "multi-line severity field body is preserved"
out=$(run_attested table_finding review phase4-table-a06 2>"$T/a06-table.err"); rc=$?
check "$rc" "0" "severity/finding Markdown table remains accepted"
contains "$out" "| High | src/example.ts:1" "table finding body is preserved"
out=$(run_attested markdown_clean review phase4-markdown-clean-a06 2>"$T/a06-clean.err"); rc=$?
check "$rc" "0" "Markdown-emphasized clean result remains accepted"
contains "$out" "**NO_FINDINGS**" "Markdown clean body is preserved"
out=$(run_attested finding_with_quoted_no_findings review phase4-quoted-clean-a06 2>"$T/a06-quoted-clean.err"); rc=$?
check "$rc" "0" "severity finding may quote the NO_FINDINGS contract"
contains "$out" "High: NO_FINDINGSの判定" "finding with quoted contract is preserved"
out=$(run_attested finding_with_list_quoted_no_findings review phase4-list-quoted-clean-a06 2>"$T/a06-list-quoted-clean.err"); rc=$?
check "$rc" "0" "severity finding may quote NO_FINDINGS inside a list fence"
contains "$out" "High: fixture finding" "finding with list-nested quoted contract is preserved"
out=$(run_attested finding_with_nested_list_quoted_no_findings review phase4-nested-list-quoted-clean-a06 2>"$T/a06-nested-list-quoted-clean.err"); rc=$?
check "$rc" "0" "severity finding may quote NO_FINDINGS inside a nested list fence"
contains "$out" "High: fixture finding" "finding with nested-list quoted contract is preserved"
out=$(run_attested finding_with_parent_list_quoted_no_findings review phase4-parent-list-quoted-clean-a06 2>"$T/a06-parent-list-quoted-clean.err"); rc=$?
check "$rc" "0" "severity finding may quote NO_FINDINGS after returning to a parent list"
contains "$out" "High: fixture finding" "finding with parent-list quoted contract is preserved"
out=$(run_attested finding_with_tab_list_quoted_no_findings review phase4-tab-list-quoted-clean-a06 2>"$T/a06-tab-list-quoted-clean.err"); rc=$?
check "$rc" "0" "severity finding may quote NO_FINDINGS in a tab-indented list fence"
contains "$out" "High: fixture finding" "finding with tab-indented quoted contract is preserved"
out=$(run_attested finding_with_indented_list_quoted_no_findings review phase4-indented-list-quoted-clean-a06 2>"$T/a06-indented-list-quoted-clean.err"); rc=$?
check "$rc" "0" "severity finding may quote NO_FINDINGS in an indented list fence"
contains "$out" "High: fixture finding" "finding with indented list-nested contract is preserved"
out=$(run_attested finding_after_unclosed_list_fence review phase4-unclosed-list-a06 2>"$T/a06-unclosed-list.err"); rc=$?
check "$rc" "0" "a finding after an unclosed list fence remains visible"
contains "$out" "High: fixture finding" "finding outside the ended list container is preserved"
out=$(run_attested finding_after_invalid_backtick_info review phase4-invalid-fence-a06 2>"$T/a06-invalid-fence.err"); rc=$?
check "$rc" "0" "backtick in a backtick info string does not hide a later finding"
contains "$out" "High: fixture finding" "finding after a non-fence line is preserved"

echo "== A07: failed ownership validation never falls back to prefix-only cleanup =="
out=$(run_attested tamper_owner review phase4-owner-mismatch-a07 2>"$T/a07.err"); rc=$?
check "$rc" "0" "valid review result is not changed by deferred cleanup diagnostics"
tampered_input=$(tail -n 1 "$FAKE_INPUT_DIRS")
if [ -d "$tampered_input" ]; then
  ok "ownership-mismatched input is preserved"
else
  ng "ownership-mismatched input is preserved"
fi

echo "== A08: dollar sequences in selected paths are rendered literally =="
DOLLAR_TEMP="$T/managed-\$&-temp"
mkdir -p "$DOLLAR_TEMP"
out=$(CLAUDE_REVIEW_TEMP_ROOT="$DOLLAR_TEMP" \
  run_attested finding review phase4-dollar-path-a08 2>"$T/a08.err"); rc=$?
check "$rc" "0" "dollar-containing temporary root remains usable"
not_contains "$(cat "$FAKE_PROMPT_FILE")" "{{CLAUDE_REVIEW_DIFF}}" "dollar path cannot recreate the diff token"
not_contains "$(cat "$FAKE_PROMPT_FILE")" "{{CLAUDE_REVIEW_REPOSITORY}}" "dollar path cannot recreate the snapshot token"

echo ""
printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
exit "$fail"
