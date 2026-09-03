#!/usr/bin/env node

import path from "node:path";
import { pathToFileURL } from "node:url";

function fail(message) {
  throw new Error(message);
}

function normalizeExitCode(value, label) {
  const exitCode = Number(value);
  if (!Number.isInteger(exitCode) || exitCode < 0) {
    fail(`${label} must be a non-negative integer`);
  }
  return exitCode;
}

export function reviewPairExitCode(exitCodes) {
  if (!Array.isArray(exitCodes) || exitCodes.length === 0) {
    fail("review pair exit codes must be a nonempty array");
  }
  const normalized = exitCodes.map((value, index) =>
    normalizeExitCode(value, `reviewer exit code ${index + 1}`),
  );
  if (normalized.some((exitCode) => exitCode === 3)) return 3;
  const failures = normalized.filter((exitCode) => exitCode !== 0).length;
  if (failures === 0) return 0;
  return failures === normalized.length && normalized.length > 1 ? 21 : 20;
}

export function assertReviewerAttemptTransition(
  previousExitCode,
  execution,
  label,
) {
  const normalizedExitCode = normalizeExitCode(
    previousExitCode,
    `${label} previous exit code`,
  );
  if (!new Set(["retry", "resume"]).has(execution)) {
    fail(`${label} execution must be retry or resume`);
  }
  if (normalizedExitCode === 3 && execution === "resume") {
    fail(
      `${label} cannot resume after execution infrastructure exit 3; retry without a resume identifier`,
    );
  }
}

function parseOptions(argv, allowed) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    const key = allowed.get(flag);
    if (!key || value === undefined || parsed[key] !== undefined) {
      fail(`invalid argument: ${flag ?? "<missing>"}`);
    }
    parsed[key] = value;
  }
  return parsed;
}

function runCli(argv) {
  const command = argv[0];
  if (command === "exit-code") {
    const parsed = parseOptions(
      argv.slice(1),
      new Map([
        ["--claude-exit-code", "claudeExitCode"],
        ["--codex-exit-code", "codexExitCode"],
      ]),
    );
    if (parsed.claudeExitCode === undefined || parsed.codexExitCode === undefined) {
      fail(
        "usage: review-pair-policy.mjs exit-code --claude-exit-code <code> --codex-exit-code <code>",
      );
    }
    process.stdout.write(
      `${reviewPairExitCode([parsed.claudeExitCode, parsed.codexExitCode])}\n`,
    );
    return;
  }
  if (command === "transition") {
    const parsed = parseOptions(
      argv.slice(1),
      new Map([
        ["--reviewer", "reviewer"],
        ["--previous-exit-code", "previousExitCode"],
        ["--execution", "execution"],
      ]),
    );
    if (
      !new Set(["claude", "codex"]).has(parsed.reviewer) ||
      parsed.previousExitCode === undefined ||
      parsed.execution === undefined
    ) {
      fail(
        "usage: review-pair-policy.mjs transition --reviewer <claude|codex> --previous-exit-code <code> --execution <retry|resume>",
      );
    }
    assertReviewerAttemptTransition(
      parsed.previousExitCode,
      parsed.execution,
      parsed.reviewer === "claude" ? "Claude" : "Codex",
    );
    return;
  }
  fail("command must be exit-code or transition");
}

const invokedPath = process.argv[1];
if (
  invokedPath &&
  import.meta.url === pathToFileURL(path.resolve(invokedPath)).href
) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exitCode = 2;
  }
}
