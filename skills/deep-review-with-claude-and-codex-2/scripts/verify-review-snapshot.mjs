#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  lstatSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from "node:fs";
import path from "node:path";

function fail(message) {
  throw new Error(message);
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

const argv = process.argv.slice(2);
if (
  (argv.length !== 5 && argv.length !== 6) ||
  argv[0] !== "--snapshot" ||
  argv[2] !== "--head-sha" ||
  (argv.length === 5 && argv[4] !== "--print-metadata-sha256") ||
  (argv.length === 6 && argv[4] !== "--expected-metadata-sha256")
) {
  process.stderr.write(
    "Usage: verify-review-snapshot.mjs --snapshot <path> --head-sha <sha> (--print-metadata-sha256 | --expected-metadata-sha256 <sha256>)\n",
  );
  process.exit(2);
}

const snapshotRoot = realpathSync(argv[1]);
const expectedHeadSha = argv[3];
const metadataPath = `${snapshotRoot}.metadata.json`;
const metadataBytes = readFileSync(metadataPath);
const metadata = JSON.parse(metadataBytes.toString("utf8"));
if (
  metadata.creator !== "deep-review-with-claude-and-codex" ||
  metadata.state !== "complete" ||
  metadata.headSha !== expectedHeadSha ||
  !Array.isArray(metadata.manifest)
) {
  fail("snapshot metadata identity mismatch");
}

const expected = new Map();
for (const entry of metadata.manifest) {
  if (
    typeof entry?.path !== "string" ||
    typeof entry?.sha256 !== "string" ||
    typeof entry?.size !== "number" ||
    expected.has(entry.path)
  ) {
    fail("invalid snapshot manifest entry");
  }
  expected.set(entry.path, entry);
}

const actualPaths = [];
const stack = [snapshotRoot];
while (stack.length > 0) {
  const current = stack.pop();
  const stat = lstatSync(current);
  if (stat.isSymbolicLink()) fail("live symlink found in snapshot");
  if (stat.isDirectory()) {
    for (const entry of readdirSync(current)) {
      stack.push(path.join(current, entry));
    }
    continue;
  }
  if (!stat.isFile()) fail("unsupported snapshot entry type");
  const relative = path.relative(snapshotRoot, current).split(path.sep).join("/");
  actualPaths.push(relative);
  const manifestEntry = expected.get(relative);
  if (!manifestEntry) fail(`unexpected snapshot file: ${relative}`);
  const content = readFileSync(current);
  if (
    content.length !== manifestEntry.size ||
    sha256(content) !== manifestEntry.sha256
  ) {
    fail(`snapshot content mismatch: ${relative}`);
  }
}

if (
  actualPaths.length !== expected.size ||
  actualPaths.some((entry) => !expected.has(entry))
) {
  fail("snapshot manifest entry set mismatch");
}

if (argv.length === 5) {
  process.stdout.write(`${sha256(metadataBytes)}\n`);
} else if (sha256(metadataBytes) !== argv[5]) {
  fail("snapshot metadata digest mismatch");
}
