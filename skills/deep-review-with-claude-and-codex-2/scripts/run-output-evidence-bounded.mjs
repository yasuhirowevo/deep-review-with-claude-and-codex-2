#!/usr/bin/env node

import { spawnSync } from "node:child_process";

const MAX_CAPTURE_BYTES = 1024 * 1024;

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  if (argv.length < 4 || argv[0] !== "--timeout-seconds" || argv[2] !== "--") {
    fail("usage: run-output-evidence-bounded.mjs --timeout-seconds <1..30> -- <tool> [args...]");
  }
  const timeoutSeconds = Number(argv[1]);
  if (
    !Number.isInteger(timeoutSeconds) ||
    timeoutSeconds < 1 ||
    timeoutSeconds > 30
  ) {
    fail("output evidence timeout must be an integer from 1 to 30 seconds");
  }
  return {
    timeoutSeconds,
    toolPath: argv[3],
    toolArgs: argv.slice(4),
  };
}

function runBounded({ timeoutSeconds, toolPath, toolArgs }) {
  const result = spawnSync(process.execPath, [toolPath, ...toolArgs], {
    encoding: "utf8",
    killSignal: "SIGKILL",
    maxBuffer: MAX_CAPTURE_BYTES,
    timeout: timeoutSeconds * 1000,
    windowsHide: true,
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error?.code === "ETIMEDOUT") {
    process.stderr.write(
      `ERROR: output evidence generation timed out after ${timeoutSeconds}s\n`,
    );
    return 124;
  }
  if (result.error) {
    process.stderr.write(`ERROR: ${result.error.message}\n`);
    return 1;
  }
  return Number.isInteger(result.status) ? result.status : 1;
}

try {
  process.exitCode = runBounded(parseArgs(process.argv.slice(2)));
} catch (error) {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exitCode = 2;
}
