#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmodSync,
  lstatSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { isDeepStrictEqual } from "node:util";

const SHA256_PATTERN = /^[0-9a-f]{64}$/u;
const MAX_CONVERGENCE_ROUNDS = 20;

function fail(message) {
  throw new Error(message);
}

function assertRegularFile(filePath, label) {
  const stat = lstatSync(filePath);
  if (stat.isSymbolicLink() || !stat.isFile()) {
    fail(`${label} must be a regular non-symlink file`);
  }
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

function normalizeIdentity({ reviewer, phase, round, purpose }) {
  if (!new Set(["claude", "codex"]).has(reviewer)) {
    fail("prompt reviewer must be claude or codex");
  }
  if (!new Set(["primary", "convergence"]).has(phase)) {
    fail("prompt phase must be primary or convergence");
  }
  let normalizedRound = null;
  if (phase === "convergence") {
    normalizedRound = Number(round);
    if (
      !Number.isInteger(normalizedRound) ||
      normalizedRound < 1 ||
      normalizedRound > MAX_CONVERGENCE_ROUNDS
    ) {
      fail(`prompt convergence round must be between 1 and ${MAX_CONVERGENCE_ROUNDS}`);
    }
  } else if (round !== undefined && round !== null && round !== "") {
    fail("prompt round is only valid for convergence");
  }
  if (!new Set(["review", "resume"]).has(purpose)) {
    fail("prompt purpose must be review or resume");
  }
  return { reviewer, phase, round: normalizedRound, purpose };
}

function assertContext(context) {
  if (
    !context ||
    typeof context !== "object" ||
    typeof context.reviewRunId !== "string" ||
    context.reviewRunId.length === 0
  ) {
    fail("prompt context is missing reviewRunId");
  }
}

function loadContext(contextPath) {
  assertRegularFile(contextPath, "prompt context");
  const context = JSON.parse(readFileSync(contextPath, "utf8"));
  assertContext(context);
  return context;
}

export function manifestPathForPrompt(promptPath) {
  return `${promptPath}.manifest.json`;
}

export function createPromptManifest({
  context,
  promptPath,
  reviewer,
  phase,
  round,
  purpose,
}) {
  assertContext(context);
  const identity = normalizeIdentity({ reviewer, phase, round, purpose });
  assertRegularFile(promptPath, "review prompt");
  const promptRealPath = realpathSync(promptPath);
  const promptBytes = readFileSync(promptRealPath);
  const manifest = {
    schema: "deep-review-prompt-manifest/v1",
    reviewRunId: context.reviewRunId,
    ...identity,
    promptPath: promptRealPath,
    promptSha256: sha256(promptBytes),
  };
  const manifestPath = manifestPathForPrompt(promptPath);
  let manifestCreated = false;
  try {
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, {
      flag: "wx",
      mode: 0o400,
    });
    manifestCreated = true;
    chmodSync(manifestPath, 0o400);
  } catch (error) {
    if (manifestCreated) rmSync(manifestPath, { force: true });
    throw error;
  }
  return manifest;
}

export function verifyPromptManifest({
  context,
  promptPath,
  reviewer,
  phase,
  round,
  purpose,
}) {
  assertContext(context);
  const identity = normalizeIdentity({ reviewer, phase, round, purpose });
  assertRegularFile(promptPath, "review prompt");
  const promptRealPath = realpathSync(promptPath);
  const manifestPath = manifestPathForPrompt(promptRealPath);
  assertRegularFile(manifestPath, "review prompt manifest");
  const manifestRealPath = realpathSync(manifestPath);
  const manifestBytes = readFileSync(manifestRealPath);
  const manifest = JSON.parse(manifestBytes.toString("utf8"));
  if (
    manifest.schema !== "deep-review-prompt-manifest/v1" ||
    manifest.reviewRunId !== context.reviewRunId ||
    manifest.reviewer !== identity.reviewer ||
    manifest.phase !== identity.phase ||
    manifest.round !== identity.round ||
    manifest.purpose !== identity.purpose ||
    typeof manifest.promptPath !== "string" ||
    typeof manifest.promptSha256 !== "string" ||
    !SHA256_PATTERN.test(manifest.promptSha256)
  ) {
    fail("review prompt manifest does not match the requested execution");
  }
  assertRegularFile(manifest.promptPath, "manifest review prompt");
  if (realpathSync(manifest.promptPath) !== promptRealPath) {
    fail("review prompt manifest path does not match the supplied prompt");
  }
  if (sha256(readFileSync(promptRealPath)) !== manifest.promptSha256) {
    fail("review prompt digest does not match its manifest");
  }
  return {
    schema: "deep-review-prompt-receipt/v1",
    reviewRunId: manifest.reviewRunId,
    reviewer: manifest.reviewer,
    phase: manifest.phase,
    round: manifest.round,
    purpose: manifest.purpose,
    promptPath: promptRealPath,
    promptSha256: manifest.promptSha256,
    manifestPath: manifestRealPath,
    manifestSha256: sha256(manifestBytes),
  };
}

export function verifyPromptReceipt(receipt, options) {
  if (!receipt || typeof receipt !== "object") {
    fail("review prompt receipt is missing");
  }
  const actual = verifyPromptManifest({
    ...options,
    promptPath: receipt.promptPath,
  });
  if (!isDeepStrictEqual(receipt, actual)) {
    fail("review prompt receipt does not match the persisted manifest");
  }
  return actual;
}

function parseArgs(argv) {
  if (argv[0] !== "--verify") {
    fail(
      "usage: review-prompt-manifest.mjs --verify --context <path> --prompt <path> --reviewer <claude|codex> --phase <primary|convergence> [--round <1..20>] --purpose <review|resume>",
    );
  }
  const parsed = {};
  for (let index = 1; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!value) fail(`${flag ?? "<missing>"} requires a value`);
    if (flag === "--context") parsed.contextPath = value;
    else if (flag === "--prompt") parsed.promptPath = value;
    else if (flag === "--reviewer") parsed.reviewer = value;
    else if (flag === "--phase") parsed.phase = value;
    else if (flag === "--round") parsed.round = value;
    else if (flag === "--purpose") parsed.purpose = value;
    else fail(`unknown argument: ${flag}`);
  }
  for (const key of [
    "contextPath",
    "promptPath",
    "reviewer",
    "phase",
    "purpose",
  ]) {
    if (!parsed[key]) fail(`missing required prompt manifest argument: ${key}`);
  }
  return parsed;
}

const invokedPath = process.argv[1];
if (
  invokedPath &&
  import.meta.url === pathToFileURL(path.resolve(invokedPath)).href
) {
  try {
    const args = parseArgs(process.argv.slice(2));
    const receipt = verifyPromptManifest({
      context: loadContext(args.contextPath),
      promptPath: args.promptPath,
      reviewer: args.reviewer,
      phase: args.phase,
      round: args.round,
      purpose: args.purpose,
    });
    process.stdout.write(`${JSON.stringify(receipt)}\n`);
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
