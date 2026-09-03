#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmodSync,
  lstatSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { toNativeAbsolutePath } from "./path-interop.mjs";
import { verifyReviewBody } from "./verify-claude-review-output.mjs";

const REVIEWERS = new Set(["claude", "codex"]);
const PHASES = new Set(["primary", "convergence"]);
const SHA256_PATTERN = /^[0-9a-f]{64}$/u;

function fail(message) {
  throw new Error(message);
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

function assertRegularFile(filePath, label, requireNonEmpty = false) {
  const hostPath = toNativeAbsolutePath(filePath);
  let stat;
  try {
    stat = lstatSync(hostPath);
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
  return hostPath;
}

export function extractReviewCandidates(body, reviewer) {
  if (!REVIEWERS.has(reviewer)) fail("reviewer must be claude or codex");
  const { candidates } = verifyReviewBody(body, reviewer);
  return candidates.map((candidate, index) => {
    const ordinal = index + 1;
    const candidateId = `${reviewer}-F${String(ordinal).padStart(3, "0")}`;
    return {
      candidateId,
      ordinal,
      severity: candidate.severity,
      title: candidate.title,
      sourceLine: candidate.sourceLine,
      candidateSha256: sha256(
        Buffer.from(
          `${candidate.sourceLine}\n${candidate.severity}\n${candidate.title}\n`,
          "utf8",
        ),
      ),
    };
  });
}

function attestedBody(raw) {
  const lines = raw.replaceAll("\r\n", "\n").split("\n");
  const separator = lines.indexOf("---");
  if (separator < 0) fail("review output is missing its attestation separator");
  return lines.slice(separator + 1).join("\n").trimEnd();
}

function validateIdentity(value) {
  if (!REVIEWERS.has(value.reviewer)) fail("invalid output evidence reviewer");
  if (!PHASES.has(value.phase)) fail("invalid output evidence phase");
  if (
    (value.phase === "primary" && value.round !== null) ||
    (value.phase === "convergence" &&
      (!Number.isInteger(value.round) || value.round < 1 || value.round > 20)) ||
    !Number.isInteger(value.attempt) ||
    value.attempt < 1
  ) {
    fail("invalid output evidence scope");
  }
}

export function createOutputEvidence({
  inputPath,
  outputPath,
  reviewer,
  phase,
  round,
  attempt,
}) {
  const hostInputPath = assertRegularFile(inputPath, "review output", true);
  const hostOutputPath = toNativeAbsolutePath(outputPath);
  const raw = readFileSync(hostInputPath);
  const candidates = extractReviewCandidates(
    attestedBody(raw.toString("utf8")),
    reviewer,
  );
  const manifest = {
    schema: "deep-review-output-evidence/v1",
    reviewer,
    phase,
    round,
    attempt,
    outputSha256: sha256(raw),
    candidateCount: candidates.length,
    candidates,
  };
  validateIdentity(manifest);
  const serialized = `${JSON.stringify(manifest, null, 2)}\n`;
  writeFileSync(hostOutputPath, serialized, { flag: "wx", mode: 0o600 });
  chmodSync(hostOutputPath, 0o600);
  return {
    schema: manifest.schema,
    path: outputPath,
    sha256: sha256(Buffer.from(serialized, "utf8")),
    outputSha256: manifest.outputSha256,
    candidateCount: candidates.length,
  };
}

export function validateOutputEvidenceFile({
  evidencePath,
  outputPath,
  reviewer,
  phase,
  round,
  attempt,
  receipt,
}) {
  const hostEvidencePath = assertRegularFile(
    evidencePath,
    `${reviewer} output evidence`,
    true,
  );
  const hostOutputPath = assertRegularFile(
    outputPath,
    `${reviewer} output`,
    true,
  );
  const evidenceRaw = readFileSync(hostEvidencePath);
  let manifest;
  try {
    manifest = JSON.parse(evidenceRaw.toString("utf8"));
  } catch {
    fail(`${reviewer} output evidence is invalid JSON`);
  }
  if (
    manifest.schema !== "deep-review-output-evidence/v1" ||
    manifest.reviewer !== reviewer ||
    manifest.phase !== phase ||
    manifest.round !== round ||
    manifest.attempt !== attempt
  ) {
    fail(`${reviewer} output evidence identity is invalid`);
  }
  validateIdentity(manifest);
  const evidenceSha256 = sha256(evidenceRaw);
  const outputSha256 = sha256(readFileSync(hostOutputPath));
  if (
    manifest.outputSha256 !== outputSha256 ||
    !SHA256_PATTERN.test(manifest.outputSha256) ||
    !Array.isArray(manifest.candidates) ||
    manifest.candidateCount !== manifest.candidates.length
  ) {
    fail(`${reviewer} output evidence does not match its output`);
  }
  const expectedCandidates = extractReviewCandidates(
    attestedBody(readFileSync(hostOutputPath, "utf8")),
    reviewer,
  );
  if (JSON.stringify(manifest.candidates) !== JSON.stringify(expectedCandidates)) {
    fail(`${reviewer} output evidence candidates do not match its output`);
  }
  if (
    receipt &&
    (receipt.schema !== manifest.schema ||
      normalizePortablePath(receipt.path) !==
        normalizePortablePath(evidencePath) ||
      receipt.sha256 !== evidenceSha256 ||
      receipt.outputSha256 !== outputSha256 ||
      receipt.candidateCount !== manifest.candidateCount)
  ) {
    fail(`${reviewer} output evidence receipt is invalid`);
  }
  return { manifest, evidenceSha256, outputSha256 };
}

function parseArgs(argv) {
  const allowed = new Map([
    ["--input", "inputPath"],
    ["--output", "outputPath"],
    ["--reviewer", "reviewer"],
    ["--phase", "phase"],
    ["--round", "round"],
    ["--attempt", "attempt"],
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
  for (const key of ["inputPath", "outputPath", "reviewer", "phase", "attempt"]) {
    if (!parsed[key]) fail(`missing required argument: ${key}`);
  }
  parsed.attempt = Number(parsed.attempt);
  parsed.round = parsed.round === undefined ? null : Number(parsed.round);
  if (parsed.phase === "convergence" && parsed.round === null) {
    fail("convergence output evidence requires --round");
  }
  if (parsed.phase === "primary" && parsed.round !== null) {
    fail("primary output evidence does not accept --round");
  }
  return parsed;
}

function normalizePortablePath(value) {
  const slashes = value.replaceAll("\\", "/").replace(/\/{2,}/gu, "/");
  const drive = slashes.match(/^([A-Za-z]):\/(.*)$/u);
  return drive ? `/${drive[1].toLowerCase()}/${drive[2]}` : slashes;
}

const invokedPath = process.argv[1];
if (
  invokedPath &&
  import.meta.url === pathToFileURL(path.resolve(invokedPath)).href
) {
  try {
    const receipt = createOutputEvidence(parseArgs(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify(receipt)}\n`);
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
