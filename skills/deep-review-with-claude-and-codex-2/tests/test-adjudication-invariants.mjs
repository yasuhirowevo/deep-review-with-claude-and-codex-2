#!/usr/bin/env node

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

import { createAdjudication } from "../scripts/review-adjudication.mjs";
import { createOutputEvidence } from "../scripts/review-output-evidence.mjs";
import { toBashAbsolutePath } from "../scripts/path-interop.mjs";

const tempRoot = mkdtempSync(path.join(os.tmpdir(), "deep-review-adjudication-"));
const reviewRunId = "11111111-1111-4111-8111-111111111111";
const originalFinding = {
  id: "F1",
  severity: "Medium",
  title: "retained finding",
};
let pass = 0;
let fail = 0;

function ok(label) {
  process.stdout.write(`  PASS: ${label}\n`);
  pass += 1;
}

function ng(label, detail) {
  process.stdout.write(`  FAIL: ${label}${detail ? ` (${detail})` : ""}\n`);
  fail += 1;
}

function writeJson(filePath, value) {
  writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function duplicateDecisions(findingId) {
  return ["claude", "codex"].map((reviewer) => ({
    candidateId: `${reviewer}-F001`,
    outcome: "duplicate",
    findingId,
    rationale: "same reported issue",
  }));
}

function runCase(name, draft) {
  const draftPath = path.join(tempRoot, `${name}.draft.json`);
  const outputPath = path.join(tempRoot, `${name}.adjudication.json`);
  writeJson(draftPath, draft);
  return () =>
    createAdjudication({
      pairStatusPath,
      draftPath,
      outputPath,
      previousPath,
    });
}

function expectPass(name, label, draft) {
  try {
    runCase(name, draft)();
    ok(label);
  } catch (error) {
    ng(label, error.message);
  }
}

function expectFail(name, label, expectedMessage, draft) {
  try {
    runCase(name, draft)();
    ng(label, "unexpectedly accepted");
  } catch (error) {
    if (error.message === expectedMessage) ok(label);
    else ng(label, `unexpected error: ${error.message}`);
  }
}

let pairStatusPath;
let previousPath;

try {
  const canonical = {};
  for (const reviewer of ["claude", "codex"]) {
    const outputPath = path.join(tempRoot, `${reviewer}.out`);
    const evidencePath = path.join(tempRoot, `${reviewer}.evidence.json`);
    writeFileSync(outputPath, `${reviewer}\n---\nMedium: repeated finding\n`, "utf8");
    const evidence = createOutputEvidence({
      inputPath: outputPath,
      outputPath: evidencePath,
      reviewer,
      phase: "convergence",
      round: 1,
      attempt: 1,
    });
    canonical[reviewer] = {
      exitCode: 0,
      attempt: 1,
      stdout: outputPath,
      evidence,
    };
  }

  pairStatusPath = path.join(tempRoot, "pair-status.json");
  previousPath = path.join(tempRoot, "previous.json");
  writeJson(pairStatusPath, {
    schema: "deep-review-pair/v6",
    reviewRunId,
    phase: "convergence",
    round: 1,
    complete: true,
    canonical,
  });
  writeJson(previousPath, {
    schema: "deep-review-adjudication/v1",
    reviewRunId,
    phase: "primary",
    round: null,
    after: { findings: [originalFinding] },
  });

  if (process.platform === "win32") {
    process.stdout.write(
      "== AI00: Windows adjudication accepts MSYS paths from pair status ==\n",
    );
    const nativePairStatusPath = pairStatusPath;
    const portableCanonical = structuredClone(canonical);
    for (const reviewer of ["claude", "codex"]) {
      portableCanonical[reviewer].stdout = toBashAbsolutePath(
        portableCanonical[reviewer].stdout,
      );
      portableCanonical[reviewer].evidence.path = toBashAbsolutePath(
        portableCanonical[reviewer].evidence.path,
      );
    }
    pairStatusPath = path.join(tempRoot, "pair-status-msys.json");
    writeJson(pairStatusPath, {
      schema: "deep-review-pair/v6",
      reviewRunId,
      phase: "convergence",
      round: 1,
      complete: true,
      canonical: portableCanonical,
    });
    expectPass("windows-msys", "MSYS artifact paths resolve with Windows Node", {
      decisions: duplicateDecisions("F1"),
      changes: [
        { findingId: "F1", action: "unchanged", rationale: "still applies" },
      ],
      after: [originalFinding],
    });
    pairStatusPath = nativePairStatusPath;
  }

  process.stdout.write("== AI01: duplicate targets survive the round ==\n");
  expectPass("unchanged", "duplicate target may remain unchanged", {
    decisions: duplicateDecisions("F1"),
    changes: [
      { findingId: "F1", action: "unchanged", rationale: "still applies" },
    ],
    after: [originalFinding],
  });
  expectPass("updated", "duplicate target may update its title", {
    decisions: duplicateDecisions("F1"),
    changes: [
      { findingId: "F1", action: "updated", rationale: "clearer title" },
    ],
    after: [{ ...originalFinding, title: "updated finding" }],
  });
  expectPass("upgraded", "duplicate target may change severity", {
    decisions: duplicateDecisions("F1"),
    changes: [
      { findingId: "F1", action: "upgraded", rationale: "wider impact" },
    ],
    after: [{ ...originalFinding, severity: "High" }],
  });

  process.stdout.write("== AI02: duplicates may target a new surviving finding ==\n");
  expectPass("new-target", "same-round duplicate may target a new finding", {
    decisions: [
      {
        candidateId: "claude-F001",
        outcome: "new",
        findingId: "F2",
        rationale: "new canonical finding",
      },
      ...duplicateDecisions("F2").slice(1),
    ],
    changes: [
      { findingId: "F1", action: "unchanged", rationale: "still applies" },
    ],
    after: [originalFinding, { id: "F2", severity: "Medium", title: "new finding" }],
  });
  expectPass("replacement", "withdrawn finding may be replaced by a new target", {
    decisions: [
      {
        candidateId: "claude-F001",
        outcome: "new",
        findingId: "F2",
        rationale: "replacement finding",
      },
      ...duplicateDecisions("F2").slice(1),
    ],
    changes: [
      { findingId: "F1", action: "withdrawn", rationale: "replaced by F2" },
    ],
    after: [{ id: "F2", severity: "Medium", title: "replacement finding" }],
  });

  process.stdout.write("== AI03: a withdrawn finding cannot absorb duplicates ==\n");
  expectFail(
    "withdrawn-target",
    "same-round duplicate and withdrawal is rejected",
    "duplicate candidate must reference a finding retained in the final set",
    {
      decisions: duplicateDecisions("F1"),
      changes: [
        { findingId: "F1", action: "withdrawn", rationale: "no longer applies" },
      ],
      after: [],
    },
  );
} finally {
  rmSync(tempRoot, { recursive: true, force: true, maxRetries: 3 });
}

process.stdout.write(`\nRESULT: pass=${pass} fail=${fail}\n`);
process.exitCode = fail === 0 ? 0 : 1;
