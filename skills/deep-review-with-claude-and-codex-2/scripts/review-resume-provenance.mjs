#!/usr/bin/env node

import { lstatSync, readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const MAX_OUTPUT_BYTES = 4 * 1024 * 1024;
const ID_PREFIX = {
  claude: "SESSION_ID: ",
  codex: "THREAD_ID: ",
};

function fail(message) {
  throw new Error(message);
}

function assertRegularFile(filePath, label) {
  const stat = lstatSync(filePath);
  if (stat.isSymbolicLink() || !stat.isFile()) {
    fail(`${label} must be a regular non-symlink file`);
  }
  if (stat.size > MAX_OUTPUT_BYTES) {
    fail(`${label} exceeds ${MAX_OUTPUT_BYTES} bytes`);
  }
}

function normalizeReviewer(reviewer) {
  if (!Object.hasOwn(ID_PREFIX, reviewer)) {
    fail("resume reviewer must be claude or codex");
  }
  return reviewer;
}

export function extractResumeId(outputPath, reviewer) {
  const normalizedReviewer = normalizeReviewer(reviewer);
  assertRegularFile(outputPath, `${normalizedReviewer} resume source output`);
  const prefix = ID_PREFIX[normalizedReviewer];
  const values = readFileSync(outputPath, "utf8")
    .replaceAll("\r\n", "\n")
    .split("\n")
    .filter((line) => line.startsWith(prefix))
    .map((line) => line.slice(prefix.length));
  if (
    values.length !== 1 ||
    values[0].length === 0 ||
    values[0] !== values[0].trim() ||
    values[0].includes("\0")
  ) {
    fail(
      `${normalizedReviewer} resume source must contain exactly one nonempty ${prefix.trim()} line`,
    );
  }
  return values[0];
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!value) fail(`${flag ?? "<missing>"} requires a value`);
    if (flag === "--input") parsed.input = value;
    else if (flag === "--reviewer") parsed.reviewer = value;
    else fail(`unknown argument: ${flag}`);
  }
  if (!parsed.input || !parsed.reviewer) {
    fail(
      "usage: review-resume-provenance.mjs --input <attempt-output> --reviewer <claude|codex>",
    );
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
    process.stdout.write(`${extractResumeId(args.input, args.reviewer)}\n`);
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
