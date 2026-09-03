#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  linkSync,
  lstatSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { isDeepStrictEqual } from "node:util";

export const PR_CONTEXT_SOURCES = [
  "issueComments",
  "reviews",
  "inlineComments",
  "reviewThreads",
];

const SHA256_PATTERN = /^[0-9a-f]{64}$/u;
const GIT_SHA_PATTERN = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/u;

function fail(message) {
  throw new Error(message);
}

function meaningful(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

export function jsonSha256(value) {
  return sha256(Buffer.from(JSON.stringify(value), "utf8"));
}

function normalizePortablePath(value) {
  const slashes = value.replaceAll("\\", "/").replace(/\/{2,}/gu, "/");
  const drive = slashes.match(/^([A-Za-z]):\/(.*)$/u);
  return drive ? `/${drive[1].toLowerCase()}/${drive[2]}` : slashes;
}

function assertRegularFile(filePath, label, requireNonEmpty = false) {
  let stat;
  try {
    stat = lstatSync(filePath);
  } catch {
    fail(`${label} is unavailable`);
  }
  if (
    stat.isSymbolicLink() ||
    !stat.isFile() ||
    (requireNonEmpty && stat.size === 0)
  ) {
    fail(`${label} must be a regular non-symlink file`);
  }
  return stat;
}

function assertMissing(filePath, label) {
  try {
    lstatSync(filePath);
    fail(`${label} must not already exist`);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

function removeIfPresent(filePath) {
  try {
    unlinkSync(filePath);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

function writeAtomicExclusive(filePath, content) {
  const tempPath = `${filePath}.tmp-${process.pid}-${randomUUID()}`;
  try {
    writeFileSync(tempPath, content, { flag: "wx", mode: 0o600 });
    linkSync(tempPath, filePath);
  } finally {
    removeIfPresent(tempPath);
  }
}

function bestEffortRemove(filePath) {
  try {
    chmodSync(filePath, 0o600);
  } catch (error) {
    if (error?.code === "ENOENT") return;
  }
  try {
    removeIfPresent(filePath);
  } catch {
    // Preserve the original publication error; a leftover file remains fail-closed.
  }
}

function assertNullableString(value, label) {
  if (value !== null && typeof value !== "string") {
    fail(`${label} must be a string or null`);
  }
}

function assertNullableInteger(value, label) {
  if (value !== null && (!Number.isSafeInteger(value) || value < 0)) {
    fail(`${label} must be a non-negative integer or null`);
  }
}

function assertApiId(value, label) {
  if (
    !(
      meaningful(value) ||
      (Number.isSafeInteger(value) && value >= 0)
    )
  ) {
    fail(`${label} must contain a stable API id`);
  }
}

function expectedStableId(prefix, apiId) {
  return `${prefix}:${apiId}`;
}

function validateCommonRestRecord(record, source, label) {
  if (!object(record)) fail(`${label} must be an object`);
  assertApiId(record.apiId, `${label}.apiId`);
  if (record.stableId !== expectedStableId(source, record.apiId)) {
    fail(`${label}.stableId does not match its API id`);
  }
  if (typeof record.body !== "string") fail(`${label}.body must be a string`);
  for (const field of ["url", "author", "createdAt", "updatedAt"]) {
    assertNullableString(record[field], `${label}.${field}`);
  }
}

function validateRestRecord(record, source, label) {
  validateCommonRestRecord(record, source, label);
  if (source === "reviews") {
    for (const field of ["state", "submittedAt", "commitId"]) {
      assertNullableString(record[field], `${label}.${field}`);
    }
  }
  if (source === "inlineComments") {
    for (const field of ["path", "commitId", "originalCommitId"]) {
      assertNullableString(record[field], `${label}.${field}`);
    }
    assertNullableInteger(record.line, `${label}.line`);
    if (record.inReplyToId !== null) {
      assertApiId(record.inReplyToId, `${label}.inReplyToId`);
    }
  }
}

function validateThreadComment(comment, label) {
  if (!object(comment)) fail(`${label} must be an object`);
  assertApiId(comment.apiId, `${label}.apiId`);
  if (
    comment.stableId !==
    expectedStableId("reviewThreadComment", comment.apiId)
  ) {
    fail(`${label}.stableId does not match its API id`);
  }
  if (comment.databaseId !== null) {
    assertApiId(comment.databaseId, `${label}.databaseId`);
  }
  if (typeof comment.body !== "string") fail(`${label}.body must be a string`);
  for (const field of ["url", "author", "createdAt", "commitId"]) {
    assertNullableString(comment[field], `${label}.${field}`);
  }
}

function addIndexedRecord(index, source, record, parentThread = null) {
  if (index.has(record.stableId)) {
    fail(`PR review context contains a duplicate stable ID: ${record.stableId}`);
  }
  index.set(record.stableId, { source, record, parentThread });
}

export function indexPrContextRecords(reviewContext) {
  if (!object(reviewContext?.records)) {
    fail("PR review context records are invalid");
  }
  const indexed = new Map();
  for (const source of PR_CONTEXT_SOURCES) {
    const records = reviewContext.records[source];
    if (!Array.isArray(records)) {
      fail(`PR review context records are invalid for ${source}`);
    }
    const sourceIndex = new Map();
    records.forEach((record, recordIndex) => {
      const label = `${source}[${recordIndex}]`;
      if (source !== "reviewThreads") {
        validateRestRecord(record, source, label);
        addIndexedRecord(sourceIndex, source, record);
        return;
      }
      if (!object(record)) fail(`${label} must be an object`);
      assertApiId(record.apiId, `${label}.apiId`);
      if (
        record.stableId !== expectedStableId("reviewThreads", record.apiId)
      ) {
        fail(`${label}.stableId does not match its API id`);
      }
      if (
        typeof record.isResolved !== "boolean" ||
        typeof record.isOutdated !== "boolean"
      ) {
        fail(`${label} state must contain booleans`);
      }
      assertNullableString(record.path, `${label}.path`);
      assertNullableInteger(record.line, `${label}.line`);
      if (!Array.isArray(record.comments) || record.comments.length === 0) {
        fail(`${label}.comments must contain at least one comment`);
      }
      addIndexedRecord(sourceIndex, source, record, record);
      record.comments.forEach((comment, commentIndex) => {
        const commentLabel = `${label}.comments[${commentIndex}]`;
        validateThreadComment(comment, commentLabel);
        addIndexedRecord(sourceIndex, source, comment, record);
      });
    });
    indexed.set(source, sourceIndex);
  }
  return indexed;
}

function validateContextIdentity(reviewContext) {
  if (
    reviewContext?.schema !== "deep-review-pr-review-context/v1" ||
    !new Set(["initial", "final"]).has(reviewContext.snapshotRole) ||
    !meaningful(reviewContext.reviewRunId) ||
    !meaningful(reviewContext.repositoryHost) ||
    !/^[^/\s]+\/[^/\s]+$/u.test(reviewContext.repository) ||
    !Number.isSafeInteger(reviewContext.prNumber) ||
    reviewContext.prNumber < 1 ||
    !GIT_SHA_PATTERN.test(reviewContext.expectedHeadSha) ||
    !new Set(["checked", "not-checked"]).has(reviewContext.status)
  ) {
    fail("PR review context identity is invalid");
  }
  if (
    (reviewContext.snapshotRole === "initial" &&
      reviewContext.supersedesSha256 !== null) ||
    (reviewContext.snapshotRole === "final" &&
      !SHA256_PATTERN.test(reviewContext.supersedesSha256))
  ) {
    fail("PR review context generation binding is invalid");
  }
}

function deriveReceipt(contextPath, raw, reviewContext) {
  validateContextIdentity(reviewContext);
  indexPrContextRecords(reviewContext);
  return {
    schema: "deep-review-pr-review-context-receipt/v1",
    path: contextPath,
    sha256: sha256(raw),
    size: raw.length,
    reviewRunId: reviewContext.reviewRunId,
    repositoryHost: reviewContext.repositoryHost,
    repository: reviewContext.repository,
    prNumber: reviewContext.prNumber,
    expectedHeadSha: reviewContext.expectedHeadSha,
    snapshotRole: reviewContext.snapshotRole,
    supersedesSha256: reviewContext.supersedesSha256,
    status: reviewContext.status,
  };
}

export function prContextReceiptPath(contextPath) {
  return `${contextPath}.receipt.json`;
}

export function writePrReviewContextArtifacts({ contextPath, reviewContext }) {
  const receiptPath = prContextReceiptPath(contextPath);
  assertMissing(contextPath, "PR review context");
  assertMissing(receiptPath, "PR review context receipt");
  const raw = Buffer.from(`${JSON.stringify(reviewContext, null, 2)}\n`, "utf8");
  const receipt = deriveReceipt(contextPath, raw, reviewContext);
  const receiptRaw = Buffer.from(`${JSON.stringify(receipt, null, 2)}\n`, "utf8");
  writeAtomicExclusive(contextPath, raw);
  try {
    writeAtomicExclusive(receiptPath, receiptRaw);
    chmodSync(contextPath, 0o400);
    chmodSync(receiptPath, 0o400);
  } catch (error) {
    bestEffortRemove(receiptPath);
    bestEffortRemove(contextPath);
    throw error;
  }
  return { receiptPath, receipt };
}

export function writePrReviewContextReceipt(contextPath) {
  const receiptPath = prContextReceiptPath(contextPath);
  assertMissing(receiptPath, "PR review context receipt");
  const originalMode =
    assertRegularFile(contextPath, "PR review context", true).mode & 0o777;
  const raw = readFileSync(contextPath);
  const reviewContext = JSON.parse(raw.toString("utf8"));
  const receipt = deriveReceipt(contextPath, raw, reviewContext);
  writeAtomicExclusive(
    receiptPath,
    Buffer.from(`${JSON.stringify(receipt, null, 2)}\n`, "utf8"),
  );
  try {
    chmodSync(contextPath, 0o400);
    chmodSync(receiptPath, 0o400);
  } catch (error) {
    bestEffortRemove(receiptPath);
    try {
      chmodSync(contextPath, originalMode);
    } catch {
      // Preserve the receipt-publication error.
    }
    throw error;
  }
  return { receiptPath, receipt };
}

export function readPrReviewContextArtifacts(contextPath) {
  const receiptPath = prContextReceiptPath(contextPath);
  const contextStat = assertRegularFile(
    contextPath,
    "PR review context",
    true,
  );
  assertRegularFile(receiptPath, "PR review context receipt", true);
  const raw = readFileSync(contextPath);
  let reviewContext;
  let receipt;
  try {
    reviewContext = JSON.parse(raw.toString("utf8"));
  } catch {
    fail("PR review context is invalid JSON");
  }
  try {
    receipt = JSON.parse(readFileSync(receiptPath, "utf8"));
  } catch {
    fail("PR review context receipt is invalid JSON");
  }
  const expected = deriveReceipt(contextPath, raw, reviewContext);
  if (
    normalizePortablePath(receipt?.path ?? "") !==
    normalizePortablePath(contextPath)
  ) {
    fail("PR review context receipt path is invalid");
  }
  expected.path = receipt.path;
  if (
    contextStat.size !== raw.length ||
    !isDeepStrictEqual(receipt, expected)
  ) {
    fail("PR review context does not match its fetch receipt");
  }
  return {
    reviewContext,
    receipt,
    receiptPath,
    recordIndex: indexPrContextRecords(reviewContext),
  };
}

export function derivePrEvidence(recordIndex, source, stableId) {
  const indexed = recordIndex?.get(source)?.get(stableId);
  if (!indexed) fail("Phase 5 decision references unavailable PR comment evidence");
  const { record, parentThread } = indexed;
  return {
    source,
    stableId,
    recordSha256: jsonSha256(record),
    url: record.url ?? null,
    commitId: record.commitId ?? null,
    state: record.state ?? null,
    isResolved: parentThread?.isResolved ?? null,
    isOutdated: parentThread?.isOutdated ?? null,
  };
}
