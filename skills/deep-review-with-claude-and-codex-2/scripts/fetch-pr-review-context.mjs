#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { lstatSync } from "node:fs";

import {
  readPrReviewContextArtifacts,
  writePrReviewContextArtifacts,
} from "./review-pr-context.mjs";

const PAGE_SIZE = 100;
const SOURCE_RECORD_LIMIT = 10_000;
const COMBINED_RAW_LIMIT = 64 * 1024 * 1024;
const IDENTITY_RESPONSE_LIMIT = 1024 * 1024;
const GH_REQUEST_TIMEOUT_MS = 30_000;
const FETCH_TIMEOUT_MS = 120_000;
const MAX_API_REQUESTS = 2 + 4 * Math.ceil(SOURCE_RECORD_LIMIT / PAGE_SIZE);

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!value) fail(`${flag ?? "<missing>"} requires a value`);
    if (flag === "--repo-host") parsed.repoHost = value;
    else if (flag === "--repo") parsed.repo = value;
    else if (flag === "--pr") parsed.pr = value;
    else if (flag === "--expected-head-sha") parsed.expectedHeadSha = value;
    else if (flag === "--review-run-id") parsed.reviewRunId = value;
    else if (flag === "--snapshot-role") parsed.snapshotRole = value;
    else if (flag === "--supersedes") parsed.supersedes = value;
    else if (flag === "--output") parsed.output = value;
    else fail(`unknown argument: ${flag}`);
  }
  if (
    !parsed.repoHost ||
    !parsed.repo ||
    !parsed.pr ||
    !parsed.expectedHeadSha ||
    !parsed.reviewRunId ||
    !parsed.snapshotRole ||
    !parsed.output
  ) {
    fail(
      "--repo-host, --repo, --pr, --expected-head-sha, --review-run-id, --snapshot-role and --output are required",
    );
  }
  if (!new Set(["initial", "final"]).has(parsed.snapshotRole)) {
    fail("--snapshot-role must be initial or final");
  }
  if (parsed.snapshotRole === "initial" && parsed.supersedes) {
    fail("initial PR context must not supersede another snapshot");
  }
  if (parsed.snapshotRole === "final" && !parsed.supersedes) {
    fail("final PR context requires --supersedes");
  }
  if (!/^[^/\s]+$/u.test(parsed.repoHost))
    fail("--repo-host must be a hostname");
  if (!/^[^/\s]+\/[^/\s]+$/u.test(parsed.repo))
    fail("--repo must be owner/name");
  if (!/^[1-9][0-9]*$/u.test(parsed.pr))
    fail("--pr must be a positive integer");
  if (!/^[0-9a-f]{40}$/u.test(parsed.expectedHeadSha)) {
    fail("--expected-head-sha must be a 40-character lowercase Git SHA");
  }
  if (!/^[0-9a-f-]{36}$/u.test(parsed.reviewRunId)) {
    fail("--review-run-id must be a UUID");
  }
  try {
    lstatSync(parsed.output);
    fail("--output must not already exist");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  return parsed;
}

function readSupersededSnapshot(args) {
  if (args.snapshotRole !== "final") return null;
  let initialArtifacts;
  try {
    initialArtifacts = readPrReviewContextArtifacts(args.supersedes);
  } catch {
    fail("superseded PR context is unavailable");
  }
  const initial = initialArtifacts.reviewContext;
  if (
    initial?.schema !== "deep-review-pr-review-context/v1" ||
    initial.snapshotRole !== "initial" ||
    initial.supersedesSha256 !== null ||
    initial.reviewRunId !== args.reviewRunId ||
    initial.repositoryHost !== args.repoHost ||
    initial.repository !== args.repo ||
    String(initial.prNumber) !== args.pr ||
    initial.expectedHeadSha !== args.expectedHeadSha
  ) {
    fail("superseded PR context identity is invalid");
  }
  return initialArtifacts.receipt.sha256;
}

function runGh(args, maxBuffer, fetchState) {
  const remainingMs = fetchState.deadlineAtMs - Date.now();
  if (fetchState.apiRequests >= MAX_API_REQUESTS) {
    return {
      ok: false,
      stdout: "",
      stderr: "",
      status: null,
      bufferExceeded: false,
      timedOut: false,
      blockedReason: `API request cap ${MAX_API_REQUESTS} reached`,
    };
  }
  if (remainingMs <= 0) {
    return {
      ok: false,
      stdout: "",
      stderr: "",
      status: null,
      bufferExceeded: false,
      timedOut: true,
      blockedReason: `overall fetch timeout ${FETCH_TIMEOUT_MS}ms reached`,
    };
  }
  const timeoutMs = Math.max(1, Math.min(GH_REQUEST_TIMEOUT_MS, remainingMs));
  fetchState.apiRequests += 1;
  const result = spawnSync("gh", args, {
    encoding: "utf8",
    env: process.env,
    maxBuffer,
    stdio: ["ignore", "pipe", "pipe"],
    timeout: timeoutMs,
    killSignal: "SIGKILL",
  });
  const timedOut = result.error?.code === "ETIMEDOUT";
  return {
    ok: result.status === 0,
    stdout: result.stdout ?? "",
    stderr: result.stderr?.trim() ?? "",
    status: result.status,
    bufferExceeded: result.error?.code === "ENOBUFS",
    timedOut,
    blockedReason: timedOut ? `timed out after ${timeoutMs}ms` : null,
  };
}

function describeGhFailure(result) {
  if (result.blockedReason) return result.blockedReason;
  return (
    `failed (exit ${result.status ?? "unknown"}): ` +
    `${result.stderr || "no stderr"}`
  );
}

function remainingRawBudget(rawState) {
  return Math.max(0, COMBINED_RAW_LIMIT - rawState.bytes);
}

function recordCombinedCap(source, reasons, unfetched, rawState) {
  if (!rawState.capReached) {
    reasons.push(
      `combined raw response cap ${COMBINED_RAW_LIMIT} bytes exceeded`,
    );
  }
  rawState.capReached = true;
  rawState.bytes = COMBINED_RAW_LIMIT;
  unfetched.push({
    source,
    range: "not fetched: combined raw response cap reached",
  });
}

function runBoundedGh(args, source, reasons, unfetched, rawState, fetchState) {
  const remaining = remainingRawBudget(rawState);
  if (remaining === 0) {
    recordCombinedCap(source, reasons, unfetched, rawState);
    return null;
  }
  const result = runGh(args, remaining, fetchState);
  const responseBytes = Buffer.byteLength(result.stdout, "utf8");
  if (result.bufferExceeded || responseBytes > remaining) {
    recordCombinedCap(source, reasons, unfetched, rawState);
    return null;
  }
  rawState.bytes += responseBytes;
  return result;
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch {
    fail(`${label} returned invalid JSON`);
  }
}

function fetchPrIdentity(repoHost, repo, pr, label, reasons, fetchState) {
  const result = runGh(
    [
      "pr",
      "view",
      pr,
      "--repo",
      `${repoHost}/${repo}`,
      "--json",
      "number,headRefOid",
    ],
    IDENTITY_RESPONSE_LIMIT,
    fetchState,
  );
  if (!result.ok) {
    reasons.push(`${label}: gh pr view ${describeGhFailure(result)}`);
    return null;
  }
  let identity;
  try {
    identity = parseJson(result.stdout, label);
  } catch (error) {
    reasons.push(`${label}: ${error.message}`);
    return null;
  }
  if (
    identity?.number !== Number(pr) ||
    typeof identity?.headRefOid !== "string" ||
    !/^[0-9a-f]{40}$/u.test(identity.headRefOid)
  ) {
    reasons.push(`${label}: PR identity is invalid or does not match PR ${pr}`);
    return null;
  }
  return { prNumber: identity.number, headSha: identity.headRefOid };
}

function emptyCollection() {
  return { pages: 0, raw: 0, nonBot: 0, deduped: 0, records: [] };
}

function recordAllSourcesUnfetched(unfetched, reason) {
  for (const source of [
    "issueComments",
    "reviews",
    "inlineComments",
    "reviewThreads",
  ]) {
    unfetched.push({ source, range: reason });
  }
}

function normalizeRestPage(value, label) {
  if (!Array.isArray(value)) fail(`${label} response must be an array`);
  if (!value.every((item) => item && typeof item === "object")) {
    fail(`${label} response has an invalid page shape`);
  }
  return value;
}

function stableId(source, record) {
  const candidate = record.id ?? record.node_id;
  if (
    (typeof candidate !== "number" && typeof candidate !== "string") ||
    String(candidate).length === 0
  ) {
    fail(`${source} record is missing a stable API id`);
  }
  return `${source}:${candidate}`;
}

function isBot(author) {
  const login = author?.login;
  return (
    author?.type === "Bot" ||
    (typeof login === "string" && /\[bot\]$/iu.test(login))
  );
}

function boundedBody(value) {
  return typeof value === "string" ? value : "";
}

function summarizeRestRecord(source, record) {
  const common = {
    stableId: stableId(source, record),
    apiId: record.id ?? record.node_id,
    url: record.html_url ?? null,
    body: boundedBody(record.body),
    author: record.user?.login ?? null,
    createdAt: record.created_at ?? null,
    updatedAt: record.updated_at ?? null,
  };
  if (source === "reviews") {
    return {
      ...common,
      state: record.state ?? null,
      submittedAt: record.submitted_at ?? null,
      commitId: record.commit_id ?? null,
    };
  }
  if (source === "inlineComments") {
    return {
      ...common,
      path: record.path ?? null,
      line: record.line ?? record.original_line ?? null,
      commitId: record.commit_id ?? null,
      originalCommitId: record.original_commit_id ?? null,
      inReplyToId: record.in_reply_to_id ?? null,
    };
  }
  return common;
}

function collectRest(
  repoHost,
  repo,
  source,
  endpoint,
  reasons,
  unfetched,
  rawState,
  fetchState,
) {
  const seen = new Map();
  let pages = 0;
  let raw = 0;
  let nonBot = 0;
  let page = 1;
  while (raw < SOURCE_RECORD_LIMIT) {
    const result = runBoundedGh(
      [
        "api",
        "--hostname",
        repoHost,
        "-H",
        "Accept: application/vnd.github+json",
        `repos/${repo}/${endpoint}?per_page=${PAGE_SIZE}&page=${page}`,
      ],
      source,
      reasons,
      unfetched,
      rawState,
      fetchState,
    );
    if (result === null) break;
    if (!result.ok) {
      reasons.push(`${source}: gh api ${describeGhFailure(result)}`);
      unfetched.push({ source, range: `page ${page}+` });
      break;
    }
    let records;
    try {
      records = normalizeRestPage(parseJson(result.stdout, source), source);
    } catch (error) {
      reasons.push(`${source}: ${error.message}`);
      unfetched.push({ source, range: `page ${page}+` });
      break;
    }
    pages += 1;
    if (records.length > PAGE_SIZE) {
      reasons.push(`${source}: page ${page} exceeds page size ${PAGE_SIZE}`);
      unfetched.push({ source, range: `after page ${page}` });
    }
    const available = SOURCE_RECORD_LIMIT - raw;
    const retained = records.slice(0, available);
    raw += retained.length;
    for (const record of retained) {
      if (isBot(record.user)) continue;
      nonBot += 1;
      let summarized;
      try {
        summarized = summarizeRestRecord(source, record);
      } catch (error) {
        reasons.push(`${source}: ${error.message}`);
        continue;
      }
      const previous = seen.get(summarized.stableId);
      if (previous && JSON.stringify(previous) !== JSON.stringify(summarized)) {
        reasons.push(
          `${source}: duplicate stable API id has inconsistent data: ${summarized.stableId}`,
        );
        continue;
      }
      seen.set(summarized.stableId, summarized);
    }
    if (records.length > retained.length) {
      reasons.push(`${source}: source cap ${SOURCE_RECORD_LIMIT} reached`);
      unfetched.push({ source, range: `${SOURCE_RECORD_LIMIT + 1}+` });
      break;
    }
    if (records.length < PAGE_SIZE) break;
    if (raw === SOURCE_RECORD_LIMIT) {
      reasons.push(`${source}: source cap ${SOURCE_RECORD_LIMIT} reached`);
      unfetched.push({ source, range: `${SOURCE_RECORD_LIMIT + 1}+` });
      break;
    }
    page += 1;
  }
  return {
    pages,
    raw,
    nonBot,
    deduped: seen.size,
    records: [...seen.values()],
  };
}

const THREAD_QUERY = `
query($owner:String!,$name:String!,$number:Int!,$endCursor:String) {
  repository(owner:$owner,name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:100,after:$endCursor) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first:100) {
            totalCount
            nodes {
              id
              databaseId
              url
              body
              createdAt
              author { login __typename }
              commit { oid }
            }
          }
        }
      }
    }
  }
}`;

function collectThreads(
  repoHost,
  owner,
  name,
  pr,
  reasons,
  unfetched,
  rawState,
  fetchState,
) {
  const seenCursors = new Set();
  const nodes = [];
  let expectedTotal = null;
  let pages = 0;
  let endCursor = "";
  while (nodes.length < SOURCE_RECORD_LIMIT) {
    const page = pages + 1;
    const result = runBoundedGh(
      [
        "api",
        "--hostname",
        repoHost,
        "graphql",
        "-f",
        `query=${THREAD_QUERY}`,
        "-f",
        `owner=${owner}`,
        "-f",
        `name=${name}`,
        "-F",
        `number=${pr}`,
        "-f",
        `endCursor=${endCursor}`,
      ],
      "reviewThreads",
      reasons,
      unfetched,
      rawState,
      fetchState,
    );
    if (result === null) break;
    if (!result.ok) {
      reasons.push(`reviewThreads: gh api ${describeGhFailure(result)}`);
      unfetched.push({ source: "reviewThreads", range: `page ${page}+` });
      break;
    }
    let parsed;
    try {
      parsed = parseJson(result.stdout, "reviewThreads");
    } catch (error) {
      reasons.push(`reviewThreads: ${error.message}`);
      unfetched.push({ source: "reviewThreads", range: `page ${page}+` });
      break;
    }
    if (Array.isArray(parsed?.errors) && parsed.errors.length > 0) {
      reasons.push(`reviewThreads: page ${page} returned GraphQL errors`);
      unfetched.push({ source: "reviewThreads", range: `page ${page}+` });
      break;
    }
    const connection = parsed?.data?.repository?.pullRequest?.reviewThreads;
    if (!connection || !Array.isArray(connection.nodes)) {
      reasons.push(`reviewThreads: page ${page} is missing the connection`);
      unfetched.push({ source: "reviewThreads", range: `page ${page}+` });
      break;
    }
    pages += 1;
    if (Number.isInteger(connection.totalCount)) {
      if (expectedTotal === null) expectedTotal = connection.totalCount;
      else if (expectedTotal !== connection.totalCount) {
        reasons.push("reviewThreads: totalCount changed during pagination");
      }
    }
    if (connection.nodes.length > PAGE_SIZE) {
      reasons.push(
        `reviewThreads: page ${page} exceeds page size ${PAGE_SIZE}`,
      );
      unfetched.push({ source: "reviewThreads", range: `after page ${page}` });
    }
    const available = SOURCE_RECORD_LIMIT - nodes.length;
    nodes.push(...connection.nodes.slice(0, available));
    if (connection.nodes.length > available) {
      reasons.push(`reviewThreads: source cap ${SOURCE_RECORD_LIMIT} reached`);
      unfetched.push({
        source: "reviewThreads",
        range: `${SOURCE_RECORD_LIMIT + 1}+`,
      });
      break;
    }
    const { hasNextPage, endCursor: nextCursor } = connection.pageInfo ?? {};
    if (hasNextPage === true) {
      if (
        typeof nextCursor !== "string" ||
        nextCursor.length === 0 ||
        seenCursors.has(nextCursor)
      ) {
        reasons.push(
          `reviewThreads: invalid or repeated cursor at page ${page}`,
        );
        unfetched.push({
          source: "reviewThreads",
          range: `after page ${page}`,
        });
        break;
      }
      if (nodes.length === SOURCE_RECORD_LIMIT) {
        reasons.push(
          `reviewThreads: source cap ${SOURCE_RECORD_LIMIT} reached`,
        );
        unfetched.push({
          source: "reviewThreads",
          range: `${SOURCE_RECORD_LIMIT + 1}+`,
        });
        break;
      }
      seenCursors.add(nextCursor);
      endCursor = nextCursor;
    } else if (hasNextPage !== false) {
      reasons.push(`reviewThreads: page ${page} has invalid pageInfo`);
      unfetched.push({ source: "reviewThreads", range: `after page ${page}` });
      break;
    } else {
      break;
    }
  }
  if (expectedTotal !== null && expectedTotal !== nodes.length) {
    reasons.push(
      `reviewThreads: totalCount mismatch (expected ${expectedTotal}, received ${nodes.length})`,
    );
    if (expectedTotal > nodes.length) {
      unfetched.push({
        source: "reviewThreads",
        range: `${nodes.length + 1}-${expectedTotal}`,
      });
    }
  }
  const seen = new Map();
  let nonBot = 0;
  for (const thread of nodes) {
    if (typeof thread?.id !== "string" || thread.id.length === 0) {
      reasons.push("reviewThreads: thread is missing a stable API id");
      continue;
    }
    const comments = thread.comments;
    if (!comments || !Array.isArray(comments.nodes)) {
      reasons.push(`reviewThreads: comments are unavailable for ${thread.id}`);
      continue;
    }
    if (comments.totalCount > comments.nodes.length) {
      reasons.push(
        `reviewThreads: thread ${thread.id} has more than ${PAGE_SIZE} comments`,
      );
      unfetched.push({
        source: "reviewThreads.comments",
        range: `${thread.id} comments ${comments.nodes.length + 1}-${comments.totalCount}`,
      });
    }
    const nonBotComments = comments.nodes.filter(
      (comment) =>
        comment.author?.__typename !== "Bot" &&
        !/\[bot\]$/iu.test(comment.author?.login ?? ""),
    );
    if (nonBotComments.length === 0) continue;
    nonBot += 1;
    const summarized = {
      stableId: `reviewThreads:${thread.id}`,
      apiId: thread.id,
      isResolved: thread.isResolved === true,
      isOutdated: thread.isOutdated === true,
      path: thread.path ?? null,
      line: thread.line ?? null,
      comments: nonBotComments.map((comment) => ({
        stableId: `reviewThreadComment:${comment.id ?? comment.databaseId}`,
        apiId: comment.id ?? comment.databaseId,
        databaseId: comment.databaseId ?? null,
        url: comment.url ?? null,
        body: boundedBody(comment.body),
        author: comment.author?.login ?? null,
        createdAt: comment.createdAt ?? null,
        commitId: comment.commit?.oid ?? null,
      })),
    };
    const previous = seen.get(summarized.stableId);
    if (previous && JSON.stringify(previous) !== JSON.stringify(summarized)) {
      reasons.push(
        `reviewThreads: duplicate stable API id has inconsistent data: ${summarized.stableId}`,
      );
      continue;
    }
    seen.set(summarized.stableId, summarized);
  }
  return {
    pages,
    raw: nodes.length,
    nonBot,
    deduped: seen.size,
    records: [...seen.values()],
  };
}

try {
  const args = parseArgs(process.argv.slice(2));
  const supersedesSha256 = readSupersededSnapshot(args);
  const [owner, name] = args.repo.split("/");
  const reasons = [];
  const unfetched = [];
  const rawState = { bytes: 0, capReached: false };
  const fetchState = {
    apiRequests: 0,
    deadlineAtMs: Date.now() + FETCH_TIMEOUT_MS,
  };
  const before = fetchPrIdentity(
    args.repoHost,
    args.repo,
    args.pr,
    "before-fetch identity",
    reasons,
    fetchState,
  );
  const mayFetch = before?.headSha === args.expectedHeadSha;
  if (before && !mayFetch) {
    reasons.push(
      `before-fetch HEAD ${before.headSha} does not match expected HEAD ` +
        args.expectedHeadSha,
    );
  }
  if (!mayFetch) {
    recordAllSourcesUnfetched(
      unfetched,
      "not fetched: PR identity did not match the fixed review target",
    );
  }
  const issueComments = mayFetch
    ? collectRest(
        args.repoHost,
        args.repo,
        "issueComments",
        `issues/${args.pr}/comments`,
        reasons,
        unfetched,
        rawState,
        fetchState,
      )
    : emptyCollection();
  const reviews = mayFetch
    ? collectRest(
        args.repoHost,
        args.repo,
        "reviews",
        `pulls/${args.pr}/reviews`,
        reasons,
        unfetched,
        rawState,
        fetchState,
      )
    : emptyCollection();
  const inlineComments = mayFetch
    ? collectRest(
        args.repoHost,
        args.repo,
        "inlineComments",
        `pulls/${args.pr}/comments`,
        reasons,
        unfetched,
        rawState,
        fetchState,
      )
    : emptyCollection();
  const reviewThreads = mayFetch
    ? collectThreads(
        args.repoHost,
        owner,
        name,
        Number(args.pr),
        reasons,
        unfetched,
        rawState,
        fetchState,
      )
    : emptyCollection();
  const after = fetchPrIdentity(
    args.repoHost,
    args.repo,
    args.pr,
    "after-fetch identity",
    reasons,
    fetchState,
  );
  if (after && after.headSha !== args.expectedHeadSha) {
    reasons.push(
      `after-fetch HEAD ${after.headSha} does not match expected HEAD ` +
        args.expectedHeadSha,
    );
  }
  if (before && after && before.headSha !== after.headSha) {
    reasons.push(
      `PR HEAD changed during comment retrieval: ${before.headSha} -> ${after.headSha}`,
    );
  }
  const result = {
    schema: "deep-review-pr-review-context/v1",
    snapshotRole: args.snapshotRole,
    supersedesSha256,
    reviewRunId: args.reviewRunId,
    repositoryHost: args.repoHost,
    repository: args.repo,
    prNumber: Number(args.pr),
    expectedHeadSha: args.expectedHeadSha,
    headShaBefore: before?.headSha ?? null,
    headShaAfter: after?.headSha ?? null,
    status: reasons.length === 0 ? "checked" : "not-checked",
    reasons,
    unfetched,
    limits: {
      pageSize: PAGE_SIZE,
      sourceRecords: SOURCE_RECORD_LIMIT,
      combinedRawBytes: COMBINED_RAW_LIMIT,
      ghRequestTimeoutMs: GH_REQUEST_TIMEOUT_MS,
      fetchTimeoutMs: FETCH_TIMEOUT_MS,
      apiRequests: MAX_API_REQUESTS,
    },
    apiRequests: fetchState.apiRequests,
    rawBytes: rawState.bytes,
    counts: {
      issueComments: {
        pages: issueComments.pages,
        raw: issueComments.raw,
        nonBot: issueComments.nonBot,
        deduped: issueComments.deduped,
      },
      reviews: {
        pages: reviews.pages,
        raw: reviews.raw,
        nonBot: reviews.nonBot,
        deduped: reviews.deduped,
      },
      inlineComments: {
        pages: inlineComments.pages,
        raw: inlineComments.raw,
        nonBot: inlineComments.nonBot,
        deduped: inlineComments.deduped,
      },
      reviewThreads: {
        pages: reviewThreads.pages,
        raw: reviewThreads.raw,
        nonBot: reviewThreads.nonBot,
        deduped: reviewThreads.deduped,
      },
    },
    records: {
      issueComments: issueComments.records,
      reviews: reviews.records,
      inlineComments: inlineComments.records,
      reviewThreads: reviewThreads.records,
    },
  };
  const { receiptPath, receipt } = writePrReviewContextArtifacts({
    contextPath: args.output,
    reviewContext: result,
  });
  process.stdout.write(
    `${JSON.stringify({
      path: args.output,
      receiptPath,
      receiptSha256: receipt.sha256,
      status: result.status,
      snapshotRole: result.snapshotRole,
      supersedesSha256: result.supersedesSha256,
      repositoryHost: result.repositoryHost,
      repository: result.repository,
      prNumber: result.prNumber,
      expectedHeadSha: result.expectedHeadSha,
      headShaBefore: result.headShaBefore,
      headShaAfter: result.headShaAfter,
      counts: result.counts,
      reasons: result.reasons,
      unfetched: result.unfetched,
    })}\n`,
  );
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exitCode = 1;
}
