#!/usr/bin/env node

import { Buffer } from "node:buffer";
import { createHash, randomBytes, randomInt } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  createReadStream,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { createInterface } from "node:readline";

const SCHEMA = "deep-review-claude-input/v1";
const PROMPT_HEADING = "## 実行境界（最優先）";
const DIFF_TOKEN = "{{CLAUDE_REVIEW_DIFF}}";
const REPOSITORY_TOKEN = "{{CLAUDE_REVIEW_REPOSITORY}}";
const PROMPT_MAX_BYTES = 4 * 1024 * 1024;
const STALE_AFTER_MS = 7 * 24 * 60 * 60 * 1000;
const STALE_SCAN_ENTRY_MAX = 20_000;

function fail(message) {
  throw new Error(message);
}

function usage() {
  process.stderr.write(
    [
      "Usage:",
      "  prepare-claude-review-input.mjs \\",
      "    --temp-root <path> --input-dir <path> \\",
      "    --diff <path> --snapshot <path> --prompt-template <path> \\",
      "    --run-id <id> --target <pr:N|branch:name> --head-sha <sha> \\",
      "    --expected-diff-sha256 <sha256> \\",
      "    --expected-snapshot-metadata-sha256 <sha256> \\",
      "    --result-contract <review|followup> --control <path>",
      "  prepare-claude-review-input.mjs --cleanup-control <path>",
      "",
    ].join("\n"),
  );
}

function parseArgs(argv) {
  if (argv.length === 2 && argv[0] === "--cleanup-control") {
    return { cleanupControl: argv[1] };
  }

  const parsed = {};
  const allowed = new Map([
    ["--temp-root", "tempRoot"],
    ["--input-dir", "inputDir"],
    ["--diff", "diff"],
    ["--snapshot", "snapshot"],
    ["--prompt-template", "promptTemplate"],
    ["--run-id", "runId"],
    ["--target", "target"],
    ["--head-sha", "headSha"],
    ["--expected-diff-sha256", "expectedDiffSha256"],
    [
      "--expected-snapshot-metadata-sha256",
      "expectedSnapshotMetadataSha256",
    ],
    ["--result-contract", "resultContract"],
    ["--control", "control"],
  ]);

  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    const key = allowed.get(flag);
    if (!key || value === undefined) {
      usage();
      fail(`invalid argument: ${flag ?? "<missing>"}`);
    }
    if (parsed[key] !== undefined) fail(`duplicate argument: ${flag}`);
    parsed[key] = value;
  }

  for (const key of allowed.values()) {
    if (!parsed[key]) {
      usage();
      fail(`missing required argument: ${key}`);
    }
  }
  return parsed;
}

function assertRegularFile(filePath, label) {
  const stat = lstatSync(filePath);
  if (stat.isSymbolicLink() || !stat.isFile()) {
    fail(`${label} must be a regular non-symlink file`);
  }
}

function assertDirectory(directoryPath, label) {
  const stat = lstatSync(directoryPath);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fail(`${label} must be a regular non-symlink directory`);
  }
}

function sha256Buffer(content) {
  return createHash("sha256").update(content).digest("hex");
}

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(filePath);
    stream.on("error", reject);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

async function selectDiffProbe(diffPath) {
  const lines = createInterface({
    input: createReadStream(diffPath),
    crlfDelay: Number.POSITIVE_INFINITY,
  });
  let lineNumber = 0;
  let candidateCount = 0;
  let selected;
  for await (const line of lines) {
    lineNumber += 1;
    if (
      !line.startsWith("diff --git ") ||
      Buffer.byteLength(line, "utf8") > 4096
    ) {
      continue;
    }
    candidateCount += 1;
    if (randomInt(candidateCount) === 0) {
      selected = { lineNumber, line };
    }
  }
  if (!selected) {
    fail("review diff has no bounded diff --git header for an access probe");
  }
  return selected;
}

function safeOutputPath(root, relativePath) {
  const outputPath = path.resolve(root, relativePath);
  if (!outputPath.startsWith(`${root}${path.sep}`)) {
    fail(`snapshot path escapes root: ${relativePath}`);
  }
  return outputPath;
}

function validateIdentifier(value, label, pattern, maxLength) {
  if (
    value.length > maxLength ||
    value.includes("\n") ||
    value.includes("\r") ||
    !pattern.test(value)
  ) {
    fail(`invalid ${label}`);
  }
}

function hasControlCharacter(value) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x1f || code === 0x7f) return true;
  }
  return false;
}

function validateTarget(value) {
  const isPullRequest = /^pr:[0-9]+$/.test(value);
  const isBranch =
    value.startsWith("branch:") &&
    value.length > "branch:".length &&
    !hasControlCharacter(value);
  if (value.length > 256 || (!isPullRequest && !isBranch)) {
    fail("invalid target");
  }
}

function loadSnapshotMetadata(snapshotRoot, expectedHeadSha, expectedDigest) {
  const metadataPath = `${snapshotRoot}.metadata.json`;
  assertRegularFile(metadataPath, "snapshot metadata");
  const bytes = readFileSync(metadataPath);
  if (sha256Buffer(bytes) !== expectedDigest) {
    fail("snapshot metadata digest mismatch before Claude input preparation");
  }
  const metadata = JSON.parse(bytes.toString("utf8"));
  if (
    metadata.creator !== "deep-review-with-claude-and-codex" ||
    metadata.state !== "complete" ||
    metadata.headSha !== expectedHeadSha ||
    !Array.isArray(metadata.manifest)
  ) {
    fail("snapshot metadata identity mismatch");
  }
  return { bytes, metadata };
}

function collectSnapshotFiles(snapshotRoot) {
  const files = [];
  const stack = [snapshotRoot];
  while (stack.length > 0) {
    const current = stack.pop();
    const stat = lstatSync(current);
    if (stat.isSymbolicLink()) fail("live symlink found in review snapshot");
    if (stat.isDirectory()) {
      for (const entry of readdirSync(current)) {
        stack.push(path.join(current, entry));
      }
      continue;
    }
    if (!stat.isFile()) fail("unsupported review snapshot entry type");
    files.push(current);
  }
  return files;
}

function hasUnsafeStaleEntry(root) {
  const stack = [root];
  let entryCount = 0;
  while (stack.length > 0) {
    const current = stack.pop();
    const stat = lstatSync(current);
    if (stat.isSymbolicLink()) return true;
    entryCount += 1;
    if (entryCount > STALE_SCAN_ENTRY_MAX) return true;
    if (!stat.isDirectory()) continue;
    for (const entry of readdirSync(current)) {
      stack.push(path.join(current, entry));
    }
  }
  return false;
}

function cleanupStaleInputs(tempRoot) {
  const tmpRoot = realpathSync(tempRoot);
  const currentUid =
    typeof process.getuid === "function" ? process.getuid() : undefined;
  for (const entry of readdirSync(tmpRoot)) {
    if (!/^claude-review-input\.[A-Za-z0-9]+$/.test(entry)) continue;
    const candidate = path.join(tmpRoot, entry);
    try {
      const stat = lstatSync(candidate);
      if (
        stat.isSymbolicLink() ||
        !stat.isDirectory() ||
        (currentUid !== undefined && stat.uid !== currentUid) ||
        Date.now() - stat.mtimeMs <= STALE_AFTER_MS
      ) {
        continue;
      }
      const lifecyclePath = path.join(
        candidate,
        ".claude-review-lifecycle.json",
      );
      const ownerPath = path.join(candidate, ".claude-review-owner");
      assertRegularFile(lifecyclePath, "Claude review lifecycle");
      assertRegularFile(ownerPath, "Claude review input owner marker");
      const lifecycle = JSON.parse(readFileSync(lifecyclePath, "utf8"));
      const ownerToken = readFileSync(ownerPath, "utf8").trim();
      if (
        lifecycle.schema !== SCHEMA ||
        lifecycle.creator !==
          "deep-review-with-claude-and-codex" ||
        !["building", "complete"].includes(lifecycle.state) ||
        lifecycle.ownerToken !== ownerToken ||
        !/^[0-9a-f]{64}$/.test(ownerToken) ||
        hasUnsafeStaleEntry(candidate)
      ) {
        continue;
      }
      rmSync(candidate, { recursive: true });
    } catch {
      // Unsafe or malformed candidates are not ours to remove. Keep scanning.
    }
  }
}

function copyVerifiedSnapshot(snapshotRoot, destinationRoot, metadata) {
  const expected = new Map();
  for (const entry of metadata.manifest) {
    if (
      typeof entry?.path !== "string" ||
      typeof entry?.size !== "number" ||
      typeof entry?.sha256 !== "string" ||
      !/^[0-9a-f]{64}$/.test(entry.sha256) ||
      expected.has(entry.path)
    ) {
      fail("invalid snapshot manifest entry");
    }
    expected.set(entry.path, entry);
  }

  const sourceFiles = collectSnapshotFiles(snapshotRoot);
  if (sourceFiles.length !== expected.size) {
    fail("snapshot manifest entry set mismatch before Claude input preparation");
  }

  for (const sourcePath of sourceFiles) {
    const relativePath = path
      .relative(snapshotRoot, sourcePath)
      .split(path.sep)
      .join("/");
    const entry = expected.get(relativePath);
    if (!entry) fail(`unexpected snapshot file: ${relativePath}`);
    const sourceContent = readFileSync(sourcePath);
    if (
      sourceContent.length !== entry.size ||
      sha256Buffer(sourceContent) !== entry.sha256
    ) {
      fail(`snapshot content mismatch before copy: ${relativePath}`);
    }

    const destinationPath = safeOutputPath(destinationRoot, relativePath);
    mkdirSync(path.dirname(destinationPath), { recursive: true, mode: 0o700 });
    writeFileSync(destinationPath, sourceContent, {
      flag: "wx",
      mode: 0o600,
    });
    const copiedContent = readFileSync(destinationPath);
    if (
      copiedContent.length !== entry.size ||
      sha256Buffer(copiedContent) !== entry.sha256
    ) {
      fail(`snapshot content mismatch after copy: ${relativePath}`);
    }
  }
}

function replaceRequiredToken(template, token, replacement) {
  if (!template.includes(token)) {
    fail(`prompt template is missing required token: ${token}`);
  }
  return template.replaceAll(token, () => replacement);
}

function buildPrompt(
  template,
  attestationPath,
  diffPath,
  repositoryPath,
  resultContract,
) {
  const normalized = template.replaceAll("\r\n", "\n");
  if (
    normalized !== PROMPT_HEADING &&
    !normalized.startsWith(`${PROMPT_HEADING}\n`)
  ) {
    fail(`prompt template must start with: ${PROMPT_HEADING}`);
  }

  let rendered = replaceRequiredToken(normalized, DIFF_TOKEN, diffPath);
  rendered = replaceRequiredToken(
    rendered,
    REPOSITORY_TOKEN,
    repositoryPath,
  );

  const receiptBoundary = [
    "",
    "### 入力世代の受領証（runnerによる必須検証）",
    `- 最初に Read で \`${attestationPath}\` を読み、JSON の \`receiptLine\` を最終回答の最初の非空行へ一字一句そのまま出力してください。コードフェンス、引用記号、前置きは付けません。`,
    "- 続く2番目の非空行には、attestation JSON の `diffProbeLineNumber` が示す差分行を実際に Read し、行頭へ `DIFF_PROBE: ` を付けて一字一句そのまま出力してください。期待する行内容はmanifestやpromptには記録されていません。",
    `- 今回のレビュー対象はmanifestに記録された差分 \`${diffPath}\` とHEAD snapshot \`${repositoryPath}\` です。別世代・working tree・会話内の過去結果で代用しません。`,
    "- manifest、差分、snapshotのいずれかを読めない場合は、findingsやNO_FINDINGSを正常結果として返さず、読めなかった対象を明記してください。受領証の欠落・不一致はrunnerが失敗として扱います。",
    resultContract === "review"
      ? "- 通常レビューの各findingは `High: ...`、`[High] ...`、`H1. ...`、重要度見出し＋実内容、または `Severity` 列と `Finding` 列を持つMarkdown表のいずれかで出力してください（重要度はCritical/High/Medium/Low）。0件の場合は `NO_FINDINGS`、非空の `scope: ...`、非空の `reason: ...` を出力してください。"
      : "- Phase 3の追加事実確認として、質問への非空回答を出力してください。通常レビューや収束レビューの代用にはしません。",
    "- 受領証とDIFF_PROBEの次行以降には、従来どおりレビュー本文だけを出力してください。受領証とDIFF_PROBEはレビュー観点・重要度・品質基準を変更しません。",
  ].join("\n");

  return rendered.replace(
    PROMPT_HEADING,
    () => `${PROMPT_HEADING}${receiptBoundary}`,
  );
}

function validateManagedInputPath(inputDir, tempRoot) {
  const tmpRoot = realpathSync(tempRoot);
  const inputReal = realpathSync(inputDir);
  if (
    path.dirname(inputReal) !== tmpRoot ||
    !/^claude-review-input\.[A-Za-z0-9]+$/.test(path.basename(inputReal))
  ) {
    fail("refusing to clean an unmanaged Claude review input directory");
  }
  assertDirectory(inputReal, "Claude review input");
  return inputReal;
}

function cleanupFromControl(controlPath) {
  if (!controlPath) fail("cleanup control path is required");
  if (!lstatSync(controlPath).isFile()) fail("cleanup control is not a file");
  const control = JSON.parse(readFileSync(controlPath, "utf8"));
  if (
    typeof control.tempRoot !== "string" ||
    typeof control.inputDir !== "string" ||
    typeof control.ownerToken !== "string" ||
    !/^[0-9a-f]{64}$/.test(control.ownerToken)
  ) {
    fail("invalid Claude review cleanup control");
  }

  let inputReal;
  try {
    inputReal = validateManagedInputPath(control.inputDir, control.tempRoot);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  const ownerPath = path.join(inputReal, ".claude-review-owner");
  assertRegularFile(ownerPath, "Claude review input owner marker");
  if (readFileSync(ownerPath, "utf8").trim() !== control.ownerToken) {
    fail("Claude review input owner mismatch; refusing cleanup");
  }
  rmSync(inputReal, { recursive: true });
}

async function prepare(args) {
  const tempRoot = realpathSync(args.tempRoot);
  cleanupStaleInputs(tempRoot);
  validateIdentifier(args.runId, "run-id", /^[A-Za-z0-9._:-]+$/, 128);
  validateTarget(args.target);
  validateIdentifier(args.headSha, "HEAD SHA", /^[0-9a-f]{40,64}$/, 64);
  validateIdentifier(
    args.expectedDiffSha256,
    "diff SHA-256",
    /^[0-9a-f]{64}$/,
    64,
  );
  validateIdentifier(
    args.expectedSnapshotMetadataSha256,
    "snapshot metadata SHA-256",
    /^[0-9a-f]{64}$/,
    64,
  );
  if (!["review", "followup"].includes(args.resultContract)) {
    fail("result-contract must be review or followup");
  }

  assertRegularFile(args.diff, "review diff");
  assertDirectory(args.snapshot, "review snapshot");
  assertRegularFile(args.promptTemplate, "Claude prompt template");
  const promptStat = lstatSync(args.promptTemplate);
  if (promptStat.size > PROMPT_MAX_BYTES) fail("Claude prompt template is too large");

  const diffPath = realpathSync(args.diff);
  const snapshotRoot = realpathSync(args.snapshot);
  const actualDiffSha256 = await sha256File(diffPath);
  if (actualDiffSha256 !== args.expectedDiffSha256) {
    fail("review diff digest mismatch before Claude input preparation");
  }
  const diffProbe = await selectDiffProbe(diffPath);
  const { bytes: metadataBytes, metadata } = loadSnapshotMetadata(
    snapshotRoot,
    args.headSha,
    args.expectedSnapshotMetadataSha256,
  );

  let inputDir;
  try {
    inputDir = validateManagedInputPath(args.inputDir, tempRoot);
    if (readdirSync(inputDir).length !== 0) {
      fail("Claude review input directory must be empty before preparation");
    }
    chmodSync(inputDir, 0o700);
    const ownerToken = randomBytes(32).toString("hex");

    const destinationDiff = path.join(inputDir, "review.diff");
    const destinationRepository = path.join(inputDir, "repository");
    const destinationMetadata = path.join(
      inputDir,
      "review-snapshot.metadata.json",
    );
    const attestationPath = path.join(
      inputDir,
      "review-input-attestation.json",
    );
    const promptPath = path.join(inputDir, "claude-prompt-attested.txt");
    const ownerPath = path.join(inputDir, ".claude-review-owner");
    const lifecyclePath = path.join(
      inputDir,
      ".claude-review-lifecycle.json",
    );

    writeFileSync(ownerPath, `${ownerToken}\n`, {
      flag: "wx",
      mode: 0o600,
    });
    writeFileSync(
      lifecyclePath,
      `${JSON.stringify({
        schema: SCHEMA,
        creator: "deep-review-with-claude-and-codex",
        state: "building",
        ownerToken,
      })}\n`,
      { flag: "wx", mode: 0o600 },
    );

    copyFileSync(diffPath, destinationDiff);
    chmodSync(destinationDiff, 0o600);
    if ((await sha256File(destinationDiff)) !== args.expectedDiffSha256) {
      fail("review diff digest mismatch after Claude input copy");
    }

    mkdirSync(destinationRepository, { mode: 0o700 });
    copyVerifiedSnapshot(snapshotRoot, destinationRepository, metadata);
    writeFileSync(destinationMetadata, metadataBytes, {
      flag: "wx",
      mode: 0o600,
    });

    const challenge = randomBytes(32).toString("hex");
    const receipt = {
      schema: SCHEMA,
      runId: args.runId,
      target: args.target,
      headSha: args.headSha,
      diffSha256: args.expectedDiffSha256,
      snapshotMetadataSha256: args.expectedSnapshotMetadataSha256,
      challenge,
    };
    const receiptLine = `INPUT_RECEIPT: ${JSON.stringify(receipt)}`;
    const attestation = {
      ...receipt,
      diffFile: destinationDiff,
      repositoryDir: destinationRepository,
      snapshotMetadataFile: destinationMetadata,
      diffProbeLineNumber: diffProbe.lineNumber,
      receiptLine,
    };
    writeFileSync(attestationPath, `${JSON.stringify(attestation, null, 2)}\n`, {
      flag: "wx",
      mode: 0o600,
    });

    const template = readFileSync(args.promptTemplate, "utf8");
    const prompt = buildPrompt(
      template,
      attestationPath,
      destinationDiff,
      destinationRepository,
      args.resultContract,
    );
    writeFileSync(promptPath, prompt, { flag: "wx", mode: 0o600 });

    const control = {
      schema: SCHEMA,
      tempRoot,
      inputDir,
      promptFile: promptPath,
      ownerToken,
      receiptLine,
      diffProbeSha256: sha256Buffer(
        Buffer.from(`DIFF_PROBE: ${diffProbe.line}`, "utf8"),
      ),
      runId: args.runId,
      target: args.target,
      headSha: args.headSha,
      diffSha256: args.expectedDiffSha256,
      snapshotMetadataSha256: args.expectedSnapshotMetadataSha256,
      resultContract: args.resultContract,
    };
    writeFileSync(args.control, `${JSON.stringify(control, null, 2)}\n`, {
      flag: "wx",
      mode: 0o600,
    });
    const lifecycleNext = `${lifecyclePath}.next`;
    writeFileSync(
      lifecycleNext,
      `${JSON.stringify({
        schema: SCHEMA,
        creator: "deep-review-with-claude-and-codex",
        state: "complete",
        ownerToken,
      })}\n`,
      { flag: "wx", mode: 0o600 },
    );
    renameSync(lifecycleNext, lifecyclePath);
    process.stdout.write(`prepared run-id ${args.runId}\n`);
  } catch (error) {
    if (inputDir) rmSync(inputDir, { recursive: true, force: true });
    throw error;
  }
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.cleanupControl) {
    cleanupFromControl(args.cleanupControl);
  } else {
    await prepare(args);
  }
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exit(1);
}
