#!/usr/bin/env node

import { randomBytes } from "node:crypto";
import {
  chmodSync,
  constants,
  copyFileSync,
  linkSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { toBashAbsolutePath } from "./path-interop.mjs";
import { validateReviewReport } from "./validate-review-report.mjs";

export { toBashAbsolutePath } from "./path-interop.mjs";

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const allowed = new Map([
    ["--tooling-root", "toolingRoot"],
    ["--target", "target"],
    ["--run-id", "runId"],
    ["--mode", "mode"],
    ["--report-path", "reportPath"],
  ]);
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    const key = allowed.get(flag);
    if (!key || value === undefined) fail(`invalid argument: ${flag}`);
    if (parsed[key] !== undefined) fail(`duplicate argument: ${flag}`);
    parsed[key] = value;
  }
  for (const key of allowed.values()) {
    if (!parsed[key]) fail(`missing required argument: ${key}`);
  }
  if (
    !/^[A-Za-z0-9._-]{1,180}$/.test(parsed.target) ||
    parsed.target === "." ||
    parsed.target === ".."
  ) {
    fail("target contains unsupported characters");
  }
  if (!/^[0-9a-f-]{36}$/.test(parsed.runId)) {
    fail("run-id must be a UUID");
  }
  if (parsed.mode !== "full") {
    fail("mode must be full");
  }
  return parsed;
}

function assertDirectoryChain(root, segments, create) {
  let current = root;
  for (const segment of segments) {
    current = path.join(current, segment);
    try {
      const stat = lstatSync(current);
      if (stat.isSymbolicLink() || !stat.isDirectory()) {
        fail(`unsafe report directory: ${current}`);
      }
    } catch (error) {
      if (error?.code !== "ENOENT" || !create) throw error;
      mkdirSync(current, { mode: 0o700 });
    }
  }
  return current;
}

function assertReport(filePath, target, context, artifactDirectory) {
  const stat = lstatSync(filePath);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size === 0) {
    fail("run-specific report must be a non-empty regular non-symlink file");
  }
  validateReviewReport(filePath, { target, context, artifactDirectory });
}

function loadRunContext(runDirectory, args, callerReportPath) {
  const contextPath = path.join(runDirectory, "context.json");
  const stat = lstatSync(contextPath);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size === 0) {
    fail("run context must be a non-empty regular non-symlink file");
  }
  let context;
  try {
    context = JSON.parse(readFileSync(contextPath, "utf8"));
  } catch {
    fail("run context must be valid JSON");
  }
  for (const key of [
    "reviewRunId",
    "reviewArtifactDir",
    "reviewMode",
    "target",
    "targetSlug",
    "baseSha",
    "headSha",
    "mergeBaseSha",
    "toolingDigest",
    "diffSha256",
    "snapshotMetadataSha256",
    "baseGuidanceSha256",
  ]) {
    if (typeof context[key] !== "string" || context[key].length === 0) {
      fail(`run context is missing ${key}`);
    }
  }
  if (context.reviewRunId !== args.runId) {
    fail("run context reviewRunId does not match --run-id");
  }
  if (context.targetSlug !== args.target) {
    fail("run context targetSlug does not match --target");
  }
  if (!new Set(["pr", "branch"]).has(context.reviewMode)) {
    fail("run context reviewMode must be pr or branch");
  }
  if (context.reviewMode === "pr") {
    if (
      context.target !== `pr:${context.prNumber}` ||
      context.prNumber !== args.target ||
      typeof context.repositoryHost !== "string" ||
      !/^[^/\s]+$/u.test(context.repositoryHost) ||
      typeof context.repository !== "string" ||
      !/^[^/\s]+\/[^/\s]+$/u.test(context.repository) ||
      typeof context.prReviewContextPath !== "string" ||
      context.prReviewContextPath.length === 0
    ) {
      fail("PR run context target identity is inconsistent");
    }
  } else if (
    typeof context.headRef !== "string" ||
    context.headRef.length === 0 ||
    context.target !== `branch:${context.headRef}` ||
    context.repositoryHost !== null ||
    context.repository !== null ||
    context.prReviewContextPath !== null
  ) {
    fail("branch run context target identity is inconsistent");
  }
  if (
    context.reviewArtifactDir.replaceAll("\\", "/") !==
    toBashAbsolutePath(path.dirname(callerReportPath))
  ) {
    fail("run context reviewArtifactDir does not match --report-path");
  }
  if (
    !Number.isSafeInteger(context.reviewStartedAtMs) ||
    context.reviewStartedAtMs <= 0
  ) {
    fail("run context reviewStartedAtMs must be a positive safe integer");
  }
  return context;
}

function publishCompatibilityCopy(reportPath, reviewsRoot, fileName) {
  const compatibilityPath = path.join(reviewsRoot, fileName);
  const temporaryPath = path.join(
    reviewsRoot,
    `.report-copy.${process.pid}.${randomBytes(8).toString("hex")}`,
  );
  try {
    copyFileSync(reportPath, temporaryPath, constants.COPYFILE_EXCL);
    chmodSync(temporaryPath, 0o600);
    renameSync(temporaryPath, compatibilityPath);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function assertTiming(timingPath, context) {
  const stat = lstatSync(timingPath);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size === 0) {
    fail("run timing must be a non-empty regular non-symlink file");
  }
  let timing;
  try {
    timing = JSON.parse(readFileSync(timingPath, "utf8"));
  } catch {
    fail("run timing must be valid JSON");
  }
  if (
    timing.schema !== "deep-review-duration/v1" ||
    timing.reviewRunId !== context.reviewRunId ||
    timing.reviewStartedAtMs !== context.reviewStartedAtMs ||
    !Number.isSafeInteger(timing.reportPublishedAtMs) ||
    !Number.isSafeInteger(timing.durationMs) ||
    timing.reportPublishedAtMs < timing.reviewStartedAtMs ||
    timing.durationMs !== timing.reportPublishedAtMs - timing.reviewStartedAtMs
  ) {
    fail("run timing does not match the review context");
  }
}

function publishTiming(runDirectory, context) {
  const reportPublishedAtMs = Date.now();
  if (reportPublishedAtMs < context.reviewStartedAtMs) {
    fail("review start time is later than the report publication time");
  }
  const timingPath = path.join(runDirectory, "timing.json");
  const temporaryPath = path.join(
    runDirectory,
    `.timing.${process.pid}.${randomBytes(8).toString("hex")}`,
  );
  const timing = {
    schema: "deep-review-duration/v1",
    reviewRunId: context.reviewRunId,
    reviewStartedAtMs: context.reviewStartedAtMs,
    reportPublishedAtMs,
    durationMs: reportPublishedAtMs - context.reviewStartedAtMs,
  };
  try {
    writeFileSync(temporaryPath, `${JSON.stringify(timing)}\n`, {
      flag: "wx",
      mode: 0o600,
    });
    chmodSync(temporaryPath, 0o600);
    try {
      linkSync(temporaryPath, timingPath);
      assertTiming(timingPath, context);
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      assertTiming(timingPath, context);
    }
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function assertNoSymlinkComponents(filePath) {
  const { root } = path.parse(filePath);
  let current = root;
  const relativePath = path.relative(root, filePath);
  for (const segment of relativePath.split(path.sep)) {
    if (!segment) continue;
    current = path.join(current, segment);
    if (lstatSync(current).isSymbolicLink()) {
      fail(`report-path contains a symlink: ${current}`);
    }
  }
}

function assertSamePhysicalPath(actualPath, expectedPath) {
  const actualRealPath = realpathSync.native(actualPath);
  const expectedRealPath = realpathSync.native(expectedPath);
  if (actualRealPath !== expectedRealPath) {
    fail("report-path does not identify the expected run-specific report");
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const toolingRoot = realpathSync(args.toolingRoot);
  const reviewsRoot = assertDirectoryChain(
    toolingRoot,
    ["_tmp", "reviews"],
    true,
  );
  const runDirectory = assertDirectoryChain(
    reviewsRoot,
    ["runs", args.target, args.runId],
    false,
  );
  if (!path.isAbsolute(args.reportPath)) {
    fail("report-path must be absolute");
  }
  const callerReportPath = path.resolve(args.reportPath);
  assertNoSymlinkComponents(callerReportPath);
  const context = loadRunContext(runDirectory, args, callerReportPath);
  const reportPath = path.join(runDirectory, "report.md");
  // Validate recorded artifact paths using the caller's already-verified long
  // path. runDirectory may express the same physical directory as an 8.3 path.
  assertReport(reportPath, args.target, context, path.dirname(callerReportPath));
  assertSamePhysicalPath(callerReportPath, reportPath);

  publishCompatibilityCopy(
    reportPath,
    reviewsRoot,
    `deep-review-2-${args.target}.md`,
  );
  if (/^[0-9]+$/u.test(args.target)) {
    publishCompatibilityCopy(
      reportPath,
      reviewsRoot,
      `pr-${args.target}-v2.md`,
    );
  }
  publishTiming(runDirectory, context);

  // Keep the spelling selected by the Bash initializer. The independently
  // canonicalized reportPath above is used only to prove that both spellings
  // identify the same run-specific report. This avoids false mismatches when
  // Windows realpath returns an 8.3 short name.
  process.stdout.write(
    `REPORT_PATH: ${toBashAbsolutePath(callerReportPath)}\n`,
  );
}

const invokedPath = process.argv[1];
if (
  invokedPath &&
  import.meta.url === pathToFileURL(path.resolve(invokedPath)).href
) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
