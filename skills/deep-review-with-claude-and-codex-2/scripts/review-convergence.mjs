#!/usr/bin/env node

import {
  lstatSync,
  readFileSync,
  realpathSync,
} from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { getAdjudicationReviewers, getEnabledReviewers } from "./reviewer-selection.mjs";

function fail(message) {
  throw new Error(message);
}

export function isStableRound(adjudication) {
  const summary = adjudication?.summary;
  let reviewers;
  try {
    reviewers = getAdjudicationReviewers(adjudication);
  } catch {
    return false;
  }
  return (
    summary?.reviewersSucceeded !== false &&
    ["claude", "codex"].every((reviewer) =>
      summary?.[`${reviewer}New`] === (reviewers.includes(reviewer) ? 0 : null),
    ) &&
    summary?.withdrawn === 0 &&
    summary?.downgraded === 0 &&
    summary?.upgraded === 0 &&
    summary?.finalSetChanged === false
  );
}

function assertReviewerSelection(adjudications, expectedReviewers) {
  const reviewers = expectedReviewers ?? (
    adjudications.length ? getAdjudicationReviewers(adjudications[0]) : null
  );
  if (adjudications.some((adjudication) =>
    !isDeepStrictEqual(getAdjudicationReviewers(adjudication), reviewers),
  )) {
    fail("convergence adjudication reviewer selection does not match the run");
  }
}

export function firstConvergenceEndIndex(adjudications) {
  assertReviewerSelection(adjudications);
  for (let index = 1; index < adjudications.length; index += 1) {
    if (
      isStableRound(adjudications[index - 1]) &&
      isStableRound(adjudications[index])
    ) {
      return index;
    }
  }
  return -1;
}

export function stableTailLength(adjudications) {
  assertReviewerSelection(adjudications);
  let stableTail = 0;
  for (const adjudication of adjudications) {
    stableTail = isStableRound(adjudication) ? stableTail + 1 : 0;
  }
  return stableTail;
}

function readPriorAdjudication({
  phase4Directory,
  phase4Real,
  reviewRunId,
  round,
}) {
  const roundDirectory = path.join(phase4Directory, `round-${round}`);
  let roundStat;
  try {
    roundStat = lstatSync(roundDirectory);
  } catch (error) {
    if (error?.code === "ENOENT") {
      fail(`previous convergence round ${round} is missing`);
    }
    throw error;
  }
  if (roundStat.isSymbolicLink() || !roundStat.isDirectory()) {
    fail(`unsafe convergence round directory: ${roundDirectory}`);
  }
  const adjudicationPath = path.join(roundDirectory, "adjudication.json");
  let adjudicationStat;
  try {
    adjudicationStat = lstatSync(adjudicationPath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      fail(`previous convergence adjudication is missing for round ${round}`);
    }
    throw error;
  }
  if (adjudicationStat.isSymbolicLink() || !adjudicationStat.isFile()) {
    fail(`unsafe convergence adjudication: ${adjudicationPath}`);
  }
  const adjudicationReal = realpathSync(adjudicationPath);
  const relative = path.relative(phase4Real, adjudicationReal);
  if (
    relative.startsWith(`..${path.sep}`) ||
    relative === ".." ||
    path.isAbsolute(relative)
  ) {
    fail(`convergence adjudication escapes phase4: ${adjudicationPath}`);
  }
  const adjudication = JSON.parse(readFileSync(adjudicationPath, "utf8"));
  if (
    adjudication.schema !== "deep-review-adjudication/v1" ||
    adjudication.reviewRunId !== reviewRunId ||
    adjudication.phase !== "convergence" ||
    adjudication.round !== round
  ) {
    fail(`convergence adjudication identity mismatch for round ${round}`);
  }
  return adjudication;
}

export function assertCanStartRound({
  phase4Directory,
  reviewRunId,
  nextRound,
  context,
}) {
  const phase4Stat = lstatSync(phase4Directory);
  if (phase4Stat.isSymbolicLink() || !phase4Stat.isDirectory()) {
    fail(`unsafe phase4 directory: ${phase4Directory}`);
  }
  const phase4Real = realpathSync(phase4Directory);
  const adjudications = [];
  for (let round = 1; round < nextRound; round += 1) {
    adjudications.push(
      readPriorAdjudication({
        phase4Directory,
        phase4Real,
        reviewRunId,
        round,
      }),
    );
  }
  assertReviewerSelection(adjudications, context ? getEnabledReviewers(context) : undefined);
  const convergenceEndIndex = firstConvergenceEndIndex(adjudications);
  if (convergenceEndIndex >= 0) {
    fail(
      `review already converged at round ${convergenceEndIndex + 1}; round ${nextRound} cannot start`,
    );
  }
}

function parseArgs(argv) {
  const allowed = new Map([
    ["--phase4-dir", "phase4Directory"],
    ["--review-run-id", "reviewRunId"],
    ["--next-round", "nextRound"],
    ["--context", "contextPath"],
  ]);
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    const key = allowed.get(flag);
    if (!key || value === undefined) fail(`invalid argument: ${flag}`);
    if (parsed[key] !== undefined) fail(`duplicate argument: ${flag}`);
    parsed[key] = value;
  }
  for (const key of ["phase4Directory", "reviewRunId", "nextRound"]) {
    if (!parsed[key]) fail(`missing required argument: ${key}`);
  }
  parsed.nextRound = Number(parsed.nextRound);
  if (!Number.isInteger(parsed.nextRound) || parsed.nextRound < 1) {
    fail("next-round must be a positive integer");
  }
  if (parsed.contextPath) {
    const stat = lstatSync(parsed.contextPath);
    if (stat.isSymbolicLink() || !stat.isFile()) fail("unsafe review context");
    parsed.context = JSON.parse(readFileSync(parsed.contextPath, "utf8"));
  }
  return parsed;
}

const invokedPath = process.argv[1];
if (
  invokedPath &&
  import.meta.url === pathToFileURL(path.resolve(invokedPath)).href
) {
  try {
    assertCanStartRound(parseArgs(process.argv.slice(2)));
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
