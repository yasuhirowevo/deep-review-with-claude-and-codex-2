#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

const CREATOR = "deep-review-with-claude-and-codex";
const MAX_FILES = 2_000;
const MAX_FILE_BYTES = 8 * 1024 * 1024;
const MAX_TOTAL_BYTES = 64 * 1024 * 1024;

function fail(message) {
  throw new Error(message);
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--verify") {
      parsed.verify = true;
      continue;
    }
    if (arg === "--require-private") {
      parsed.requirePrivate = true;
      continue;
    }
    const value = argv[index + 1];
    if (!value) fail(`${arg} requires a value`);
    if (arg === "--source") parsed.source = value;
    else if (arg === "--destination") parsed.destination = value;
    else if (arg === "--snapshot") parsed.snapshot = value;
    else if (arg === "--expected-digest") parsed.expectedDigest = value;
    else fail(`unknown argument: ${arg}`);
    index += 1;
  }
  return parsed;
}

function assertOwnedPrivate(stat, expectedMode, label) {
  if (
    typeof process.getuid === "function" &&
    stat.uid !== process.getuid()
  ) {
    fail(`${label} is not owned by the current user`);
  }
  if (process.platform !== "win32") {
    const actualMode = stat.mode & 0o777;
    if (actualMode !== expectedMode) {
      fail(
        `${label} mode must be ${expectedMode.toString(8)}, got ${actualMode.toString(8)}`,
      );
    }
  }
}

function collect(root, { requirePrivate = false } = {}) {
  const entries = [];
  const stack = [root];
  let totalBytes = 0;
  while (stack.length > 0) {
    const current = stack.pop();
    const stat = lstatSync(current);
    if (stat.isSymbolicLink()) fail(`tooling contains a symlink: ${current}`);
    if (stat.isDirectory()) {
      if (requirePrivate) assertOwnedPrivate(stat, 0o700, current);
      const children = readdirSync(current).sort().reverse();
      for (const child of children) stack.push(path.join(current, child));
      continue;
    }
    if (!stat.isFile()) fail(`unsupported tooling entry: ${current}`);
    const relative = path.relative(root, current).split(path.sep).join("/");
    if (!relative || relative.startsWith("../")) {
      fail(`unsafe tooling path: ${relative}`);
    }
    if (stat.size > MAX_FILE_BYTES) {
      fail(`tooling file exceeds ${MAX_FILE_BYTES} bytes: ${relative}`);
    }
    totalBytes += stat.size;
    if (totalBytes > MAX_TOTAL_BYTES) {
      fail(`tooling exceeds ${MAX_TOTAL_BYTES} total bytes`);
    }
    const content = readFileSync(current);
    const normalizedMode = stat.mode & 0o111 ? 0o500 : 0o400;
    if (requirePrivate) assertOwnedPrivate(stat, normalizedMode, current);
    entries.push({
      path: relative,
      size: content.length,
      mode: normalizedMode,
      sha256: sha256(content),
    });
    if (entries.length > MAX_FILES) fail(`tooling exceeds ${MAX_FILES} files`);
  }
  return entries.sort((left, right) => left.path.localeCompare(right.path));
}

function manifestDigest(entries) {
  return sha256(Buffer.from(JSON.stringify(entries), "utf8"));
}

function createSnapshot(sourceInput, destinationInput) {
  const source = realpathSync(sourceInput);
  const destinationParent = realpathSync(path.dirname(destinationInput));
  const destination = path.join(destinationParent, path.basename(destinationInput));
  if (path.dirname(destination) !== destinationParent) {
    fail("tooling destination escaped its parent");
  }
  mkdirSync(destination, { mode: 0o700 });
  const entries = collect(source);
  for (const entry of entries) {
    const output = path.join(destination, ...entry.path.split("/"));
    mkdirSync(path.dirname(output), { recursive: true, mode: 0o700 });
    copyFileSync(path.join(source, ...entry.path.split("/")), output);
    chmodSync(output, entry.mode);
  }
  const metadata = {
    creator: CREATOR,
    schema: "deep-review-tooling-snapshot/v1",
    createdAtMs: Date.now(),
    entries,
    digest: manifestDigest(entries),
  };
  const metadataPath = `${destination}.metadata.json`;
  writeFileSync(metadataPath, `${JSON.stringify(metadata)}\n`, {
    flag: "wx",
    mode: 0o400,
  });
  process.stdout.write(
    `${JSON.stringify({
      toolingRoot: destination,
      toolingMetadataPath: metadataPath,
      toolingDigest: metadata.digest,
    })}\n`,
  );
}

function verifySnapshot(
  snapshotInput,
  expectedDigest,
  sourceInput,
  requirePrivate,
) {
  const snapshotResolved = path.resolve(snapshotInput);
  const snapshot = realpathSync(snapshotInput);
  if (requirePrivate && snapshotResolved !== snapshot) {
    fail("tooling snapshot path contains symlink traversal");
  }
  const metadataPath = `${snapshot}.metadata.json`;
  const metadataStat = lstatSync(metadataPath);
  if (metadataStat.isSymbolicLink() || !metadataStat.isFile()) {
    fail("tooling metadata must be a regular file");
  }
  if (requirePrivate) assertOwnedPrivate(metadataStat, 0o400, metadataPath);
  const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
  if (
    metadata.creator !== CREATOR ||
    metadata.schema !== "deep-review-tooling-snapshot/v1" ||
    !Array.isArray(metadata.entries) ||
    metadata.digest !== expectedDigest
  ) {
    fail("tooling snapshot identity mismatch");
  }
  const actual = collect(snapshot, { requirePrivate });
  const actualDigest = manifestDigest(actual);
  if (
    actualDigest !== expectedDigest ||
    JSON.stringify(actual) !== JSON.stringify(metadata.entries)
  ) {
    fail("tooling snapshot content mismatch");
  }
  if (sourceInput) {
    const source = realpathSync(sourceInput);
    const trustedEntries = collect(source);
    const trustedDigest = manifestDigest(trustedEntries);
    if (
      trustedDigest !== expectedDigest ||
      JSON.stringify(trustedEntries) !== JSON.stringify(metadata.entries)
    ) {
      fail("tooling snapshot does not match the trusted installed skill");
    }
  }
  process.stdout.write(`TOOLING_OK: ${actualDigest}\n`);
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.verify) {
    if (!args.snapshot || !/^[0-9a-f]{64}$/u.test(args.expectedDigest ?? "")) {
      fail("--verify requires --snapshot and --expected-digest");
    }
    verifySnapshot(
      args.snapshot,
      args.expectedDigest,
      args.source,
      args.requirePrivate,
    );
  } else {
    if (!args.source || !args.destination) {
      fail("creation requires --source and --destination");
    }
    createSnapshot(args.source, args.destination);
  }
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exitCode = 1;
}
