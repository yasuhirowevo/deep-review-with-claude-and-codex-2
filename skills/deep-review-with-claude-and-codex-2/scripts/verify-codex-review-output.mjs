#!/usr/bin/env node

import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import {
  chmodSync,
  lstatSync,
  readFileSync,
  writeFileSync,
} from "node:fs";

import { verifyReviewBody } from "./verify-claude-review-output.mjs";

function fail(message) {
  throw new Error(message);
}

function usage() {
  process.stderr.write(
    "Usage: verify-codex-review-output.mjs --control <path> --prompt <path> --input <path> --output <path>\n",
  );
}

function parseArgs(argv) {
  if (
    argv.length !== 8 ||
    argv[0] !== "--control" ||
    argv[2] !== "--prompt" ||
    argv[4] !== "--input" ||
    argv[6] !== "--output"
  ) {
    usage();
    process.exit(2);
  }
  return {
    control: argv[1],
    prompt: argv[3],
    input: argv[5],
    output: argv[7],
  };
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

function verify(args) {
  assertRegularFile(args.control, "Codex review control");
  assertRegularFile(args.prompt, "attested Codex prompt");
  assertRegularFile(args.input, "raw Codex review output");
  const control = JSON.parse(readFileSync(args.control, "utf8"));
  if (
    control.schema !== "deep-review-codex-input/v1" ||
    typeof control.receiptLine !== "string" ||
    typeof control.diffProbeSha256 !== "string" ||
    typeof control.runId !== "string" ||
    typeof control.target !== "string" ||
    typeof control.headSha !== "string" ||
    typeof control.diffSha256 !== "string" ||
    typeof control.snapshotMetadataSha256 !== "string" ||
    typeof control.promptSha256 !== "string" ||
    !["review", "followup"].includes(control.resultContract)
  ) {
    fail("invalid Codex review control");
  }
  if (sha256(readFileSync(args.prompt)) !== control.promptSha256) {
    fail("Codex attested prompt digest mismatch");
  }

  const lines = readFileSync(args.input, "utf8")
    .replaceAll("\r\n", "\n")
    .split("\n");
  while (lines.length > 0 && lines[0].trim() === "") lines.shift();
  if (lines[0] !== control.receiptLine) {
    fail(
      "Codex input receipt is missing or does not match this review generation",
    );
  }
  lines.shift();
  while (lines.length > 0 && lines[0].trim() === "") lines.shift();
  if (sha256(Buffer.from(lines[0] ?? "", "utf8")) !== control.diffProbeSha256) {
    fail("Codex diff access probe is missing or does not match the fixed diff");
  }
  lines.shift();
  while (lines.length > 0 && lines[0].trim() === "") lines.shift();
  while (lines.length > 0 && lines[lines.length - 1].trim() === "") {
    lines.pop();
  }
  const body = lines.join("\n");
  if (body.trim().length === 0) fail("Codex produced an empty review body");
  if (control.resultContract === "review") {
    verifyReviewBody(body, "Codex");
  }

  const verified = [
    `RUN_ID: ${control.runId}`,
    "INPUT_ATTESTATION: verified",
    `TARGET: ${control.target}`,
    `HEAD_SHA: ${control.headSha}`,
    `DIFF_SHA256: ${control.diffSha256}`,
    `SNAPSHOT_METADATA_SHA256: ${control.snapshotMetadataSha256}`,
    "---",
    body,
    "",
  ].join("\n");
  writeFileSync(args.output, verified, { flag: "wx", mode: 0o600 });
  chmodSync(args.output, 0o600);
}

try {
  verify(parseArgs(process.argv.slice(2)));
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exit(1);
}
