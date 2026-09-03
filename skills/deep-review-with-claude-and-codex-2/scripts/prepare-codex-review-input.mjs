#!/usr/bin/env node

import { Buffer } from "node:buffer";
import { createHash, randomBytes, randomInt } from "node:crypto";
import {
  chmodSync,
  createReadStream,
  lstatSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createInterface } from "node:readline";

const SCHEMA = "deep-review-codex-input/v1";
const PROMPT_HEADING = "## 実行境界（最優先）";
const PROMPT_MAX_BYTES = 4 * 1024 * 1024;
const DIFF_TOKENS = [
  "{{CODEX_REVIEW_DIFF}}",
  "{{CLAUDE_REVIEW_DIFF}}",
];
const REPOSITORY_TOKENS = [
  "{{CODEX_REVIEW_REPOSITORY}}",
  "{{CLAUDE_REVIEW_REPOSITORY}}",
];

function fail(message) {
  throw new Error(message);
}

function usage() {
  process.stderr.write(
    [
      "Usage: prepare-codex-review-input.mjs \\",
      "  --diff <path> --snapshot <path> --prompt-template <path> \\",
      "  --run-id <id> --target <pr:N|branch:name> --head-sha <sha> \\",
      "  --expected-diff-sha256 <sha256> \\",
      "  --expected-snapshot-metadata-sha256 <sha256> \\",
      "  --result-contract <review|followup> \\",
      "  --prompt-output <path> --control-output <path>",
      "",
    ].join("\n"),
  );
}

function parseArgs(argv) {
  const parsed = {};
  const allowed = new Map([
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
    ["--prompt-output", "promptOutput"],
    ["--control-output", "controlOutput"],
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

function replacePathToken(template, tokens, replacement, label) {
  const present = tokens.filter((token) => template.includes(token));
  if (present.length !== 1) {
    fail(`prompt template must contain exactly one ${label} token`);
  }
  return template.replaceAll(present[0], () => replacement);
}

function buildPrompt(
  template,
  diffPath,
  snapshotRoot,
  receiptLine,
  probeLineNumber,
  resultContract,
) {
  const normalized = template.replaceAll("\r\n", "\n");
  if (
    normalized !== PROMPT_HEADING &&
    !normalized.startsWith(`${PROMPT_HEADING}\n`)
  ) {
    fail(`prompt template must start with: ${PROMPT_HEADING}`);
  }
  let rendered = replacePathToken(
    normalized,
    DIFF_TOKENS,
    diffPath,
    "review diff",
  );
  rendered = replacePathToken(
    rendered,
    REPOSITORY_TOKENS,
    snapshotRoot,
    "review repository",
  );

  const receiptBoundary = [
    "",
    "### 入力世代の受領証（runnerによる必須検証）",
    `- 最終回答の最初の非空行へ次を一字一句そのまま出力してください。コードフェンス、引用記号、前置きは付けません: \`${receiptLine}\``,
    `- 続く2番目の非空行には、固定差分 \`${diffPath}\` の ${probeLineNumber} 行目を実際に読み、行頭へ \`DIFF_PROBE: \` を付けて一字一句そのまま出力してください。期待する行内容はpromptに記録されていません。`,
    `- 今回のレビュー対象は固定差分 \`${diffPath}\` とHEAD snapshot \`${snapshotRoot}\` です。別世代・working tree・会話内の過去結果で代用しません。`,
    "- 差分・snapshotのいずれかを読めない場合は、findingsやNO_FINDINGSを正常結果として返さず、読めなかった対象とエラーを明記してください。受領証・DIFF_PROBEの欠落や不一致はrunnerが失敗として扱います。",
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

async function prepare(args) {
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
  assertRegularFile(args.promptTemplate, "Codex prompt template");
  if (lstatSync(args.promptTemplate).size > PROMPT_MAX_BYTES) {
    fail("Codex prompt template is too large");
  }

  const diffPath = realpathSync(args.diff);
  const snapshotRoot = realpathSync(args.snapshot);
  const promptTemplate = realpathSync(args.promptTemplate);
  const actualDiffSha256 = await sha256File(diffPath);
  if (actualDiffSha256 !== args.expectedDiffSha256) {
    fail("review diff digest mismatch before Codex input preparation");
  }

  const metadataPath = `${snapshotRoot}.metadata.json`;
  assertRegularFile(metadataPath, "snapshot metadata");
  const metadataBytes = readFileSync(metadataPath);
  if (
    sha256Buffer(metadataBytes) !==
    args.expectedSnapshotMetadataSha256
  ) {
    fail("snapshot metadata digest mismatch before Codex input preparation");
  }
  const metadata = JSON.parse(metadataBytes.toString("utf8"));
  if (
    metadata.creator !== "deep-review-with-claude-and-codex" ||
    metadata.state !== "complete" ||
    metadata.headSha !== args.headSha ||
    !Array.isArray(metadata.manifest)
  ) {
    fail("snapshot metadata identity mismatch");
  }

  const diffProbe = await selectDiffProbe(diffPath);
  const receipt = {
    schema: SCHEMA,
    runId: args.runId,
    target: args.target,
    headSha: args.headSha,
    diffSha256: args.expectedDiffSha256,
    snapshotMetadataSha256: args.expectedSnapshotMetadataSha256,
    challenge: randomBytes(32).toString("hex"),
  };
  const receiptLine = `INPUT_RECEIPT: ${JSON.stringify(receipt)}`;
  const prompt = buildPrompt(
    readFileSync(promptTemplate, "utf8"),
    diffPath,
    snapshotRoot,
    receiptLine,
    diffProbe.lineNumber,
    args.resultContract,
  );
  const promptBytes = Buffer.from(prompt, "utf8");
  const control = {
    schema: SCHEMA,
    receiptLine,
    diffProbeSha256: sha256Buffer(
      Buffer.from(`DIFF_PROBE: ${diffProbe.line}`, "utf8"),
    ),
    runId: args.runId,
    target: args.target,
    headSha: args.headSha,
    diffSha256: args.expectedDiffSha256,
    snapshotMetadataSha256: args.expectedSnapshotMetadataSha256,
    promptSha256: sha256Buffer(promptBytes),
    resultContract: args.resultContract,
  };

  try {
    writeFileSync(args.promptOutput, promptBytes, {
      flag: "wx",
      mode: 0o600,
    });
    writeFileSync(args.controlOutput, `${JSON.stringify(control, null, 2)}\n`, {
      flag: "wx",
      mode: 0o600,
    });
    chmodSync(args.promptOutput, 0o600);
    chmodSync(args.controlOutput, 0o600);
  } catch (error) {
    rmSync(args.promptOutput, { force: true });
    rmSync(args.controlOutput, { force: true });
    throw error;
  }
}

try {
  await prepare(parseArgs(process.argv.slice(2)));
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exit(1);
}
