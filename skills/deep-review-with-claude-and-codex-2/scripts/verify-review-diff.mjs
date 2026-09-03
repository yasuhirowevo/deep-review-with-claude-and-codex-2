#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createReadStream, lstatSync } from "node:fs";

const REVIEW_DIFF_MAX_BYTES = 64 * 1024 * 1024;

function fail(message) {
  throw new Error(message);
}

const argv = process.argv.slice(2);
if (
  argv.length < 2 ||
  argv[0] !== "--diff" ||
  !["--print-sha256", "--expected-sha256"].includes(argv[2]) ||
  (argv[2] === "--expected-sha256" && argv.length !== 4) ||
  (argv[2] === "--print-sha256" && argv.length !== 3)
) {
  process.stderr.write(
    "Usage: verify-review-diff.mjs --diff <path> <--print-sha256|--expected-sha256 <sha256>>\n",
  );
  process.exit(2);
} else {
  const diffPath = argv[1];
  const metadata = lstatSync(diffPath);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    fail("review diff must be a regular non-symlink file");
  }
  if (metadata.size === 0 || metadata.size > REVIEW_DIFF_MAX_BYTES) {
    fail(`review diff size is outside 1..${REVIEW_DIFF_MAX_BYTES} bytes`);
  }
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(diffPath)) hash.update(chunk);
  const digest = hash.digest("hex");
  if (argv[2] === "--expected-sha256") {
    if (!/^[0-9a-f]{64}$/u.test(argv[3]) || digest !== argv[3]) {
      fail("review diff digest mismatch");
    }
    process.stdout.write(`DIFF_OK: ${digest}\n`);
  } else {
    process.stdout.write(`${digest}\n`);
  }
}
