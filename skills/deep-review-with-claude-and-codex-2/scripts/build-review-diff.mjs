#!/usr/bin/env node

import { Buffer } from "node:buffer";
import { spawn, spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { TextDecoder } from "node:util";

const REVIEW_DIFF_MAX_BYTES = 64 * 1024 * 1024;
const TEXT_BLOB_MAX_BYTES = 2 * 1024 * 1024;
const TEXT_INSPECTION_MAX_BYTES = 64 * 1024 * 1024;
const REVIEW_PATH_MAX = 10_000;
const GIT_OUTPUT_MAX_BYTES = 128 * 1024 * 1024;
const decoder = new TextDecoder("utf-8", { fatal: true });
const secureGitEnv = {
  ...process.env,
  GIT_ATTR_NOSYSTEM: "1",
  GIT_NO_REPLACE_OBJECTS: "1",
};

function fail(message) {
  throw new Error(message);
}

function runGit(root, args, options = {}) {
  const result = spawnSync("git", args, {
    cwd: root,
    encoding: options.encoding ?? null,
    env: secureGitEnv,
    input: options.input,
    maxBuffer: options.maxBuffer ?? GIT_OUTPUT_MAX_BYTES,
    stdio: ["pipe", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    const stderr = Buffer.isBuffer(result.stderr)
      ? result.stderr.toString("utf8")
      : result.stderr;
    fail(`git ${args[0]} failed: ${stderr.trim()}`);
  }
  return result.stdout;
}

function hasControlCharacter(value) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x1f || code === 0x7f) return true;
  }
  return false;
}

function decodePath(buffer) {
  const decoded = decoder.decode(buffer);
  if (
    decoded.length === 0 ||
    decoded.startsWith("/") ||
    decoded === ".." ||
    decoded.startsWith("../") ||
    decoded.endsWith("/..") ||
    decoded.includes("/../") ||
    hasControlCharacter(decoded)
  ) {
    fail(`unsafe review path: ${JSON.stringify(decoded)}`);
  }
  return decoded;
}

function parseNulPaths(buffer) {
  const paths = [];
  let start = 0;
  for (let index = 0; index < buffer.length; index += 1) {
    if (buffer[index] !== 0) continue;
    paths.push(decodePath(buffer.subarray(start, index)));
    start = index + 1;
  }
  if (start !== buffer.length) fail("unterminated changed-path output");
  return paths;
}

function parseTree(buffer) {
  const entries = new Map();
  let start = 0;
  for (let index = 0; index < buffer.length; index += 1) {
    if (buffer[index] !== 0) continue;
    const record = buffer.subarray(start, index);
    const tab = record.indexOf(0x09);
    if (tab < 0) fail("invalid git ls-tree record");
    const metadata = record.subarray(0, tab).toString("ascii");
    const match = metadata.match(
      /^([0-7]{6}) (blob|commit) ([0-9a-f]+) +(-|[0-9]+)$/,
    );
    if (!match) fail(`invalid git ls-tree metadata: ${metadata}`);
    entries.set(decodePath(record.subarray(tab + 1)), {
      mode: match[1],
      type: match[2],
      oid: match[3],
      size: match[4] === "-" ? null : Number(match[4]),
    });
    start = index + 1;
  }
  if (start !== buffer.length) fail("unterminated git ls-tree output");
  return entries;
}

function classifyTextBlobs(root, candidates) {
  if (candidates.length === 0) return new Map();
  const expected = new Map(candidates.map((entry) => [entry.oid, entry.size]));
  const output = runGit(root, ["cat-file", "--batch"], {
    input: Buffer.from(`${candidates.map((entry) => entry.oid).join("\n")}\n`),
    maxBuffer: TEXT_INSPECTION_MAX_BYTES + 4 * 1024 * 1024,
  });
  const classifications = new Map();
  let offset = 0;
  for (const candidate of candidates) {
    const newline = output.indexOf(0x0a, offset);
    if (newline < 0) fail("incomplete git cat-file header");
    const header = output.subarray(offset, newline).toString("ascii");
    const match = header.match(/^([0-9a-f]+) blob ([0-9]+)$/);
    if (!match || match[1] !== candidate.oid) {
      fail(`unexpected git cat-file header: ${header}`);
    }
    const size = Number(match[2]);
    if (size !== expected.get(candidate.oid)) {
      fail(`git blob size mismatch: ${candidate.oid}`);
    }
    const contentStart = newline + 1;
    const contentEnd = contentStart + size;
    if (contentEnd >= output.length || output[contentEnd] !== 0x0a) {
      fail(`incomplete git blob: ${candidate.oid}`);
    }
    const content = output.subarray(contentStart, contentEnd);
    let isText = !content.includes(0);
    if (isText) {
      try {
        decoder.decode(content);
      } catch {
        isText = false;
      }
    }
    classifications.set(candidate.oid, isText);
    offset = contentEnd + 1;
  }
  if (offset !== output.length) fail("unexpected trailing git cat-file output");
  return classifications;
}

function attributePattern(reviewPath) {
  const escaped = reviewPath.replace(/[\\*?[\]]/gu, "\\$&");
  return JSON.stringify(`/${escaped}`);
}

function parseArgs(argv) {
  const parsed = {};
  const allowed = new Map([
    ["--temp-root", "tempRoot"],
    ["--base-sha", "baseSha"],
    ["--head-sha", "headSha"],
  ]);
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    const key = allowed.get(flag);
    if (!key || !value || parsed[key]) return null;
    parsed[key] = value;
  }
  return parsed.baseSha && parsed.headSha ? parsed : null;
}

const args = parseArgs(process.argv.slice(2));
if (!args) {
  process.stderr.write(
    "ERROR: Usage: build-review-diff.mjs [--temp-root <path>] --base-sha <base-sha> --head-sha <head-sha>\n",
  );
  process.exit(1);
}

const temporaryBase = realpathSync(args.tempRoot ?? tmpdir());
let temporaryRoot;
let child;
let cleaned = false;
function cleanup() {
  if (cleaned) return;
  cleaned = true;
  if (temporaryRoot) {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.once(signal, () => {
    if (child) child.kill(signal);
    cleanup();
    process.exit(128 + { SIGHUP: 1, SIGINT: 2, SIGTERM: 15 }[signal]);
  });
}

try {
  const projectRoot = runGit(process.cwd(), ["rev-parse", "--show-toplevel"], {
    encoding: "utf8",
  }).trim();
  const baseSha = runGit(
    projectRoot,
    ["rev-parse", "--verify", `${args.baseSha}^{commit}`],
    { encoding: "utf8" },
  ).trim();
  const headSha = runGit(
    projectRoot,
    ["rev-parse", "--verify", `${args.headSha}^{commit}`],
    { encoding: "utf8" },
  ).trim();
  const changedPaths = parseNulPaths(
    runGit(projectRoot, [
      "-c",
      "core.attributesFile=/dev/null",
      "diff",
      "--name-only",
      "--no-renames",
      "-z",
      `${baseSha}...${headSha}`,
    ]),
  );
  if (changedPaths.length === 0) fail("review diff is empty");
  if (changedPaths.length > REVIEW_PATH_MAX) {
    fail(`review diff exceeds ${REVIEW_PATH_MAX} changed paths`);
  }

  const baseTree = parseTree(
    runGit(projectRoot, ["ls-tree", "-r", "-z", "-l", baseSha]),
  );
  const headTree = parseTree(
    runGit(projectRoot, ["ls-tree", "-r", "-z", "-l", headSha]),
  );
  const candidatesByOid = new Map();
  let inspectionBytes = 0;
  for (const reviewPath of changedPaths) {
    for (const entry of [baseTree.get(reviewPath), headTree.get(reviewPath)]) {
      if (
        !entry ||
        entry.type !== "blob" ||
        entry.size === null ||
        candidatesByOid.has(entry.oid) ||
        entry.size > TEXT_BLOB_MAX_BYTES ||
        inspectionBytes + entry.size > TEXT_INSPECTION_MAX_BYTES
      ) {
        continue;
      }
      candidatesByOid.set(entry.oid, entry);
      inspectionBytes += entry.size;
    }
  }
  const textBlobs = classifyTextBlobs(
    projectRoot,
    [...candidatesByOid.values()],
  );
  const attributeLines = ["* -diff", "**/* -diff"];
  for (const reviewPath of changedPaths) {
    const entries = [baseTree.get(reviewPath), headTree.get(reviewPath)].filter(
      Boolean,
    );
    const isText =
      entries.length > 0 &&
      entries.every(
        (entry) =>
          entry.type === "blob" &&
          entry.size !== null &&
          entry.size <= TEXT_BLOB_MAX_BYTES &&
          textBlobs.get(entry.oid) === true,
      );
    attributeLines.push(
      `${attributePattern(reviewPath)} ${isText ? "diff" : "-diff"}`,
    );
  }

  temporaryRoot = mkdtempSync(
    path.join(temporaryBase, "deep-review-diff-repo."),
  );
  const bareRoot = path.join(temporaryRoot, "repo.git");
  runGit(projectRoot, [
    "clone",
    "--quiet",
    "--shared",
    "--bare",
    projectRoot,
    bareRoot,
  ]);
  const infoRoot = path.join(bareRoot, "info");
  mkdirSync(infoRoot, { recursive: true, mode: 0o700 });
  const attributesPath = path.join(infoRoot, "attributes");
  writeFileSync(attributesPath, `${attributeLines.join("\n")}\n`, {
    mode: 0o400,
  });
  chmodSync(attributesPath, 0o400);

  child = spawn(
    "git",
    [
      "--git-dir",
      bareRoot,
      "-c",
      "core.attributesFile=/dev/null",
      "--no-pager",
      "diff",
      "--no-renames",
      "--no-ext-diff",
      "--no-textconv",
      `${baseSha}...${headSha}`,
    ],
    {
      cwd: temporaryRoot,
      env: secureGitEnv,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  let outputBytes = 0;
  let stderr = "";
  let exceeded = false;

  child.stdout.on("data", (chunk) => {
    if (exceeded) return;
    outputBytes += chunk.length;
    if (outputBytes > REVIEW_DIFF_MAX_BYTES) {
      exceeded = true;
      child.kill("SIGKILL");
      return;
    }
    if (!process.stdout.write(chunk)) child.stdout.pause();
  });
  process.stdout.on("drain", () => child.stdout.resume());
  child.stderr.on("data", (chunk) => {
    if (stderr.length < 64 * 1024) stderr += chunk.toString("utf8");
  });

  const code = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  });
  if (exceeded) {
    fail(`review diff exceeds ${REVIEW_DIFF_MAX_BYTES} bytes`);
  }
  if (code !== 0) {
    fail(`git diff failed (${code}): ${stderr.trim()}`);
  }
  if (outputBytes === 0) fail("review diff is empty");
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exitCode = 1;
} finally {
  cleanup();
}
