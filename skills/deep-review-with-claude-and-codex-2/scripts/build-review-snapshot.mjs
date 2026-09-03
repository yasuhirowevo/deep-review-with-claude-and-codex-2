#!/usr/bin/env node

import { Buffer } from "node:buffer";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { TextDecoder } from "node:util";

import { toBashAbsolutePath } from "./path-interop.mjs";

const REVIEW_BLOB_MAX_BYTES = 2 * 1024 * 1024;
const REVIEW_TOTAL_MAX_BYTES = 256 * 1024 * 1024;
const REVIEW_ENTRY_MAX = 10_000;
const REVIEW_PATH_MAX_BYTES = 4 * 1024 * 1024;
const REVIEW_DIRECTORY_MAX = 5_000;
const REVIEW_TEXT_SCAN_MAX_BYTES = 512 * 1024 * 1024;
const REVIEW_SCOPE_GAP_PATH_MAX = 2_000;
const textDecoder = new TextDecoder("utf-8", { fatal: true });

function fail(message) {
  throw new Error(message);
}

function usage() {
  process.stderr.write(
    "Usage: build-review-snapshot.mjs [--temp-root <path>] --base-sha <sha> --head-sha <sha> [--related <repo-relative-path>]...\n",
  );
}

function parseArgs(argv) {
  const parsed = { related: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const value = argv[index + 1];
    if (
      arg === "--temp-root" ||
      arg === "--base-sha" ||
      arg === "--head-sha" ||
      arg === "--related"
    ) {
      if (!value) fail(`${arg} requires a value`);
      if (arg === "--temp-root") parsed.tempRoot = value;
      if (arg === "--base-sha") parsed.baseSha = value;
      if (arg === "--head-sha") parsed.headSha = value;
      if (arg === "--related") parsed.related.push(value);
      index += 1;
      continue;
    }
    if (arg === "-h" || arg === "--help") {
      usage();
      process.exit(0);
    }
    fail(`unknown argument: ${arg}`);
  }
  if (!parsed.baseSha || !parsed.headSha) {
    usage();
    fail("--base-sha and --head-sha are required");
  }
  return parsed;
}

function runGit(root, args, options = {}) {
  const result = spawnSync("git", args, {
    cwd: root,
    encoding: options.encoding ?? null,
    env: { ...process.env, GIT_NO_REPLACE_OBJECTS: "1" },
    maxBuffer: 128 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
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

function decodePath(pathBuffer) {
  const decoded = textDecoder.decode(pathBuffer);
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
  if (start !== buffer.length) fail("unterminated NUL-delimited git path output");
  return paths;
}

function parseTree(buffer) {
  const entries = [];
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
    entries.push({
      mode: match[1],
      type: match[2],
      oid: match[3],
      size: match[4] === "-" ? null : Number(match[4]),
      reviewPath: decodePath(record.subarray(tab + 1)),
    });
    start = index + 1;
  }
  if (start !== buffer.length) fail("unterminated git ls-tree output");
  return entries;
}

function isReviewText(reviewPath) {
  const basename = path.posix.basename(reviewPath);
  if (["Dockerfile", "Makefile", "Podfile"].includes(basename)) return true;
  if (
    /^(?:\.env(?:\.[^.]+)*\.(?:example|sample|template)|\.(?:editorconfig|gitignore|npmrc|nvmrc|prettierrc|eslintrc)(?:\.|$))/u.test(
      basename,
    )
  ) {
    return true;
  }
  return /\.(?:ts|tsx|js|jsx|mjs|cjs|json|jsonc|md|mdx|txt|yml|yaml|toml|sh|bash|zsh|fish|ps1|tf|tfvars|tftpl|graphql|gql|proto|prisma|sql|css|scss|sass|less|html|xml|plist|gradle|properties|cfg|conf|ini|lock|snap|rb|py|pyi|go|rs|swift|kt|kts|java|c|cc|cpp|cxx|h|hh|hpp|hxx|cs|csx|fs|fsx|vb|php|phtml|dart|vue|svelte|scala|sc|ex|exs|erl|hrl|lua|pl|pm|r|groovy|gvy|sol|zig|nim|hs|lhs|clj|cljs|cljc|edn|coffee|qml|pbxproj|xcconfig|entitlements|storyboard|xcscheme)$/.test(
    reviewPath,
  );
}

function isSensitiveUnchangedPath(reviewPath) {
  const lowerPath = reviewPath.toLowerCase();
  const basename = path.posix.basename(lowerPath);
  const segments = lowerPath.split("/");
  const isTemplate =
    /(?:^|[._-])(?:example|sample|template)(?:\.(?:json|ya?ml|toml|ini|conf|cfg))?$/u.test(
      basename,
    );
  const isCredentialDataFile =
    !basename.includes(".") ||
    /\.(?:json|ya?ml|toml|ini|conf|cfg)$/u.test(basename);
  if (/^\.env(?:\.|$)/u.test(basename) && !isTemplate) return true;
  if (
    /\.(?:pem|key|p8|pk8|p12|pfx|jks|keystore|der|gpg|pgp|age|kdbx|ovpn|tfstate)$/u.test(
      basename,
    )
  ) {
    return true;
  }
  if (
    !isTemplate &&
    isCredentialDataFile &&
    /(?:^|[._-])(?:credentials?|client[-_]?secrets?|service[-_]?accounts?|firebase[-_]?adminsdk|account[-_]?keys?)(?:[._-]|$)/u.test(
      basename,
    )
  ) {
    return true;
  }
  if (/^id_(?:rsa|dsa|ecdsa|ed25519|xmss)(?:\.pub)?$/u.test(basename)) {
    return true;
  }
  if (/^\.(?:npmrc|pypirc|netrc)/u.test(basename)) return true;
  if (
    [
      "auth.json",
      "credentials",
      "credentials.json",
      "credentials.yml",
      "credentials.yaml",
      "secrets.json",
      "secrets.yml",
      "secrets.yaml",
      "service-account.json",
      "service_account.json",
      "google-services.json",
      "googleservice-info.plist",
      "id_rsa",
      "id_ed25519",
      "kubeconfig",
    ].includes(basename)
  ) {
    return true;
  }
  if (/\.tfvars(?:\.json)?$/u.test(basename) && !isTemplate) return true;
  if (
    segments.includes(".ssh") ||
    segments.includes(".gnupg") ||
    (segments.includes(".aws") &&
      ["config", "credentials"].includes(basename)) ||
    (lowerPath.includes(".config/gcloud/") &&
      /(?:credential|account|token)/u.test(basename))
  ) {
    return true;
  }
  return false;
}

function detectUtf8TextBlobs(root, blobs) {
  return new Promise((resolve, reject) => {
    if (blobs.length === 0) {
      resolve(new Set());
      return;
    }
    const child = spawn("git", ["cat-file", "--batch"], {
      cwd: root,
      env: { ...process.env, GIT_NO_REPLACE_OBJECTS: "1" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buffer = Buffer.alloc(0);
    let stderr = "";
    let recordIndex = 0;
    let state = "header";
    let current = null;
    let settled = false;
    const textPaths = new Set();

    const rejectOnce = (error) => {
      if (settled) return;
      settled = true;
      child.kill("SIGKILL");
      reject(error);
    };
    const consume = () => {
      while (true) {
        if (state === "header") {
          const newline = buffer.indexOf(0x0a);
          if (newline < 0) return;
          if (recordIndex >= blobs.length) {
            fail("text scan returned an unexpected extra object");
          }
          const header = buffer.subarray(0, newline).toString("ascii");
          buffer = buffer.subarray(newline + 1);
          const match = header.match(/^([0-9a-f]+) blob ([0-9]+)$/);
          current = blobs[recordIndex];
          if (
            !match ||
            match[1] !== current.oid ||
            Number(match[2]) !== current.size
          ) {
            fail(`text scan response mismatch: ${current.reviewPath}`);
          }
          state = "content";
        }
        if (state === "content") {
          if (buffer.length < current.size + 1) return;
          if (buffer[current.size] !== 0x0a) {
            fail(`invalid text scan object boundary: ${current.reviewPath}`);
          }
          const content = buffer.subarray(0, current.size);
          if (!content.includes(0)) {
            try {
              textDecoder.decode(content);
              textPaths.add(current.reviewPath);
            } catch {
              // Invalid UTF-8 is treated as binary. Changed files remain
              // selected independently and are represented by the snapshot.
            }
          }
          buffer = buffer.subarray(current.size + 1);
          recordIndex += 1;
          current = null;
          state = "header";
        }
      }
    };

    child.stdout.on("data", (chunk) => {
      try {
        buffer = Buffer.concat([buffer, chunk]);
        consume();
      } catch (error) {
        rejectOnce(error);
      }
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", rejectOnce);
    child.on("close", (code) => {
      if (settled) return;
      try {
        consume();
        if (
          code !== 0 ||
          state !== "header" ||
          recordIndex !== blobs.length ||
          buffer.length !== 0
        ) {
          fail(`incomplete text scan stream: ${stderr.trim()}`);
        }
        settled = true;
        resolve(textPaths);
      } catch (error) {
        rejectOnce(error);
      }
    });
    child.stdin.on("error", rejectOnce);
    child.stdin.end(`${blobs.map((entry) => entry.oid).join("\n")}\n`);
  });
}

function safeOutputPath(snapshotRoot, reviewPath) {
  const outputPath = path.resolve(snapshotRoot, reviewPath);
  if (!outputPath.startsWith(`${snapshotRoot}${path.sep}`)) {
    fail(`snapshot path escapes root: ${reviewPath}`);
  }
  return outputPath;
}

function gitBlobHash(objectFormat, content) {
  return createHash(objectFormat)
    .update(Buffer.from(`blob ${content.length}\0`, "ascii"))
    .update(content)
    .digest("hex");
}

function manifestEntry(reviewPath, content, kind) {
  return {
    path: reviewPath,
    size: content.length,
    sha256: createHash("sha256").update(content).digest("hex"),
    kind,
  };
}

function materializeBlobs(
  root,
  snapshotRoot,
  objectFormat,
  blobs,
  manifest,
) {
  return new Promise((resolve, reject) => {
    const child = spawn("git", ["cat-file", "--batch"], {
      cwd: root,
      env: { ...process.env, GIT_NO_REPLACE_OBJECTS: "1" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buffer = Buffer.alloc(0);
    let stderr = "";
    let recordIndex = 0;
    let state = "header";
    let current = null;
    let settled = false;

    const rejectOnce = (error) => {
      if (settled) return;
      settled = true;
      child.kill("SIGKILL");
      reject(error);
    };

    const consume = () => {
      while (true) {
        if (state === "header") {
          const newline = buffer.indexOf(0x0a);
          if (newline < 0) return;
          if (recordIndex >= blobs.length) {
            fail("git cat-file returned an unexpected extra object");
          }
          const header = buffer.subarray(0, newline).toString("ascii");
          buffer = buffer.subarray(newline + 1);
          const match = header.match(/^([0-9a-f]+) (blob) ([0-9]+)$/);
          current = blobs[recordIndex];
          if (
            !match ||
            match[1] !== current.oid ||
            Number(match[3]) !== current.size
          ) {
            fail(`git cat-file response mismatch: ${current.reviewPath}`);
          }
          state = "content";
        }

        if (state === "content") {
          if (buffer.length < current.size + 1) return;
          if (buffer[current.size] !== 0x0a) {
            fail(`invalid git cat-file object boundary: ${current.reviewPath}`);
          }
          const content = buffer.subarray(0, current.size);
          const actualOid = gitBlobHash(objectFormat, content);
          if (actualOid !== current.oid) {
            fail(`raw blob hash mismatch: ${current.reviewPath}`);
          }
          const outputPath = safeOutputPath(snapshotRoot, current.reviewPath);
          mkdirSync(path.dirname(outputPath), { recursive: true, mode: 0o700 });
          const outputContent =
            current.mode === "120000"
              ? Buffer.concat([Buffer.from("SYMLINK_TARGET:\n"), content])
              : content;
          writeFileSync(outputPath, outputContent, {
            flag: "wx",
            mode: 0o600,
          });
          manifest.push(
            manifestEntry(
              current.reviewPath,
              outputContent,
              current.mode === "120000" ? "symlink-target" : "blob",
            ),
          );
          buffer = buffer.subarray(current.size + 1);
          recordIndex += 1;
          current = null;
          state = "header";
        }
      }
    };

    child.stdout.on("data", (chunk) => {
      try {
        buffer = Buffer.concat([buffer, chunk]);
        consume();
      } catch (error) {
        rejectOnce(error);
      }
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", rejectOnce);
    child.on("close", (code) => {
      if (settled) return;
      try {
        consume();
        if (
          code !== 0 ||
          state !== "header" ||
          recordIndex !== blobs.length ||
          buffer.length !== 0
        ) {
          fail(`incomplete git cat-file stream: ${stderr.trim()}`);
        }
        settled = true;
        resolve();
      } catch (error) {
        rejectOnce(error);
      }
    });
    child.stdin.on("error", rejectOnce);
    child.stdin.end(`${blobs.map((entry) => entry.oid).join("\n")}\n`);
  });
}

const args = parseArgs(process.argv.slice(2));
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
const mergeBase = runGit(
  projectRoot,
  ["merge-base", baseSha, headSha],
  { encoding: "utf8" },
).trim();
const objectFormat = runGit(
  projectRoot,
  ["rev-parse", "--show-object-format"],
  { encoding: "utf8" },
).trim();
if (!["sha1", "sha256"].includes(objectFormat)) {
  fail(`unsupported git object format: ${objectFormat}`);
}

const changedPaths = new Set(
  parseNulPaths(
    runGit(projectRoot, [
      "diff-tree",
      "-r",
      "--no-commit-id",
      "--name-only",
      "--no-renames",
      "-z",
      mergeBase,
      headSha,
    ]),
  ),
);
for (const relatedPath of args.related) {
  changedPaths.add(decodePath(Buffer.from(relatedPath, "utf8")));
}

const treeEntries = parseTree(
  runGit(projectRoot, ["ls-tree", "-r", "-z", "-l", headSha]),
);
const textScanCandidates = [];
const unscannedTextCandidates = [];
let textScanBytes = 0;
for (const entry of treeEntries) {
  if (
    entry.type !== "blob" ||
    entry.mode === "120000" ||
    entry.size === null ||
    isReviewText(entry.reviewPath) ||
    isSensitiveUnchangedPath(entry.reviewPath) ||
    changedPaths.has(entry.reviewPath)
  ) {
    continue;
  }
  if (
    entry.size <= REVIEW_BLOB_MAX_BYTES &&
    textScanBytes + entry.size <= REVIEW_TEXT_SCAN_MAX_BYTES
  ) {
    textScanCandidates.push(entry);
    textScanBytes += entry.size;
  } else {
    unscannedTextCandidates.push(entry);
  }
}
const detectedTextPaths = await detectUtf8TextBlobs(
  projectRoot,
  textScanCandidates,
);
const selected = treeEntries.filter(
  (entry) =>
    changedPaths.has(entry.reviewPath) ||
    (!isSensitiveUnchangedPath(entry.reviewPath) &&
      (isReviewText(entry.reviewPath) ||
        detectedTextPaths.has(entry.reviewPath))),
);
if (selected.length === 0) fail("review snapshot has no selected objects");
if (selected.length > REVIEW_ENTRY_MAX) {
  fail(`review snapshot exceeds ${REVIEW_ENTRY_MAX} entries`);
}

let totalPathBytes = 0;
const reviewDirectories = new Set();
for (const entry of selected) {
  totalPathBytes += Buffer.byteLength(entry.reviewPath);
  if (totalPathBytes > REVIEW_PATH_MAX_BYTES) {
    fail(`review paths exceed ${REVIEW_PATH_MAX_BYTES} total bytes`);
  }
  let directory = path.posix.dirname(entry.reviewPath);
  while (directory !== ".") {
    reviewDirectories.add(directory);
    if (reviewDirectories.size > REVIEW_DIRECTORY_MAX) {
      fail(`review snapshot exceeds ${REVIEW_DIRECTORY_MAX} directories`);
    }
    directory = path.posix.dirname(directory);
  }
}

let totalBytes = 0;
const blobs = [];
const gitlinks = [];
const omittedBlobs = [];
for (const entry of selected) {
  if (entry.type === "commit") {
    gitlinks.push(entry);
    continue;
  }
  if (entry.type !== "blob" || entry.size === null) {
    fail(`unsupported git object: ${entry.reviewPath}`);
  }
  if (entry.size > REVIEW_BLOB_MAX_BYTES) {
    omittedBlobs.push({ ...entry, reason: "individual-byte-limit" });
    continue;
  }
  if (totalBytes + entry.size > REVIEW_TOTAL_MAX_BYTES) {
    omittedBlobs.push({ ...entry, reason: "total-byte-budget" });
    continue;
  }
  totalBytes += entry.size;
  blobs.push(entry);
}
if (blobs.length + gitlinks.length + omittedBlobs.length === 0) {
  fail("review snapshot has no materializable objects");
}

const snapshotTempRoot = realpathSync(args.tempRoot ?? tmpdir());
const snapshotRoot = mkdtempSync(
  path.join(snapshotTempRoot, "deep-review-head."),
);
const metadataPath = `${snapshotRoot}.metadata.json`;
const metadataNextPath = `${metadataPath}.next.${process.pid}`;
chmodSync(snapshotRoot, 0o700);
let completed = false;
const manifest = [];
const metadata = (state) => ({
  creator: "deep-review-with-claude-and-codex",
  state,
  baseSha,
  headSha,
  createdAtMs: Date.now(),
  uid: typeof process.getuid === "function" ? process.getuid() : null,
  manifest: [...manifest].sort((left, right) =>
    left.path.localeCompare(right.path),
  ),
});
const replaceMetadata = (state, initial = false) => {
  if (initial) {
    writeFileSync(metadataPath, `${JSON.stringify(metadata(state))}\n`, {
      flag: "wx",
      mode: 0o600,
    });
    chmodSync(metadataPath, 0o400);
    return;
  }
  writeFileSync(metadataNextPath, `${JSON.stringify(metadata(state))}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  chmodSync(metadataNextPath, 0o400);
  if (process.platform !== "win32") {
    renameSync(metadataNextPath, metadataPath);
    return;
  }
  chmodSync(metadataPath, 0o600);
  try {
    renameSync(metadataNextPath, metadataPath);
  } catch (error) {
    chmodSync(metadataPath, 0o400);
    throw error;
  }
};
const cleanup = () => {
  if (completed) return;
  rmSync(snapshotRoot, { recursive: true, force: true });
  rmSync(metadataPath, { force: true });
  rmSync(metadataNextPath, { force: true });
};
try {
  replaceMetadata("building", true);
} catch (error) {
  cleanup();
  throw error;
}
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.once(signal, () => {
    cleanup();
    process.exit(128);
  });
}

try {
  await materializeBlobs(
    projectRoot,
    snapshotRoot,
    objectFormat,
    blobs,
    manifest,
  );
  if (unscannedTextCandidates.length > 0) {
    const scopeGapPath = ".deep-review-scope-gaps.txt";
    if (treeEntries.some((entry) => entry.reviewPath === scopeGapPath)) {
      fail(`repository path conflicts with generated scope marker: ${scopeGapPath}`);
    }
    const outputPath = safeOutputPath(snapshotRoot, scopeGapPath);
    const listed = unscannedTextCandidates.slice(
      0,
      REVIEW_SCOPE_GAP_PATH_MAX,
    );
    const outputContent = Buffer.from(
      [
        "DEEP_REVIEW_SNAPSHOT_SCOPE_GAP:",
        `unscanned_candidate_count=${unscannedTextCandidates.length}`,
        `text_scan_byte_limit=${REVIEW_TEXT_SCAN_MAX_BYTES}`,
        `listed_path_count=${listed.length}`,
        "The following unmodified files were not content-classified because the bounded text-scan budget was exhausted or the individual file limit was exceeded.",
        "Treat relevant listed paths as an explicit review-scope gap.",
        ...listed.map(
          (entry) => `${entry.reviewPath}\tsize=${entry.size ?? "unknown"}`,
        ),
        "",
      ].join("\n"),
      "utf8",
    );
    writeFileSync(outputPath, outputContent, {
      flag: "wx",
      mode: 0o600,
    });
    manifest.push(
      manifestEntry(scopeGapPath, outputContent, "scope-gap"),
    );
  }
  for (const omitted of omittedBlobs) {
    const outputPath = safeOutputPath(snapshotRoot, omitted.reviewPath);
    mkdirSync(path.dirname(outputPath), { recursive: true, mode: 0o700 });
    const outputContent = Buffer.from(
      [
        "REVIEW_BLOB_OMITTED:",
        `oid=${omitted.oid}`,
        `size=${omitted.size}`,
        `reason=${omitted.reason}`,
        "Review the diff metadata and report this file as an explicit review-scope gap.",
        "",
      ].join("\n"),
      "utf8",
    );
    writeFileSync(outputPath, outputContent, {
      flag: "wx",
      mode: 0o600,
    });
    manifest.push(
      manifestEntry(omitted.reviewPath, outputContent, "omitted-blob"),
    );
  }
  for (const gitlink of gitlinks) {
    const outputPath = safeOutputPath(snapshotRoot, gitlink.reviewPath);
    mkdirSync(path.dirname(outputPath), { recursive: true, mode: 0o700 });
    const outputContent = Buffer.from(`GITLINK_OID: ${gitlink.oid}\n`);
    writeFileSync(outputPath, outputContent, {
      flag: "wx",
      mode: 0o600,
    });
    manifest.push(
      manifestEntry(gitlink.reviewPath, outputContent, "gitlink"),
    );
  }

  const remainingLinks = [];
  const stack = [snapshotRoot];
  while (stack.length > 0) {
    const currentPath = stack.pop();
    const stat = lstatSync(currentPath);
    if (stat.isSymbolicLink()) remainingLinks.push(currentPath);
    if (!stat.isDirectory()) continue;
    const entries = readdirSync(currentPath);
    for (const entry of entries) stack.push(path.join(currentPath, entry));
  }
  if (remainingLinks.length > 0) fail("live symlink remained in snapshot");

  replaceMetadata("complete");

  const chmodStack = [snapshotRoot];
  while (chmodStack.length > 0) {
    const currentPath = chmodStack.pop();
    const stat = lstatSync(currentPath);
    if (stat.isDirectory()) {
      const entries = readdirSync(currentPath);
      for (const entry of entries) chmodStack.push(path.join(currentPath, entry));
    } else {
      chmodSync(currentPath, 0o400);
    }
  }
  completed = true;
  process.stdout.write(`${toBashAbsolutePath(snapshotRoot)}\n`);
} catch (error) {
  cleanup();
  throw error;
}
