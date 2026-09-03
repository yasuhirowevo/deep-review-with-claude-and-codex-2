#!/usr/bin/env node

import { toBashAbsolutePath } from "./path-interop.mjs";

const [reviewRunId, reviewTempRoot, reviewRunRoot, reviewArtifactDir] =
  process.argv.slice(2);

if (
  !reviewRunId ||
  !reviewTempRoot ||
  !reviewRunRoot ||
  !reviewArtifactDir ||
  process.argv.length !== 6
) {
  process.stderr.write(
    "Usage: format-review-context.mjs <run-id> <temp-root> <run-root> <artifact-dir>\n",
  );
  process.exit(2);
}

process.stdout.write(
  `${JSON.stringify({
    reviewRunId,
    reviewTempRoot: toBashAbsolutePath(reviewTempRoot),
    reviewRunRoot: toBashAbsolutePath(reviewRunRoot),
    reviewArtifactDir: toBashAbsolutePath(reviewArtifactDir),
  })}\n`,
);
