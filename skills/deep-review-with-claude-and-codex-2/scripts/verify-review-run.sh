#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONTEXT_PATH="${1:-}"
if [ -z "$CONTEXT_PATH" ] || [ ! -f "$CONTEXT_PATH" ]; then
  echo "Usage: $0 <context.json>" >&2
  exit 2
fi

value() {
  jq -er "$1" "$CONTEXT_PATH"
}

SKILL_DIR=$(value .skillDir)
TOOLING_DIGEST=$(value .toolingDigest)
DIFF_FILE=$(value .diffFile)
DIFF_SHA256=$(value .diffSha256)
SNAPSHOT_DIR=$(value .reviewSnapshotDir)
HEAD_SHA=$(value .headSha)
SNAPSHOT_DIGEST=$(value .snapshotMetadataSha256)
GUIDANCE_FILE=$(value .baseGuidancePath)
GUIDANCE_DIGEST=$(value .baseGuidanceSha256)
value '.reviewerConfig.claude.model | select(type == "string" and length > 0)' >/dev/null
value '.reviewerConfig.claude.effort | select(type == "string" and length > 0)' >/dev/null
value '.reviewerConfig.codex.model | select(type == "string" and length > 0)' >/dev/null
value '.reviewerConfig.codex.reasoningEffort | select(type == "string" and length > 0)' >/dev/null
value '.reviewerConfigSources.claude.model | select(. == "environment" or . == "config-file")' >/dev/null
value '.reviewerConfigSources.claude.effort | select(. == "environment" or . == "config-file")' >/dev/null
value '.reviewerConfigSources.codex.model | select(. == "environment" or . == "config-file")' >/dev/null
value '.reviewerConfigSources.codex.reasoningEffort | select(. == "environment" or . == "config-file")' >/dev/null

node "$SKILL_DIR/scripts/snapshot-tooling.mjs" --verify \
  --snapshot "$SKILL_DIR" --expected-digest "$TOOLING_DIGEST"
node "$SKILL_DIR/scripts/verify-review-diff.mjs" \
  --diff "$DIFF_FILE" --expected-sha256 "$DIFF_SHA256"
node "$SKILL_DIR/scripts/verify-review-snapshot.mjs" \
  --snapshot "$SNAPSHOT_DIR" --head-sha "$HEAD_SHA" \
  --expected-metadata-sha256 "$SNAPSHOT_DIGEST"

ACTUAL_GUIDANCE_DIGEST=$(node -e '
const fs = require("node:fs");
const crypto = require("node:crypto");
process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
' "$GUIDANCE_FILE")
if [ "$ACTUAL_GUIDANCE_DIGEST" != "$GUIDANCE_DIGEST" ]; then
  echo "ERROR: base guidance digest mismatch" >&2
  exit 1
fi
printf 'REVIEW_RUN_OK: %s\n' "$(value .reviewRunId)"
