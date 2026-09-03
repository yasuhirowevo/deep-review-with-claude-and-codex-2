#!/usr/bin/env node

import { lstatSync, readFileSync } from "node:fs";
import path from "node:path";

function fail(message) {
  throw new Error(message);
}

function formatDuration(durationMs) {
  const totalSeconds = Math.floor(durationMs / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const parts = [];
  if (hours > 0) parts.push(`${hours}時間`);
  if (minutes > 0) parts.push(`${minutes}分`);
  parts.push(`${seconds}秒`);
  return parts.join("");
}

function main() {
  const [contextPath] = process.argv.slice(2);
  if (!contextPath || process.argv.length !== 3) {
    fail("usage: format-review-duration.mjs <context.json>");
  }
  const stat = lstatSync(contextPath);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size === 0) {
    fail("context must be a non-empty regular non-symlink file");
  }
  const context = JSON.parse(readFileSync(contextPath, "utf8"));
  if (
    !Number.isSafeInteger(context.reviewStartedAtMs) ||
    context.reviewStartedAtMs <= 0
  ) {
    fail("context.reviewStartedAtMs must be a positive safe integer");
  }
  const timingPath = path.join(path.dirname(contextPath), "timing.json");
  const timingStat = lstatSync(timingPath);
  if (
    timingStat.isSymbolicLink() ||
    !timingStat.isFile() ||
    timingStat.size === 0
  ) {
    fail("timing must be a non-empty regular non-symlink file");
  }
  const timing = JSON.parse(readFileSync(timingPath, "utf8"));
  if (
    timing.schema !== "deep-review-duration/v1" ||
    timing.reviewRunId !== context.reviewRunId ||
    timing.reviewStartedAtMs !== context.reviewStartedAtMs ||
    !Number.isSafeInteger(timing.reportPublishedAtMs) ||
    !Number.isSafeInteger(timing.durationMs) ||
    timing.reportPublishedAtMs < timing.reviewStartedAtMs ||
    timing.durationMs !== timing.reportPublishedAtMs - timing.reviewStartedAtMs
  ) {
    fail("timing does not match the review context");
  }
  process.stdout.write(`REVIEW_DURATION: ${formatDuration(timing.durationMs)}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exit(1);
}
