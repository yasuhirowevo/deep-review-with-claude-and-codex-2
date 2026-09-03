#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmodSync,
  lstatSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { pathToFileURL } from "node:url";

import { validateOutputEvidenceFile } from "./review-output-evidence.mjs";

const FINDING_ID = /^F[1-9][0-9]*$/u;
const SEVERITIES = ["Critical", "High", "Medium", "Low"];
const OUTCOMES = new Set(["new", "duplicate", "rejected"]);
const CHANGE_ACTIONS = new Set([
  "unchanged",
  "withdrawn",
  "downgraded",
  "upgraded",
  "updated",
]);

function fail(message) {
  throw new Error(message);
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

function assertRegularFile(filePath, label, requireNonEmpty = false) {
  let stat;
  try {
    stat = lstatSync(filePath);
  } catch {
    fail(`${label} is unavailable`);
  }
  if (
    stat.isSymbolicLink() ||
    !stat.isFile() ||
    (requireNonEmpty && stat.size === 0)
  ) {
    fail(`${label} must be a regular non-symlink file`);
  }
}

function readJson(filePath, label) {
  assertRegularFile(filePath, label, true);
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    fail(`${label} is invalid JSON`);
  }
}

function meaningful(value) {
  return typeof value === "string" && value.trim().length > 0;
}

export function canonicalFindings(findings, label = "finding set") {
  if (!Array.isArray(findings)) fail(`${label} must be an array`);
  const ids = new Set();
  const normalized = findings.map((finding) => {
    if (
      !finding ||
      !FINDING_ID.test(finding.id) ||
      !SEVERITIES.includes(finding.severity) ||
      !meaningful(finding.title) ||
      ids.has(finding.id)
    ) {
      fail(`${label} contains an invalid finding`);
    }
    ids.add(finding.id);
    return {
      id: finding.id,
      severity: finding.severity,
      title: finding.title.trim(),
    };
  });
  normalized.sort(
    (left, right) => Number(left.id.slice(1)) - Number(right.id.slice(1)),
  );
  return normalized;
}

export function findingSetSha256(findings) {
  const canonical = canonicalFindings(findings, "finding set");
  return sha256(Buffer.from(`${JSON.stringify(canonical)}\n`, "utf8"));
}

function validatePairIdentity(pairStatus) {
  if (
    pairStatus?.schema !== "deep-review-pair/v6" ||
    !meaningful(pairStatus.reviewRunId) ||
    !new Set(["primary", "convergence"]).has(pairStatus.phase) ||
    (pairStatus.phase === "primary"
      ? pairStatus.round !== null
      : !Number.isInteger(pairStatus.round) || pairStatus.round < 1) ||
    pairStatus.complete !== true
  ) {
    fail("pair status is not a completed adjudication input");
  }
}

function canonicalEvidence(pairStatus, reviewer) {
  const canonical = pairStatus.canonical?.[reviewer];
  if (
    canonical?.exitCode !== 0 ||
    !Number.isInteger(canonical.attempt) ||
    !canonical.evidence ||
    !meaningful(canonical.stdout)
  ) {
    fail(`${reviewer} canonical output evidence is unavailable`);
  }
  const result = validateOutputEvidenceFile({
    evidencePath: canonical.evidence.path,
    outputPath: canonical.stdout,
    reviewer,
    phase: pairStatus.phase,
    round: pairStatus.round,
    attempt: canonical.attempt,
    receipt: canonical.evidence,
  });
  return {
    receipt: canonical.evidence,
    manifest: result.manifest,
  };
}

function inputRecord(evidence) {
  return {
    evidencePath: evidence.receipt.path,
    evidenceSha256: evidence.receipt.sha256,
    outputSha256: evidence.receipt.outputSha256,
    candidateCount: evidence.receipt.candidateCount,
  };
}

function deriveAdjudication({ pairStatus, draft, previous }) {
  validatePairIdentity(pairStatus);
  const claude = canonicalEvidence(pairStatus, "claude");
  const codex = canonicalEvidence(pairStatus, "codex");
  const before = previous
    ? canonicalFindings(previous.after?.findings, "previous final finding set")
    : [];
  if ((pairStatus.phase === "primary") !== (previous === null)) {
    fail("primary adjudication must start the chain and convergence must continue it");
  }
  if (
    previous &&
    (previous.schema !== "deep-review-adjudication/v1" ||
      previous.reviewRunId !== pairStatus.reviewRunId ||
      (previous.phase === "primary"
        ? pairStatus.round !== 1
        : previous.round + 1 !== pairStatus.round))
  ) {
    fail("previous adjudication does not precede this pair status");
  }

  const after = canonicalFindings(draft?.after, "adjudication final finding set");
  const beforeById = new Map(before.map((finding) => [finding.id, finding]));
  const afterById = new Map(after.map((finding) => [finding.id, finding]));
  const allCandidates = [...claude.manifest.candidates, ...codex.manifest.candidates];
  const candidateById = new Map(
    allCandidates.map((candidate) => [candidate.candidateId, candidate]),
  );
  if (!Array.isArray(draft?.decisions) || !Array.isArray(draft?.changes)) {
    fail("adjudication draft must contain decisions, changes, and after arrays");
  }

  const decided = new Set();
  const newFindingIds = new Set();
  const decisions = draft.decisions.map((decision) => {
    if (
      !decision ||
      !candidateById.has(decision.candidateId) ||
      decided.has(decision.candidateId) ||
      !OUTCOMES.has(decision.outcome) ||
      !meaningful(decision.rationale)
    ) {
      fail("adjudication contains an invalid or duplicate candidate decision");
    }
    decided.add(decision.candidateId);
    if (decision.outcome === "rejected") {
      if (decision.findingId !== null) {
        fail("rejected candidate must not reference a final finding");
      }
    } else if (!FINDING_ID.test(decision.findingId)) {
      fail("accepted or duplicate candidate must reference a final finding");
    } else if (decision.outcome === "new") {
      if (beforeById.has(decision.findingId) || newFindingIds.has(decision.findingId)) {
        fail("new candidate finding IDs must be new and unique");
      }
      newFindingIds.add(decision.findingId);
      const finding = afterById.get(decision.findingId);
      if (!finding) {
        fail("new candidate must reference a final finding");
      }
    }
    return {
      candidateId: decision.candidateId,
      outcome: decision.outcome,
      findingId: decision.findingId,
      rationale: decision.rationale.trim(),
    };
  });
  if (decided.size !== candidateById.size) {
    fail("every canonical reviewer candidate must be adjudicated exactly once");
  }
  for (const decision of decisions) {
    if (
      decision.outcome === "duplicate" &&
      !beforeById.has(decision.findingId) &&
      !newFindingIds.has(decision.findingId)
    ) {
      fail("duplicate candidate must reference an existing or newly accepted finding");
    }
    if (
      decision.outcome === "duplicate" &&
      !afterById.has(decision.findingId)
    ) {
      fail("duplicate candidate must reference a finding retained in the final set");
    }
  }

  const changed = new Set();
  const changes = draft.changes.map((change) => {
    if (
      !change ||
      !beforeById.has(change.findingId) ||
      changed.has(change.findingId) ||
      !CHANGE_ACTIONS.has(change.action) ||
      !meaningful(change.rationale)
    ) {
      fail("adjudication contains an invalid or duplicate prior-finding change");
    }
    changed.add(change.findingId);
    const oldFinding = beforeById.get(change.findingId);
    const newFinding = afterById.get(change.findingId);
    if (change.action === "withdrawn") {
      if (newFinding) fail("withdrawn finding must be absent from the final set");
    } else {
      if (!newFinding) {
        fail("retained finding must preserve its identity");
      }
      const oldRank = SEVERITIES.indexOf(oldFinding.severity);
      const newRank = SEVERITIES.indexOf(newFinding.severity);
      if (
        (change.action === "unchanged" && newRank !== oldRank) ||
        (change.action === "downgraded" && newRank <= oldRank) ||
        (change.action === "upgraded" && newRank >= oldRank) ||
        (change.action === "updated" &&
          (newRank !== oldRank || newFinding.title === oldFinding.title)) ||
        (change.action === "unchanged" && newFinding.title !== oldFinding.title)
      ) {
        fail("prior-finding change does not match its severity transition");
      }
    }
    return {
      findingId: change.findingId,
      action: change.action,
      rationale: change.rationale.trim(),
    };
  });
  if (changed.size !== beforeById.size) {
    fail("every prior final finding must have exactly one change decision");
  }
  for (const finding of after) {
    if (!beforeById.has(finding.id) && !newFindingIds.has(finding.id)) {
      fail("final finding set contains a finding with no adjudication source");
    }
  }

  const candidateReviewer = (candidateId) =>
    candidateId.startsWith("claude-") ? "claude" : "codex";
  const count = (items, predicate) => items.filter(predicate).length;
  const summary = {
    claudeNew: count(
      decisions,
      (decision) =>
        candidateReviewer(decision.candidateId) === "claude" &&
        decision.outcome === "new",
    ),
    codexNew: count(
      decisions,
      (decision) =>
        candidateReviewer(decision.candidateId) === "codex" &&
        decision.outcome === "new",
    ),
    duplicates: count(decisions, (decision) => decision.outcome === "duplicate"),
    rejected: count(decisions, (decision) => decision.outcome === "rejected"),
    withdrawn: count(changes, (change) => change.action === "withdrawn"),
    downgraded: count(changes, (change) => change.action === "downgraded"),
    upgraded: count(changes, (change) => change.action === "upgraded"),
    unchanged: count(changes, (change) => change.action === "unchanged"),
    updated: count(changes, (change) => change.action === "updated"),
    finalSetChanged: !isDeepStrictEqual(before, after),
  };
  return {
    schema: "deep-review-adjudication/v1",
    reviewRunId: pairStatus.reviewRunId,
    phase: pairStatus.phase,
    round: pairStatus.round,
    inputs: {
      claude: inputRecord(claude),
      codex: inputRecord(codex),
    },
    before: { sha256: findingSetSha256(before), findings: before },
    decisions,
    changes,
    after: { sha256: findingSetSha256(after), findings: after },
    summary,
  };
}

export function createAdjudication({ pairStatusPath, draftPath, outputPath, previousPath }) {
  const pairStatus = readJson(pairStatusPath, "pair status");
  const draft = readJson(draftPath, "adjudication draft");
  const previous = previousPath
    ? readJson(previousPath, "previous adjudication")
    : null;
  const result = deriveAdjudication({ pairStatus, draft, previous });
  const serialized = `${JSON.stringify(result, null, 2)}\n`;
  writeFileSync(outputPath, serialized, { flag: "wx", mode: 0o600 });
  chmodSync(outputPath, 0o600);
  return result;
}

export function validateAdjudicationFile({ adjudicationPath, pairStatus, previous }) {
  const actual = readJson(adjudicationPath, "adjudication artifact");
  const draft = {
    decisions: actual.decisions,
    changes: actual.changes,
    after: actual.after?.findings,
  };
  const expected = deriveAdjudication({ pairStatus, draft, previous });
  if (!isDeepStrictEqual(actual, expected)) {
    fail("adjudication artifact contains non-derived or inconsistent data");
  }
  return actual;
}

function parseArgs(argv) {
  const allowed = new Map([
    ["--pair-status", "pairStatusPath"],
    ["--draft", "draftPath"],
    ["--output", "outputPath"],
    ["--previous", "previousPath"],
  ]);
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = allowed.get(argv[index]);
    const value = argv[index + 1];
    if (!key || value === undefined || parsed[key] !== undefined) {
      fail(`invalid argument: ${argv[index]}`);
    }
    parsed[key] = value;
  }
  for (const key of ["pairStatusPath", "draftPath", "outputPath"]) {
    if (!parsed[key]) fail(`missing required argument: ${key}`);
  }
  return parsed;
}

const invokedPath = process.argv[1];
if (
  invokedPath &&
  import.meta.url === pathToFileURL(path.resolve(invokedPath)).href
) {
  try {
    const result = createAdjudication(parseArgs(process.argv.slice(2)));
    process.stdout.write(
      `ADJUDICATION_OK: ${JSON.stringify({
        beforeSha256: result.before.sha256,
        afterSha256: result.after.sha256,
        summary: result.summary,
      })}\n`,
    );
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
