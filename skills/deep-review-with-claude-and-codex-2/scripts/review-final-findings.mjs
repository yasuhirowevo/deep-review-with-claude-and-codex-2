#!/usr/bin/env node

import {
  chmodSync,
  lstatSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { isDeepStrictEqual } from "node:util";
import path from "node:path";
import { pathToFileURL } from "node:url";

import {
  canonicalFindings,
  findingSetSha256,
} from "./review-adjudication.mjs";
import {
  PR_CONTEXT_SOURCES,
  derivePrEvidence,
  indexPrContextRecords,
  jsonSha256,
  readPrReviewContextArtifacts,
} from "./review-pr-context.mjs";

const OUTCOMES = new Set([
  "addressed",
  "dismissed-valid",
  "dismissed-but-rechallenge",
  "not-judged",
]);
const RETAINED_OUTCOMES = new Set([
  "dismissed-but-rechallenge",
  "not-judged",
]);
export const HANDLING_LABELS = Object.freeze({
  "this-pr-candidate": "このPRでの対応候補",
  "user-decision": "ユーザー判断が必要",
  "additional-verification": "追加確認が必要",
  "separate-issue": "別Issue候補",
  accepted: "受容済み・見送り済み",
  addressed: "対応済み",
});
const HANDLINGS = new Set(Object.keys(HANDLING_LABELS));
const HANDLINGS_BY_OUTCOME = Object.freeze({
  addressed: new Set(["addressed"]),
  "dismissed-valid": new Set(["accepted", "separate-issue"]),
  "dismissed-but-rechallenge": new Set([
    "this-pr-candidate",
    "user-decision",
    "additional-verification",
    "separate-issue",
  ]),
  "not-judged": new Set([
    "this-pr-candidate",
    "user-decision",
    "additional-verification",
    "separate-issue",
  ]),
});
export const RECHALLENGE_EVIDENCE_LABELS = Object.freeze({
  "relevant-head-change": "関連コード変更",
  "new-reproduction": "新しい再現・実測",
  "prior-rationale-error": "以前の根拠の事実誤認",
  "user-scope-change": "ユーザーによるスコープ変更",
});
const RECHALLENGE_EVIDENCE_KINDS = new Set(
  Object.keys(RECHALLENGE_EVIDENCE_LABELS),
);
const SHA256_PATTERN = /^[0-9a-f]{64}$/u;

function fail(message) {
  throw new Error(message);
}

function meaningful(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function singleLine(value, label) {
  if (!meaningful(value) || /[\r\n]/u.test(value)) {
    fail(`${label} must be one non-empty line`);
  }
  return value.trim();
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

function validateInputs(
  context,
  adjudication,
  prReviewContext,
  prReviewContextReceipt,
) {
  if (
    !context ||
    !meaningful(context.reviewRunId) ||
    !new Set(["pr", "branch"]).has(context.reviewMode)
  ) {
    fail("review context identity is invalid");
  }
  if (
    adjudication?.schema !== "deep-review-adjudication/v1" ||
    adjudication.reviewRunId !== context.reviewRunId
  ) {
    fail("final adjudication identity does not match the review context");
  }
  const phase4Findings = canonicalFindings(
    adjudication.after?.findings,
    "Phase 4 final finding set",
  );
  if (adjudication.after?.sha256 !== findingSetSha256(phase4Findings)) {
    fail("Phase 4 final finding-set digest is invalid");
  }

  if (context.reviewMode === "branch") {
    if (prReviewContext !== null || prReviewContextReceipt !== null) {
      fail("branch finalization must not use PR review context");
    }
    return { phase4Findings, prRecordIndex: null };
  }
  if (
    prReviewContext?.schema !== "deep-review-pr-review-context/v1" ||
    prReviewContext.snapshotRole !== "final" ||
    !SHA256_PATTERN.test(prReviewContext.supersedesSha256) ||
    prReviewContext.reviewRunId !== context.reviewRunId ||
    prReviewContext.repositoryHost !== context.repositoryHost ||
    prReviewContext.repository !== context.repository ||
    String(prReviewContext.prNumber) !== String(context.prNumber) ||
    prReviewContext.expectedHeadSha !== context.headSha ||
    !new Set(["checked", "not-checked"]).has(prReviewContext.status)
  ) {
    fail("PR review context identity does not match the review context");
  }
  if (
    prReviewContextReceipt?.schema !==
      "deep-review-pr-review-context-receipt/v1" ||
    !SHA256_PATTERN.test(prReviewContextReceipt.sha256) ||
    prReviewContextReceipt.reviewRunId !== prReviewContext.reviewRunId ||
    prReviewContextReceipt.repositoryHost !== prReviewContext.repositoryHost ||
    prReviewContextReceipt.repository !== prReviewContext.repository ||
    prReviewContextReceipt.prNumber !== prReviewContext.prNumber ||
    prReviewContextReceipt.expectedHeadSha !== prReviewContext.expectedHeadSha ||
    prReviewContextReceipt.snapshotRole !== prReviewContext.snapshotRole ||
    prReviewContextReceipt.supersedesSha256 !==
      prReviewContext.supersedesSha256 ||
    prReviewContextReceipt.status !== prReviewContext.status
  ) {
    fail("PR review context receipt does not match the final snapshot");
  }
  return {
    phase4Findings,
    prRecordIndex: indexPrContextRecords(prReviewContext),
  };
}

function normalizeEvidence(evidence, prRecordIndex) {
  if (!Array.isArray(evidence)) {
    fail("Phase 5 decision evidence must be an array");
  }
  const seen = new Set();
  return evidence.map((item) => {
    if (
      !item ||
      !PR_CONTEXT_SOURCES.includes(item.source) ||
      !meaningful(item.stableId)
    ) {
      fail("Phase 5 decision contains invalid PR comment evidence");
    }
    const key = `${item.source}\u0000${item.stableId}`;
    if (seen.has(key)) {
      fail("Phase 5 decision contains duplicate PR comment evidence");
    }
    seen.add(key);
    return derivePrEvidence(prRecordIndex, item.source, item.stableId);
  });
}

function normalizeHandling(decision) {
  if (
    !HANDLINGS.has(decision.handling) ||
    !HANDLINGS_BY_OUTCOME[decision.outcome].has(decision.handling) ||
    !meaningful(decision.handlingRationale)
  ) {
    fail("Phase 5 decision contains an invalid handling or handling rationale");
  }
  let userDecisionRequest;
  let userDecisionImpact;
  if (decision.handling === "user-decision") {
    if (
      !meaningful(decision.userDecisionRequest) ||
      !meaningful(decision.userDecisionImpact)
    ) {
      fail(
        "user-decision handling requires a concrete question and decision impact",
      );
    }
    userDecisionRequest = singleLine(
      decision.userDecisionRequest,
      "userDecisionRequest",
    );
    userDecisionImpact = singleLine(
      decision.userDecisionImpact,
      "userDecisionImpact",
    );
  } else if (
    decision.userDecisionRequest !== undefined ||
    decision.userDecisionImpact !== undefined
  ) {
    fail(
      "only user-decision handling may contain userDecisionRequest or userDecisionImpact",
    );
  }

  let verificationRequest;
  if (decision.handling === "additional-verification") {
    if (!meaningful(decision.verificationRequest)) {
      fail(
        "additional-verification handling requires a concrete verification request",
      );
    }
    verificationRequest = singleLine(
      decision.verificationRequest,
      "verificationRequest",
    );
  } else if (decision.verificationRequest !== undefined) {
    fail(
      "only additional-verification handling may contain verificationRequest",
    );
  }

  let rechallengeEvidence;
  if (decision.outcome === "dismissed-but-rechallenge") {
    if (
      !decision.rechallengeEvidence ||
      !RECHALLENGE_EVIDENCE_KINDS.has(
        decision.rechallengeEvidence.kind,
      ) ||
      !meaningful(decision.rechallengeEvidence.detail)
    ) {
      fail(
        "rechallenging a prior decision requires a permitted new evidence kind and detail",
      );
    }
    rechallengeEvidence = {
      kind: decision.rechallengeEvidence.kind,
      kindLabel:
        RECHALLENGE_EVIDENCE_LABELS[decision.rechallengeEvidence.kind],
      detail: singleLine(
        decision.rechallengeEvidence.detail,
        "rechallengeEvidence.detail",
      ),
    };
  } else if (decision.rechallengeEvidence !== undefined) {
    fail(
      "rechallengeEvidence is only valid for dismissed-but-rechallenge",
    );
  }
  return {
    handling: decision.handling,
    handlingLabel: HANDLING_LABELS[decision.handling],
    handlingRationale: singleLine(
      decision.handlingRationale,
      "handlingRationale",
    ),
    ...(userDecisionRequest === undefined ? {} : { userDecisionRequest }),
    ...(userDecisionImpact === undefined ? {} : { userDecisionImpact }),
    ...(verificationRequest === undefined ? {} : { verificationRequest }),
    ...(rechallengeEvidence === undefined ? {} : { rechallengeEvidence }),
  };
}

function deriveFinalFindingSet({
  context,
  adjudication,
  prReviewContext,
  prReviewContextReceipt,
  draft,
}) {
  const { phase4Findings, prRecordIndex } = validateInputs(
    context,
    adjudication,
    prReviewContext,
    prReviewContextReceipt,
  );
  if (!Array.isArray(draft?.decisions)) {
    fail("Phase 5 draft decisions must be an array");
  }
  const phase4ById = new Map(
    phase4Findings.map((finding) => [finding.id, finding]),
  );
  const decided = new Set();
  const decisions = draft.decisions.map((decision) => {
    if (
      !decision ||
      !phase4ById.has(decision.findingId) ||
      decided.has(decision.findingId) ||
      !OUTCOMES.has(decision.outcome) ||
      !meaningful(decision.rationale)
    ) {
      fail("Phase 5 draft contains an invalid or duplicate finding decision");
    }
    decided.add(decision.findingId);
    const evidence = normalizeEvidence(decision.evidence, prRecordIndex);
    const mayUsePrJudgment =
      context.reviewMode === "pr" && prReviewContext.status === "checked";
    if (decision.outcome === "not-judged") {
      if (evidence.length !== 0) {
        fail("not-judged finding must not claim PR comment evidence");
      }
    } else if (!mayUsePrJudgment || evidence.length === 0) {
      fail("PR comment judgment requires checked evidence");
    }
    const handling = normalizeHandling(decision);
    return {
      findingId: decision.findingId,
      outcome: decision.outcome,
      evidence,
      rationale: decision.rationale.trim(),
      ...handling,
    };
  });
  if (decided.size !== phase4ById.size) {
    fail("every Phase 4 finding must have exactly one Phase 5 decision");
  }
  decisions.sort(
    (left, right) =>
      Number(left.findingId.slice(1)) - Number(right.findingId.slice(1)),
  );

  const retainedIds = new Set(
    decisions
      .filter((decision) => RETAINED_OUTCOMES.has(decision.outcome))
      .map((decision) => decision.findingId),
  );
  const finalFindings = phase4Findings.filter((finding) =>
    retainedIds.has(finding.id),
  );
  const count = (outcome) =>
    decisions.filter((decision) => decision.outcome === outcome).length;
  const summary = {
    phase4: phase4Findings.length,
    addressed: count("addressed"),
    dismissedValid: count("dismissed-valid"),
    dismissedButRechallenge: count("dismissed-but-rechallenge"),
    notJudged: count("not-judged"),
    excluded: decisions.filter(
      (decision) => !RETAINED_OUTCOMES.has(decision.outcome),
    ).length,
    retained: finalFindings.length,
    final: finalFindings.length,
    handling: Object.fromEntries(
      Object.keys(HANDLING_LABELS).map((handling) => [
        handling,
        decisions.filter((decision) => decision.handling === handling).length,
      ]),
    ),
  };
  return {
    schema:
      context.reviewMode === "pr"
        ? "deep-review-final-findings/v3"
        : "deep-review-final-findings/v2",
    reviewRunId: context.reviewRunId,
    reviewMode: context.reviewMode,
    inputs: {
      phase4FindingSetSha256: adjudication.after.sha256,
      prReviewContext:
        context.reviewMode === "pr"
          ? {
              status: prReviewContext.status,
              expectedHeadSha: prReviewContext.expectedHeadSha,
              sha256: prReviewContextReceipt.sha256,
              receiptSha256: jsonSha256(prReviewContextReceipt),
            }
          : null,
    },
    decisions,
    handling: {
      sha256: jsonSha256(decisions),
      labels: HANDLING_LABELS,
      counts: summary.handling,
    },
    final: {
      sha256: findingSetSha256(finalFindings),
      findings: finalFindings,
    },
    summary,
  };
}

export function createFinalFindingSet({
  contextPath,
  adjudicationPath,
  prReviewContextPath,
  draftPath,
  outputPath,
}) {
  const context = readJson(contextPath, "review context");
  const adjudication = readJson(adjudicationPath, "final adjudication");
  const prReviewArtifacts = prReviewContextPath
    ? readPrReviewContextArtifacts(prReviewContextPath)
    : null;
  const prReviewContext = prReviewArtifacts?.reviewContext ?? null;
  const prReviewContextReceipt = prReviewArtifacts?.receipt ?? null;
  const draft = readJson(draftPath, "Phase 5 draft");
  const result = deriveFinalFindingSet({
    context,
    adjudication,
    prReviewContext,
    prReviewContextReceipt,
    draft,
  });
  writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  chmodSync(outputPath, 0o600);
  return result;
}

export function validateFinalFindingSetFile({
  finalFindingSetPath,
  context,
  adjudication,
  prReviewContext,
  prReviewContextReceipt,
}) {
  const actual = readJson(finalFindingSetPath, "final finding-set artifact");
  const expected = deriveFinalFindingSet({
    context,
    adjudication,
    prReviewContext,
    prReviewContextReceipt,
    draft: { decisions: actual.decisions },
  });
  if (!isDeepStrictEqual(actual, expected)) {
    fail("final finding-set artifact contains non-derived or inconsistent data");
  }
  return actual;
}

function parseArgs(argv) {
  const allowed = new Map([
    ["--context", "contextPath"],
    ["--adjudication", "adjudicationPath"],
    ["--pr-review-context", "prReviewContextPath"],
    ["--draft", "draftPath"],
    ["--output", "outputPath"],
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
  for (const key of [
    "contextPath",
    "adjudicationPath",
    "draftPath",
    "outputPath",
  ]) {
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
    const result = createFinalFindingSet(parseArgs(process.argv.slice(2)));
    process.stdout.write(
      `FINAL_FINDINGS_OK: ${JSON.stringify({
        finalSha256: result.final.sha256,
        summary: result.summary,
      })}\n`,
    );
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
