#!/usr/bin/env node

import {
  existsSync,
  lstatSync,
  readFileSync,
  realpathSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { toNativeAbsolutePath } from "./path-interop.mjs";

const PAIR_OPTIONS = new Set([
  "--context",
  "--claude-prompt",
  "--codex-prompt",
  "--phase",
  "--round",
  "--reviewer",
  "--attempt",
  "--wave-status",
  "--wave-role",
  "--wave-supervisor-nonce",
  "--claude-resume-session-id",
  "--codex-thread-id",
]);
const WAVE_OPTIONS = new Set([
  "--context",
  "--first-round",
  "--claude-lead-prompt",
  "--codex-lead-prompt",
  "--claude-speculative-prompt",
  "--codex-speculative-prompt",
]);
const CLAUDE_FOLLOWUP_OPTIONS = new Set([
  "--context",
  "--project",
  "--prompt-template",
  "--diff",
  "--snapshot",
  "--run-id",
  "--target",
  "--head-sha",
  "--diff-sha256",
  "--snapshot-metadata-sha256",
  "--result-contract",
  "--resume-session-id",
]);

function fail(message) {
  throw new Error(message);
}

function parseOptionPairs(args, allowed, label) {
  if (args.length === 0 || args.length % 2 !== 0) {
    fail(`${label} arguments must be nonempty option/value pairs`);
  }
  const options = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const option = args[index];
    const value = args[index + 1];
    if (!allowed.has(option)) fail(`unsupported ${label} option: ${option}`);
    if (!value) fail(`${option} requires a nonempty value`);
    if (options.has(option)) fail(`duplicate ${label} option: ${option}`);
    options.set(option, value);
  }
  return options;
}

function requireOptions(options, required) {
  for (const option of required) {
    if (!options.has(option)) fail(`missing runner option: ${option}`);
  }
}

function parseArgs(argv) {
  if (
    argv[0] !== "--context" ||
    !argv[1] ||
    argv[2] !== "--mode" ||
    !argv[3]
  ) {
    fail("usage: --context <context.json> --mode <mode> [launcher options] -- <runner arguments>");
  }
  const contextPath = argv[1];
  const mode = argv[3];
  if (!new Set(["pair", "wave", "claude-followup"]).has(mode)) {
    fail(`unsupported reviewer launch mode: ${mode}`);
  }
  let stdoutPath = null;
  let stderrPath = null;
  let index = 4;
  while (index < argv.length && argv[index] !== "--") {
    const option = argv[index];
    const value = argv[index + 1];
    if (!new Set(["--stdout-path", "--stderr-path"]).has(option)) {
      fail(`unsupported launcher option: ${option}`);
    }
    if (!value) fail(`${option} requires a nonempty value`);
    if (option === "--stdout-path") {
      if (stdoutPath) fail(`duplicate launcher option: ${option}`);
      stdoutPath = value;
    } else {
      if (stderrPath) fail(`duplicate launcher option: ${option}`);
      stderrPath = value;
    }
    index += 2;
  }
  if (argv[index] !== "--") fail("launcher arguments must end with --");
  const runnerArgs = argv.slice(index + 1);
  if (mode === "claude-followup") {
    if (!stdoutPath || !stderrPath) {
      fail("claude-followup requires --stdout-path and --stderr-path");
    }
  } else if (stdoutPath || stderrPath) {
    fail("output paths are only valid for claude-followup");
  }
  const allowed =
    mode === "pair"
      ? PAIR_OPTIONS
      : mode === "wave"
        ? WAVE_OPTIONS
        : CLAUDE_FOLLOWUP_OPTIONS;
  return {
    contextPath,
    mode,
    stdoutPath,
    stderrPath,
    options: parseOptionPairs(runnerArgs, allowed, mode),
  };
}

function requiredString(object, key) {
  const value = object[key];
  if (typeof value !== "string" || value.length === 0) {
    fail(`context.${key} must be a nonempty string`);
  }
  return value;
}

function requiredReviewerConfig(context) {
  const config = context.reviewerConfig;
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    fail("context.reviewerConfig must be an object");
  }
  const claude = config.claude;
  const codex = config.codex;
  if (!claude || typeof claude !== "object" || Array.isArray(claude)) {
    fail("context.reviewerConfig.claude must be an object");
  }
  if (!codex || typeof codex !== "object" || Array.isArray(codex)) {
    fail("context.reviewerConfig.codex must be an object");
  }
  return {
    claude: {
      model: requiredString(claude, "model"),
      effort: requiredString(claude, "effort"),
    },
    codex: {
      model: requiredString(codex, "model"),
      reasoningEffort: requiredString(codex, "reasoningEffort"),
    },
  };
}

function assertOwnedEntry(input, kind, label, expectedMode = null) {
  const stat = lstatSync(input);
  if (stat.isSymbolicLink()) fail(`${label} must not be a symlink`);
  if (kind === "file" && !stat.isFile()) fail(`${label} must be a file`);
  if (kind === "directory" && !stat.isDirectory()) {
    fail(`${label} must be a directory`);
  }
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
    fail(`${label} must be owned by the current user`);
  }
  if (expectedMode !== null && process.platform !== "win32") {
    const actualMode = stat.mode & 0o777;
    if (actualMode !== expectedMode) {
      fail(`${label} mode must be ${expectedMode.toString(8)}, got ${actualMode.toString(8)}`);
    }
  }
}

function canonicalExisting(input, label) {
  const hostInput = toNativeAbsolutePath(input);
  if (!path.isAbsolute(hostInput)) fail(`${label} must be absolute`);
  const resolved = path.resolve(hostInput);
  const canonical = realpathSync(hostInput);
  if (resolved !== canonical) {
    fail(`${label} must be a canonical path without symlink traversal`);
  }
  return canonical;
}

function sameCanonicalPath(actual, expected, label) {
  const actualCanonical = canonicalExisting(actual, label);
  const expectedCanonical = canonicalExisting(expected, `context ${label}`);
  if (actualCanonical !== expectedCanonical) {
    fail(`${label} does not match the review context`);
  }
  return actualCanonical;
}

function assertDescendant(input, root, label) {
  const canonical = canonicalExisting(input, label);
  if (canonical === root || !canonical.startsWith(`${root}${path.sep}`)) {
    fail(`${label} must be inside the review run namespace`);
  }
  return canonical;
}

function assertPrompt(input, runRoot, label) {
  const canonical = assertDescendant(input, runRoot, label);
  assertOwnedEntry(canonical, "file", label, 0o400);
  return canonical;
}

function assertContext(contextPath, context) {
  const canonicalContext = canonicalExisting(contextPath, "context path");
  assertOwnedEntry(canonicalContext, "file", "context path", 0o400);
  const artifactDir = canonicalExisting(
    requiredString(context, "reviewArtifactDir"),
    "review artifact directory",
  );
  assertOwnedEntry(artifactDir, "directory", "review artifact directory", 0o700);
  if (canonicalContext !== path.join(artifactDir, "context.json")) {
    fail("context path must be reviewArtifactDir/context.json");
  }
  return { canonicalContext, artifactDir };
}

function assertRunNamespace(context) {
  const reviewRunId = requiredString(context, "reviewRunId");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(reviewRunId)) {
    fail("context.reviewRunId must be a UUIDv4");
  }
  const tempRoot = canonicalExisting(
    requiredString(context, "reviewTempRoot"),
    "review temporary root",
  );
  const runRoot = canonicalExisting(
    requiredString(context, "reviewRunRoot"),
    "review run root",
  );
  assertOwnedEntry(runRoot, "directory", "review run root", 0o700);
  if (
    path.dirname(runRoot) !== tempRoot ||
    !path.basename(runRoot).startsWith(`deep-review.${reviewRunId}.`)
  ) {
    fail("review run root is outside its fixed temporary namespace");
  }
  const skillDir = canonicalExisting(
    requiredString(context, "skillDir"),
    "run-specific skill directory",
  );
  assertOwnedEntry(skillDir, "directory", "run-specific skill directory", 0o700);
  if (skillDir !== path.join(runRoot, "tooling")) {
    fail("run-specific skill directory must be reviewRunRoot/tooling");
  }
  return { runRoot, skillDir };
}

function assertRunnerContext(options, canonicalContext) {
  requireOptions(options, ["--context"]);
  if (canonicalExisting(options.get("--context"), "runner --context") !== canonicalContext) {
    fail("runner --context does not match launcher context");
  }
}

function assertPair(options, canonicalContext, runRoot, artifactDir) {
  requireOptions(options, ["--context", "--phase", "--reviewer", "--attempt"]);
  assertRunnerContext(options, canonicalContext);
  const phase = options.get("--phase");
  const reviewer = options.get("--reviewer");
  const attempt = options.get("--attempt");
  const round = options.get("--round");
  if (!new Set(["primary", "convergence"]).has(phase)) {
    fail("--phase must be primary or convergence");
  }
  if (!new Set(["both", "claude", "codex"]).has(reviewer)) {
    fail("--reviewer must be both, claude, or codex");
  }
  if (!/^[1-9][0-9]*$/u.test(attempt)) fail("--attempt must be positive");
  if (attempt === "1" && reviewer !== "both") {
    fail("attempt 1 must launch both reviewers");
  }
  if (phase === "primary" && round) fail("primary must not specify --round");
  if (phase === "convergence" && (!round || !/^[1-9][0-9]*$/u.test(round) || Number(round) > 20)) {
    fail("convergence requires --round 1..20");
  }
  const wantsClaude = reviewer === "both" || reviewer === "claude";
  const wantsCodex = reviewer === "both" || reviewer === "codex";
  if (wantsClaude !== options.has("--claude-prompt")) {
    fail("--claude-prompt must match the selected reviewer");
  }
  if (wantsCodex !== options.has("--codex-prompt")) {
    fail("--codex-prompt must match the selected reviewer");
  }
  if (wantsClaude) assertPrompt(options.get("--claude-prompt"), runRoot, "Claude prompt");
  if (wantsCodex) assertPrompt(options.get("--codex-prompt"), runRoot, "Codex prompt");
  if (options.has("--claude-resume-session-id") && (!wantsClaude || attempt === "1")) {
    fail("Claude resume ID is invalid for this attempt");
  }
  if (options.has("--codex-thread-id") && (!wantsCodex || attempt === "1")) {
    fail("Codex thread ID is invalid for this attempt");
  }
  const waveStatus = options.get("--wave-status");
  const waveRole = options.get("--wave-role");
  const waveNonce = options.get("--wave-supervisor-nonce");
  if (Boolean(waveStatus) !== Boolean(waveRole)) {
    fail("--wave-status and --wave-role must be supplied together");
  }
  if (waveStatus) {
    if (phase !== "convergence" || !new Set(["lead", "speculative"]).has(waveRole)) {
      fail("wave pair options are only valid for convergence lead/speculative roles");
    }
    const canonicalWaveStatus = canonicalExisting(waveStatus, "wave status");
    assertOwnedEntry(canonicalWaveStatus, "file", "wave status");
    const waveRoot = path.join(artifactDir, "phase4", "waves");
    if (!canonicalWaveStatus.startsWith(`${waveRoot}${path.sep}`)) {
      fail("wave status must be inside reviewArtifactDir/phase4/waves");
    }
  }
  if ((attempt === "1" && Boolean(waveStatus)) !== Boolean(waveNonce)) {
    fail("wave supervisor nonce is valid only for wave attempt 1");
  }
}

function assertWave(options, canonicalContext, runRoot) {
  const required = [
    "--context",
    "--first-round",
    "--claude-lead-prompt",
    "--codex-lead-prompt",
    "--claude-speculative-prompt",
    "--codex-speculative-prompt",
  ];
  requireOptions(options, required);
  if (options.size !== required.length) fail("wave runner received extra options");
  assertRunnerContext(options, canonicalContext);
  const round = options.get("--first-round");
  if (!/^[1-9][0-9]*$/u.test(round) || Number(round) > 19) {
    fail("--first-round must be 1..19");
  }
  for (const option of required.slice(2)) {
    assertPrompt(options.get(option), runRoot, option);
  }
}

function assertOutputPath(input, artifactDir, basename, label) {
  const nativeInput = toNativeAbsolutePath(input);
  if (!path.isAbsolute(nativeInput)) fail(`${label} must be absolute`);
  if (existsSync(nativeInput)) fail(`${label} must not already exist`);
  const resolved = path.resolve(nativeInput);
  const parent = canonicalExisting(path.dirname(nativeInput), `${label} directory`);
  assertOwnedEntry(parent, "directory", `${label} directory`, 0o700);
  if (resolved !== path.join(parent, basename)) {
    fail(`${label} must use the canonical ${basename} path`);
  }
  const relative = path.relative(path.join(artifactDir, "phase3"), parent);
  if (!/^followup-[1-9][0-9]*$/u.test(relative)) {
    fail(`${label} must be in a fresh phase3/followup-N directory`);
  }
  return resolved;
}

function assertClaudeFollowup(options, context, canonicalContext, runRoot, artifactDir, stdoutPath, stderrPath) {
  const required = [...CLAUDE_FOLLOWUP_OPTIONS];
  requireOptions(options, required);
  if (options.size !== required.length) fail("Claude follow-up runner received extra options");
  assertRunnerContext(options, canonicalContext);
  const pathOptions = [
    ["--project", "projectRoot"],
    ["--diff", "diffFile"],
    ["--snapshot", "reviewSnapshotDir"],
  ];
  for (const [option, key] of pathOptions) {
    sameCanonicalPath(options.get(option), requiredString(context, key), option);
  }
  const exactOptions = [
    ["--run-id", "reviewRunId"],
    ["--target", "target"],
    ["--head-sha", "headSha"],
    ["--diff-sha256", "diffSha256"],
    ["--snapshot-metadata-sha256", "snapshotMetadataSha256"],
  ];
  for (const [option, key] of exactOptions) {
    if (options.get(option) !== requiredString(context, key)) {
      fail(`${option} does not match the review context`);
    }
  }
  if (options.get("--result-contract") !== "followup") {
    fail("Claude follow-up must use --result-contract followup");
  }
  assertPrompt(options.get("--prompt-template"), runRoot, "Claude follow-up prompt");
  const stdout = assertOutputPath(stdoutPath, artifactDir, "claude.out", "Claude follow-up stdout");
  const stderr = assertOutputPath(stderrPath, artifactDir, "claude.err", "Claude follow-up stderr");
  if (path.dirname(stdout) !== path.dirname(stderr)) {
    fail("Claude follow-up stdout and stderr must share one fresh directory");
  }
}

try {
  const parsed = parseArgs(process.argv.slice(2));
  const context = JSON.parse(readFileSync(parsed.contextPath, "utf8"));
  if (!context || typeof context !== "object" || Array.isArray(context)) {
    fail("context must be a JSON object");
  }
  const { canonicalContext, artifactDir } = assertContext(parsed.contextPath, context);
  const { runRoot, skillDir } = assertRunNamespace(context);
  const scriptDir = realpathSync(path.dirname(fileURLToPath(import.meta.url)));
  const trustedSkillDir = realpathSync(path.resolve(scriptDir, ".."));
  const launcherPath = realpathSync(path.join(scriptDir, "launch-run-reviewer.sh"));
  if (canonicalExisting(requiredString(context, "reviewerLauncherPath"), "context reviewer launcher") !== launcherPath) {
    fail("context reviewer launcher does not match this installed skill");
  }

  if (parsed.mode === "pair") {
    assertPair(parsed.options, canonicalContext, runRoot, artifactDir);
  } else if (parsed.mode === "wave") {
    assertWave(parsed.options, canonicalContext, runRoot);
  } else {
    assertClaudeFollowup(
      parsed.options,
      context,
      canonicalContext,
      runRoot,
      artifactDir,
      parsed.stdoutPath,
      parsed.stderrPath,
    );
  }

  const runnerName =
    parsed.mode === "pair"
      ? "run-review-pair.sh"
      : parsed.mode === "wave"
        ? "run-review-wave.sh"
        : "run-claude-attested.sh";
  const runnerPath = canonicalExisting(
    path.join(skillDir, "scripts", runnerName),
    `run-specific ${parsed.mode} runner`,
  );
  assertOwnedEntry(runnerPath, "file", `run-specific ${parsed.mode} runner`, 0o500);
  const toolingDigest = requiredString(context, "toolingDigest");
  if (!/^[0-9a-f]{64}$/u.test(toolingDigest)) {
    fail("context.toolingDigest must be a SHA-256 digest");
  }
  process.stdout.write(
    `${JSON.stringify({
      trustedSkillDir,
      skillDir,
      toolingDigest,
      runnerPath,
      reviewerConfig: requiredReviewerConfig(context),
    })}\n`,
  );
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exitCode = 1;
}
