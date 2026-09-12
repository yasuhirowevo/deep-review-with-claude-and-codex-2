#!/usr/bin/env node

import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { toNativeAbsolutePath } from "./path-interop.mjs";

const REVIEWERS = ["claude", "codex"];
const VALUE_SOURCES = new Set(["environment", "config-file"]);

function assertObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
}

export function getEnabledReviewers(context) {
  assertObject(context, "context");
  if (context.reviewerConfig !== undefined) {
    assertObject(context.reviewerConfig, "context.reviewerConfig");
  }
  const enabled = REVIEWERS.filter((reviewer) => {
    const config = context.reviewerConfig?.[reviewer];
    if (config !== undefined) {
      assertObject(config, `context.reviewerConfig.${reviewer}`);
    }
    if (config && Object.hasOwn(config, "enabled")) {
      if (typeof config.enabled !== "boolean") {
        throw new Error(`context.reviewerConfig.${reviewer}.enabled must be a boolean`);
      }
      return config.enabled;
    }
    // Prepared contexts from before reviewer selection enabled both reviewers.
    return true;
  });
  if (enabled.length === 0) {
    throw new Error("at least one reviewer must be enabled");
  }
  return enabled;
}

export function assertReviewerEnabled(context, reviewer) {
  if (!REVIEWERS.includes(reviewer)) {
    throw new Error("reviewer must be claude or codex");
  }
  if (!getEnabledReviewers(context).includes(reviewer)) {
    throw new Error(`${reviewer} reviewer is disabled in the prepared context`);
  }
}

export function getAdjudicationReviewers(adjudication) {
  if (adjudication?.inputs === undefined) return [...REVIEWERS];
  const reviewers = REVIEWERS.filter((reviewer) => {
    const input = adjudication.inputs?.[reviewer];
    if (input === null) return false;
    if (!input || typeof input !== "object" || Array.isArray(input)) {
      throw new Error(`${reviewer} adjudication input is missing or invalid`);
    }
    return true;
  });
  if (reviewers.length === 0) {
    throw new Error("adjudication requires a selected reviewer");
  }
  return reviewers;
}

export function validateReviewerConfiguration(context) {
  const enabled = getEnabledReviewers(context);
  assertObject(context.reviewerConfig, "context.reviewerConfig");
  assertObject(context.reviewerConfigSources, "context.reviewerConfigSources");
  for (const reviewer of REVIEWERS) {
    const config = context.reviewerConfig[reviewer];
    const sources = context.reviewerConfigSources[reviewer];
    assertObject(config, `context.reviewerConfig.${reviewer}`);
    assertObject(sources, `context.reviewerConfigSources.${reviewer}`);
    if (Object.hasOwn(config, "enabled")) {
      if (!new Set([...VALUE_SOURCES, "default"]).has(sources.enabled)) {
        throw new Error(`context reviewer ${reviewer} enabled source is invalid`);
      }
      if (sources.enabled === "default" && config.enabled !== true) {
        throw new Error(`context reviewer ${reviewer} default selection must be enabled`);
      }
    } else if (Object.hasOwn(sources, "enabled")) {
      throw new Error(`context reviewer ${reviewer} enabled source has no value`);
    }
    for (const key of ["model", reviewer === "claude" ? "effort" : "reasoningEffort"]) {
      const value = config[key];
      const source = sources[key];
      if (!enabled.includes(reviewer) && value == null && source == null) continue;
      if (typeof value !== "string" || value.length === 0 || /\s/u.test(value)) {
        throw new Error(`context.reviewerConfig.${reviewer}.${key} must be a nonempty value without whitespace`);
      }
      if (!VALUE_SOURCES.has(source)) {
        throw new Error(`context reviewer config source is invalid: ${reviewer}.${key}`);
      }
    }
  }
  return {
    reviewerConfig: context.reviewerConfig,
    reviewerConfigSources: context.reviewerConfigSources,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2);
    if (args[0] !== "--context" || !args[1]) {
      throw new Error("usage: reviewer-selection.mjs --context <path> [--reviewer <claude|codex> | --validate-config]");
    }
    const context = JSON.parse(readFileSync(toNativeAbsolutePath(args[1]), "utf8"));
    if (args.length === 3 && args[2] === "--validate-config") {
      validateReviewerConfiguration(context);
    } else if (args.length === 4 && args[2] === "--reviewer") {
      assertReviewerEnabled(context, args[3]);
    } else if (args.length !== 2) {
      throw new Error("unsupported reviewer selection arguments");
    }
    process.stdout.write(`${JSON.stringify(getEnabledReviewers(context))}\n`);
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exitCode = 1;
  }
}
