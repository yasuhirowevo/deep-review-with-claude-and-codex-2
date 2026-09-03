#!/usr/bin/env node

import assert from "node:assert/strict";

import { extractReviewCandidates } from "../scripts/review-output-evidence.mjs";
import { verifyReviewBody } from "../scripts/verify-claude-review-output.mjs";

let pass = 0;
let fail = 0;

function ok(label) {
  process.stdout.write(`  PASS: ${label}\n`);
  pass += 1;
}

function ng(label, detail) {
  process.stdout.write(`  FAIL: ${label} (${detail})\n`);
  fail += 1;
}

function evidenceShape(candidates) {
  return candidates.map(({ severity, title, sourceLine }) => ({
    severity,
    title,
    sourceLine,
  }));
}

function expectAccepted(label, body, expected) {
  try {
    for (const reviewer of ["claude", "codex"]) {
      const verified = verifyReviewBody(body, reviewer);
      const extracted = evidenceShape(
        extractReviewCandidates(body, reviewer),
      );
      assert.deepEqual(verified.candidates, expected);
      assert.deepEqual(extracted, expected);
    }
    ok(label);
  } catch (error) {
    ng(label, error.message);
  }
}

function expectRejected(label, body, expectedMessage) {
  try {
    for (const reviewer of ["claude", "codex"]) {
      const reviewerMessage = expectedMessage.replace(/^claude/u, reviewer);
      assert.throws(
        () => verifyReviewBody(body, reviewer),
        (error) => error.message === reviewerMessage,
      );
      assert.throws(
        () => extractReviewCandidates(body, reviewer),
        (error) => error.message === reviewerMessage,
      );
    }
    ok(label);
  } catch (error) {
    ng(label, error.message);
  }
}

process.stdout.write("== FP01: verifier and evidence share accepted finding forms ==\n");
expectAccepted("inline finding remains accepted", "High: inline finding", [
  { severity: "High", title: "inline finding", sourceLine: 1 },
]);
expectAccepted(
  "field finding remains accepted",
  "### finding\n- severity: high\n- evidence: src/example.ts:1 accepts an invalid value",
  [
    {
      severity: "High",
      title: "src/example.ts:1 accepts an invalid value",
      sourceLine: 3,
    },
  ],
);
expectAccepted(
  "bold Markdown table remains accepted and extractable",
  "| **Severity** | **Finding** |\n| --- | --- |\n| **High** | **table finding** |",
  [{ severity: "High", title: "table finding", sourceLine: 3 }],
);

process.stdout.write("== FP02: grouped findings keep nested detail in their parent ==\n");
expectAccepted(
  "one grouped finding does not expand nested fields",
  "## High\n- save loses the selected value\n  - location: src/save.ts:10\n  - impact: the update disappears",
  [{ severity: "High", title: "save loses the selected value", sourceLine: 2 }],
);
expectAccepted(
  "nested severity fields stay inside their grouped finding",
  "## High\n- save loses value\n  - severity: high\n  - evidence: src/save.ts:1 drops data",
  [{ severity: "High", title: "save loses value", sourceLine: 2 }],
);
expectAccepted(
  "multiple top-level grouped findings remain distinct",
  "## Medium\n- first grouped finding\n  - location: src/first.ts:1\n- second grouped finding\n  - impact: retry stops",
  [
    { severity: "Medium", title: "first grouped finding", sourceLine: 2 },
    { severity: "Medium", title: "second grouped finding", sourceLine: 4 },
  ],
);
expectAccepted(
  "top-level list indentation may vary without promoting nested detail",
  "## Medium\n- first grouped finding\n - second grouped finding\n  - impact: nested detail",
  [
    { severity: "Medium", title: "first grouped finding", sourceLine: 2 },
    { severity: "Medium", title: "second grouped finding", sourceLine: 3 },
  ],
);
expectAccepted(
  "finding headings own their following detail lists",
  "## High\n### First heading finding\n- location: src/first.ts:1\n### Second heading finding\n- impact: retry stops",
  [
    { severity: "High", title: "First heading finding", sourceLine: 2 },
    { severity: "High", title: "Second heading finding", sourceLine: 4 },
  ],
);
expectAccepted(
  "a details subheading does not reopen a grouped finding list",
  "## High\n- grouped finding\n### Details\n- location: src/example.ts:1\n- impact: save stops",
  [{ severity: "High", title: "grouped finding", sourceLine: 2 }],
);
expectAccepted(
  "a shallower heading closes heading-style grouped findings",
  "# Medium\n### grouped heading finding\n- location: src/example.ts:1\n## Notes\n### unrelated heading",
  [
    {
      severity: "Medium",
      title: "grouped heading finding",
      sourceLine: 2,
    },
  ],
);

process.stdout.write("== FP03: mixed forms and clean results stay deterministic ==\n");
expectAccepted(
  "mixed accepted forms preserve candidate order and count",
  "High: inline finding\n\n## Medium\n- grouped finding one\n- grouped finding two\n\n| Severity | Finding |\n|---|---|\n| Low | table finding |",
  [
    { severity: "High", title: "inline finding", sourceLine: 1 },
    { severity: "Medium", title: "grouped finding one", sourceLine: 4 },
    { severity: "Medium", title: "grouped finding two", sourceLine: 5 },
    { severity: "Low", title: "table finding", sourceLine: 9 },
  ],
);
expectAccepted(
  "existing parser-category ordering remains stable",
  "severity: medium: field finding\nHigh: inline finding",
  [
    { severity: "High", title: "inline finding", sourceLine: 2 },
    { severity: "Medium", title: "field finding", sourceLine: 1 },
  ],
);
expectAccepted(
  "a grouped block does not hide following independent formats",
  "## High\n- grouped finding\nLow: following inline finding\nseverity: medium: following field finding",
  [
    { severity: "Low", title: "following inline finding", sourceLine: 3 },
    {
      severity: "Medium",
      title: "following field finding",
      sourceLine: 4,
    },
    { severity: "High", title: "grouped finding", sourceLine: 2 },
  ],
);
expectAccepted(
  "a plain severity group closes before a following Markdown section",
  "**High**\n- grouped finding\n## Notes\nLow: independent inline finding\nseverity: medium: independent field finding\n| Severity | Finding |\n|---|---|\n| Low | independent table finding |",
  [
    { severity: "Low", title: "independent inline finding", sourceLine: 4 },
    {
      severity: "Medium",
      title: "independent field finding",
      sourceLine: 5,
    },
    { severity: "High", title: "grouped finding", sourceLine: 2 },
    { severity: "Low", title: "independent table finding", sourceLine: 8 },
  ],
);
expectAccepted(
  "a heading-style plain group closes before a shallower section",
  "**High**\n## grouped heading finding\n- location: src/grouped.ts:1\n# Additional findings\nLow: independent inline finding\nseverity: medium: independent field finding\n| Severity | Finding |\n|---|---|\n| Low | independent table finding |",
  [
    { severity: "Low", title: "independent inline finding", sourceLine: 5 },
    {
      severity: "Medium",
      title: "independent field finding",
      sourceLine: 6,
    },
    {
      severity: "High",
      title: "grouped heading finding",
      sourceLine: 2,
    },
    { severity: "Low", title: "independent table finding", sourceLine: 9 },
  ],
);
expectAccepted(
  "repeated titles on distinct lines remain distinct",
  "High: repeated finding\nHigh: repeated finding",
  [
    { severity: "High", title: "repeated finding", sourceLine: 1 },
    { severity: "High", title: "repeated finding", sourceLine: 2 },
  ],
);
expectAccepted(
  "NO_FINDINGS with scope and reason remains accepted",
  "NO_FINDINGS\nscope: fixed diff and HEAD snapshot\nreason: no actionable issue",
  [],
);

process.stdout.write("== FP04: contradictory result contracts fail consistently ==\n");
expectRejected(
  "NO_FINDINGS cannot coexist with a finding",
  "High: contradictory finding\nNO_FINDINGS\nscope: fixed diff and HEAD snapshot\nreason: no other issue",
  "claude output cannot contain both NO_FINDINGS and findings",
);
expectRejected(
  "NO_FINDINGS still requires scope and reason",
  "NO_FINDINGS\nscope: fixed diff and HEAD snapshot",
  "claude NO_FINDINGS body must include scope + reason",
);

process.stdout.write(`\nRESULT: pass=${pass} fail=${fail}\n`);
process.exitCode = fail === 0 ? 0 : 1;
