#!/usr/bin/env node

import {
  lstatSync,
  readFileSync,
  realpathSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { toNativeAbsolutePath } from "./path-interop.mjs";

const REQUIRED_RUNNER_OPTIONS = new Set([
  "--project",
  "--temp-root",
  "--prompt-template",
  "--diff",
  "--snapshot",
  "--run-id",
  "--target",
  "--head-sha",
  "--diff-sha256",
  "--snapshot-metadata-sha256",
  "--result-contract",
]);
const OPTIONAL_RUNNER_OPTIONS = new Set(["--thread-id"]);

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  if (argv[0] !== "--context" || !argv[1] || argv[2] !== "--") {
    fail("usage: --context <context.json> -- <run-codex.sh arguments>");
  }
  const runnerArgs = argv.slice(3);
  if (runnerArgs.length === 0 || runnerArgs.length % 2 !== 0) {
    fail("runner arguments must be nonempty option/value pairs");
  }
  const options = new Map();
  for (let index = 0; index < runnerArgs.length; index += 2) {
    const option = runnerArgs[index];
    const value = runnerArgs[index + 1];
    if (
      !REQUIRED_RUNNER_OPTIONS.has(option) &&
      !OPTIONAL_RUNNER_OPTIONS.has(option)
    ) {
      fail(`unsupported runner option: ${option}`);
    }
    if (!value) fail(`${option} requires a nonempty value`);
    if (options.has(option)) fail(`duplicate runner option: ${option}`);
    options.set(option, value);
  }
  for (const option of REQUIRED_RUNNER_OPTIONS) {
    if (!options.has(option)) fail(`missing runner option: ${option}`);
  }
  return { contextPath: argv[1], options, runnerArgs };
}

function requiredString(object, key) {
  const value = object[key];
  if (typeof value !== "string" || value.length === 0) {
    fail(`context.${key} must be a nonempty string`);
  }
  return value;
}

function requiredReviewerConfig(context) {
  const reviewerConfig = context.reviewerConfig;
  if (
    !reviewerConfig ||
    typeof reviewerConfig !== "object" ||
    Array.isArray(reviewerConfig)
  ) {
    fail("context.reviewerConfig must be an object");
  }
  const claude = reviewerConfig.claude;
  const codex = reviewerConfig.codex;
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

function requiredReviewerConfigSources(context) {
  const sources = context.reviewerConfigSources;
  if (!sources || typeof sources !== "object" || Array.isArray(sources)) {
    fail("context.reviewerConfigSources must be an object");
  }
  const claude = sources.claude;
  const codex = sources.codex;
  if (!claude || typeof claude !== "object" || Array.isArray(claude)) {
    fail("context.reviewerConfigSources.claude must be an object");
  }
  if (!codex || typeof codex !== "object" || Array.isArray(codex)) {
    fail("context.reviewerConfigSources.codex must be an object");
  }
  const allowed = new Set(["environment", "config-file"]);
  const source = (object, key) => {
    const value = requiredString(object, key);
    if (!allowed.has(value)) {
      fail(`context reviewer config source is invalid: ${value}`);
    }
    return value;
  };
  return {
    claude: {
      model: source(claude, "model"),
      effort: source(claude, "effort"),
    },
    codex: {
      model: source(codex, "model"),
      reasoningEffort: source(codex, "reasoningEffort"),
    },
  };
}

function assertPrivateEntry(input, kind, expectedMode, label) {
  const stat = lstatSync(input);
  if (stat.isSymbolicLink()) fail(`${label} must not be a symlink`);
  if (kind === "file" && !stat.isFile()) fail(`${label} must be a file`);
  if (kind === "directory" && !stat.isDirectory()) {
    fail(`${label} must be a directory`);
  }
  if (
    typeof process.getuid === "function" &&
    stat.uid !== process.getuid()
  ) {
    fail(`${label} must be owned by the current user`);
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

function assertContextPath(contextPath, context) {
  const canonicalContext = canonicalExisting(contextPath, "context path");
  assertPrivateEntry(canonicalContext, "file", 0o400, "context path");
  const artifactDir = canonicalExisting(
    requiredString(context, "reviewArtifactDir"),
    "review artifact directory",
  );
  assertPrivateEntry(
    artifactDir,
    "directory",
    0o700,
    "review artifact directory",
  );
  if (canonicalContext !== path.join(artifactDir, "context.json")) {
    fail("context path must be reviewArtifactDir/context.json");
  }
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
  assertPrivateEntry(runRoot, "directory", 0o700, "review run root");
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
  assertPrivateEntry(
    skillDir,
    "directory",
    0o700,
    "run-specific skill directory",
  );
  if (skillDir !== path.join(runRoot, "tooling")) {
    fail("run-specific skill directory must be reviewRunRoot/tooling");
  }
  return { runRoot, skillDir };
}

function assertInvocation(context, options, runRoot) {
  const pathOptions = [
    ["--project", "projectRoot"],
    ["--temp-root", "reviewTempRoot"],
    ["--diff", "diffFile"],
    ["--snapshot", "reviewSnapshotDir"],
  ];
  for (const [option, key] of pathOptions) {
    sameCanonicalPath(options.get(option), requiredString(context, key), option);
  }

  const promptPath = canonicalExisting(
    options.get("--prompt-template"),
    "--prompt-template",
  );
  assertPrivateEntry(promptPath, "file", 0o400, "prompt template");
  if (
    promptPath === runRoot ||
    !promptPath.startsWith(`${runRoot}${path.sep}`)
  ) {
    fail("prompt template must be inside the review run root");
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
  if (!["review", "followup"].includes(options.get("--result-contract"))) {
    fail("--result-contract must be review or followup");
  }
}

try {
  const { contextPath, options } = parseArgs(process.argv.slice(2));
  const context = JSON.parse(readFileSync(contextPath, "utf8"));
  if (!context || typeof context !== "object" || Array.isArray(context)) {
    fail("context must be a JSON object");
  }
  assertContextPath(contextPath, context);
  const { runRoot, skillDir } = assertRunNamespace(context);

  const scriptDir = realpathSync(
    path.dirname(fileURLToPath(import.meta.url)),
  );
  const trustedSkillDir = realpathSync(path.resolve(scriptDir, ".."));
  const launcherPath = realpathSync(path.join(scriptDir, "launch-run-codex.sh"));
  if (
    canonicalExisting(
      requiredString(context, "codexLauncherPath"),
      "context Codex launcher",
    ) !== launcherPath
  ) {
    fail("context Codex launcher does not match this installed skill");
  }
  assertInvocation(context, options, runRoot);
  const reviewerConfig = requiredReviewerConfig(context);
  const reviewerConfigSources = requiredReviewerConfigSources(context);

  const runnerPath = canonicalExisting(
    path.join(skillDir, "scripts", "run-codex.sh"),
    "run-specific Codex runner",
  );
  assertPrivateEntry(
    runnerPath,
    "file",
    0o500,
    "run-specific Codex runner",
  );
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
      reviewerConfig,
      reviewerConfigSources,
    })}\n`,
  );
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exitCode = 1;
}
