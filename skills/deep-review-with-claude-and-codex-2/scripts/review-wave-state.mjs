#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  linkSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

import {
  assertCanStartRound,
  firstConvergenceEndIndex,
} from "./review-convergence.mjs";
import {
  replacePortablePathPrefix,
  sameNativeParentDirectory,
  toBashAbsolutePath,
  toNativeAbsolutePath,
} from "./path-interop.mjs";
import { reviewPairExitCode } from "./review-pair-policy.mjs";
import { verifyPromptManifest } from "./review-prompt-manifest.mjs";

const SCHEMA = "deep-review-wave/v1";
const LOCK_SCHEMA = "deep-review-wave-lock/v1";
const MODE_SCHEMA = "deep-review-phase4-mode/v1";
const MAX_ROUNDS = 20;
const TERMINAL_SPECULATIVE_STATES = new Set([
  "promoted",
  "aborted-incomplete",
  "cancelled-after-convergence",
  "cancelled-after-prior-failure",
  "completed-but-not-promoted",
]);

function fail(message) {
  throw new Error(message);
}

function now() {
  return new Date().toISOString();
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

function filesystemPath(filePath) {
  return toNativeAbsolutePath(filePath);
}

function persistentPath(filePath) {
  return toBashAbsolutePath(filePath);
}

function assertPlainDirectory(directory, label) {
  const nativeDirectory = filesystemPath(directory);
  const stat = lstatSync(nativeDirectory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fail(`${label} must be a plain directory`);
  }
  return realpathSync(nativeDirectory);
}

function assertRegularFile(filePath, label, requireNonEmpty = false) {
  const nativeFilePath = filesystemPath(filePath);
  const stat = lstatSync(nativeFilePath);
  if (
    stat.isSymbolicLink() ||
    !stat.isFile() ||
    (requireNonEmpty && stat.size === 0)
  ) {
    fail(`${label} must be a regular non-symlink file`);
  }
  return realpathSync(nativeFilePath);
}

function readJson(filePath, label) {
  const realFilePath = assertRegularFile(filePath, label, true);
  try {
    return JSON.parse(readFileSync(realFilePath, "utf8"));
  } catch {
    fail(`${label} is invalid JSON`);
  }
}

function atomicWriteJson(filePath, value, mode = 0o600) {
  const nativeFilePath = filesystemPath(filePath);
  const directory = assertPlainDirectory(
    path.dirname(nativeFilePath),
    "JSON parent",
  );
  const tempPath = path.join(
    directory,
    `.${path.basename(nativeFilePath)}.${process.pid}.${randomUUID()}.tmp`,
  );
  const serialized = `${JSON.stringify(value, null, 2)}\n`;
  let created = false;
  try {
    writeFileSync(tempPath, serialized, { flag: "wx", mode });
    created = true;
    chmodSync(tempPath, mode);
    renameSync(tempPath, nativeFilePath);
  } catch (error) {
    if (created) rmSync(tempPath, { force: true });
    throw error;
  }
}

function atomicCreateJson(filePath, value, mode = 0o600) {
  const nativeFilePath = filesystemPath(filePath);
  const directory = assertPlainDirectory(
    path.dirname(nativeFilePath),
    "JSON parent",
  );
  const tempPath = path.join(
    directory,
    `.${path.basename(nativeFilePath)}.${process.pid}.${randomUUID()}.candidate`,
  );
  try {
    writeFileSync(tempPath, `${JSON.stringify(value, null, 2)}\n`, {
      flag: "wx",
      mode,
    });
    chmodSync(tempPath, mode);
    try {
      linkSync(tempPath, nativeFilePath);
      return true;
    } catch (error) {
      if (error?.code === "EEXIST") return false;
      throw error;
    }
  } finally {
    rmSync(tempPath, { force: true });
  }
}

function readLockMetadata(lockPath) {
  const lock = readJson(lockPath, "wave status lock");
  if (
    lock.schema !== LOCK_SCHEMA ||
    !Number.isInteger(lock.pid) ||
    lock.pid < 1 ||
    typeof lock.nonce !== "string" ||
    lock.nonce.length === 0 ||
    typeof lock.createdAt !== "string"
  ) {
    fail("wave status lock metadata is invalid");
  }
  return lock;
}

function tryReadLockMetadata(lockPath) {
  try {
    return readLockMetadata(lockPath);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

function lockOwnerIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    if (error?.code === "EPERM") return true;
    throw error;
  }
}

function removeOwnedLock(lockPath, owner) {
  const current = tryReadLockMetadata(lockPath);
  if (current === null) return;
  if (current.pid === owner.pid && current.nonce === owner.nonce) {
    rmSync(lockPath, { force: true });
  }
}

function newLockOwner() {
  return {
    schema: LOCK_SCHEMA,
    pid: process.pid,
    nonce: randomUUID(),
    createdAt: now(),
  };
}

function newSupervisorOwner(pid) {
  if (!Number.isInteger(pid) || pid < 1) {
    fail("wave supervisor pid must be a positive integer");
  }
  return {
    pid,
    nonce: randomUUID(),
    claimedAt: now(),
  };
}

function recoverDeadLock(lockPath) {
  const recoveryPath = `${lockPath}.recovery`;
  const recoveryOwner = newLockOwner();
  if (!atomicCreateJson(recoveryPath, recoveryOwner)) {
    const existingRecovery = tryReadLockMetadata(recoveryPath);
    if (
      existingRecovery !== null &&
      !lockOwnerIsAlive(existingRecovery.pid)
    ) {
      fail(
        `stale wave recovery lock requires manual verification: ${recoveryPath}`,
      );
    }
    return false;
  }
  try {
    const observed = tryReadLockMetadata(lockPath);
    if (observed === null) return true;
    if (lockOwnerIsAlive(observed.pid)) return false;
    const confirmed = tryReadLockMetadata(lockPath);
    if (confirmed === null) return true;
    if (
      confirmed.pid !== observed.pid ||
      confirmed.nonce !== observed.nonce ||
      lockOwnerIsAlive(confirmed.pid)
    ) {
      return false;
    }
    removeOwnedLock(lockPath, confirmed);
    return true;
  } finally {
    removeOwnedLock(recoveryPath, recoveryOwner);
  }
}

function acquireLock(statusPath) {
  const lockPath = `${filesystemPath(statusPath)}.lock`;
  const recoveryPath = `${lockPath}.recovery`;
  const owner = newLockOwner();
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (!existsSync(recoveryPath) && atomicCreateJson(lockPath, owner)) {
      return () => removeOwnedLock(lockPath, owner);
    }
    if (recoverDeadLock(lockPath)) continue;
    if (attempt < 199) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
  }
  fail("wave status remained locked by another process");
}

function loadContext(contextPath) {
  const contextReal = assertRegularFile(contextPath, "review context", true);
  const context = readJson(contextReal, "review context");
  if (
    typeof context.reviewRunId !== "string" ||
    context.reviewRunId.length === 0 ||
    typeof context.reviewArtifactDir !== "string" ||
    context.reviewArtifactDir.length === 0
  ) {
    fail("review context is missing wave identity fields");
  }
  const artifactReal = assertPlainDirectory(
    context.reviewArtifactDir,
    "review artifact directory",
  );
  if (artifactReal !== realpathSync(filesystemPath(context.reviewArtifactDir))) {
    fail("review artifact directory is not canonical");
  }
  const phase4Directory = path.join(artifactReal, "phase4");
  const phase4Real = assertPlainDirectory(phase4Directory, "Phase 4 directory");
  return { context, contextReal, artifactReal, phase4Directory, phase4Real };
}

function phase4ModePath(phase4Real) {
  return path.join(phase4Real, "execution-mode.json");
}

function readPhase4Mode(loaded) {
  const modePath = phase4ModePath(loaded.phase4Real);
  if (!existsSync(modePath)) return null;
  const mode = readJson(modePath, "Phase 4 execution mode");
  if (
    mode.schema !== MODE_SCHEMA ||
    mode.reviewRunId !== loaded.context.reviewRunId ||
    !new Set(["sequential", "wave"]).has(mode.mode) ||
    typeof mode.createdAt !== "string"
  ) {
    fail("Phase 4 execution mode is invalid");
  }
  return mode;
}

function hasWaveReservation(phase4Real) {
  const wavesDirectory = path.join(phase4Real, "waves");
  return (
    existsSync(wavesDirectory) &&
    readdirSync(wavesDirectory, { withFileTypes: true }).some(
      (entry) => entry.name.startsWith("wave-"),
    )
  );
}

function claimPhase4Mode(loaded, requestedMode) {
  if (!new Set(["sequential", "wave"]).has(requestedMode)) {
    fail("Phase 4 execution mode request is invalid");
  }
  if (requestedMode === "sequential" && hasWaveReservation(loaded.phase4Real)) {
    fail("sequential execution cannot start after a wave reservation");
  }
  const modePath = phase4ModePath(loaded.phase4Real);
  const candidate = {
    schema: MODE_SCHEMA,
    reviewRunId: loaded.context.reviewRunId,
    mode: requestedMode,
    createdAt: now(),
  };
  if (!atomicCreateJson(modePath, candidate)) {
    const existing = readPhase4Mode(loaded);
    if (existing?.mode !== requestedMode) {
      fail(`Phase 4 is already reserved for ${existing?.mode ?? "unknown"} execution`);
    }
  }
  if (requestedMode === "sequential" && hasWaveReservation(loaded.phase4Real)) {
    fail("sequential execution cannot start after a wave reservation");
  }
  return readPhase4Mode(loaded);
}

export function claimSequentialPhase4({ contextPath }) {
  const loaded = loadContext(contextPath);
  return claimPhase4Mode(loaded, "sequential");
}

export function authorizeSequentialPhase4({ contextPath, round }) {
  const loaded = loadContext(contextPath);
  const normalizedRound = Number(round);
  assertCanStartRound({
    phase4Directory: loaded.phase4Directory,
    reviewRunId: loaded.context.reviewRunId,
    nextRound: normalizedRound,
  });
  claimPhase4Mode(loaded, "sequential");
  assertCanStartRound({
    phase4Directory: loaded.phase4Directory,
    reviewRunId: loaded.context.reviewRunId,
    nextRound: normalizedRound,
  });
  return {
    reviewRunId: loaded.context.reviewRunId,
    round: normalizedRound,
    mode: "sequential",
  };
}

function validateWaveIdentity(status, context, statusPath, phase4Real) {
  if (
    status?.schema !== SCHEMA ||
    status.reviewRunId !== context.reviewRunId ||
    !Number.isInteger(status.revision) ||
    status.revision < 1 ||
    !Number.isInteger(status.firstRound) ||
    status.firstRound < 1 ||
    status.firstRound >= MAX_ROUNDS ||
    status.speculativeRound !== status.firstRound + 1 ||
    status.speculativeRound > MAX_ROUNDS ||
    typeof status.createdAt !== "string" ||
    typeof status.updatedAt !== "string" ||
    !status.supervisor ||
    !Number.isInteger(status.supervisor.pid) ||
    status.supervisor.pid < 1 ||
    typeof status.supervisor.nonce !== "string" ||
    status.supervisor.nonce.length === 0 ||
    typeof status.supervisor.claimedAt !== "string" ||
    (status.reviewersReadyAt !== null &&
      status.reviewersReadyAt !== undefined &&
      typeof status.reviewersReadyAt !== "string") ||
    !Object.hasOwn(status, "termination") ||
    !status.lead ||
    !status.speculative
  ) {
    fail("wave status identity is invalid");
  }
  if (
    status.termination !== null &&
    (!status.termination ||
      !new Set(["TERM", "INT", "HUP"]).has(status.termination.signal) ||
      typeof status.termination.requestedAt !== "string" ||
      typeof status.termination.supervisorNonce !== "string" ||
      status.termination.supervisorNonce.length === 0)
  ) {
    fail("wave termination intent is invalid");
  }
  const statusReal = assertRegularFile(statusPath, "wave status", true);
  const expectedDirectory = path.join(
    phase4Real,
    "waves",
    `wave-${status.firstRound}-${status.speculativeRound}`,
  );
  if (path.dirname(statusReal) !== expectedDirectory) {
    fail("wave status path does not match its round identity");
  }
  const expectedLead = path.join(phase4Real, `round-${status.firstRound}`);
  const expectedSpeculative = path.join(
    expectedDirectory,
    `speculative-round-${status.speculativeRound}`,
  );
  const expectedCanonical = path.join(
    phase4Real,
    `round-${status.speculativeRound}`,
  );
  if (
    status.lead.round !== status.firstRound ||
    status.lead.role !== "lead" ||
    persistentPath(status.lead.artifactDir) !== persistentPath(expectedLead) ||
    status.speculative.round !== status.speculativeRound ||
    status.speculative.role !== "speculative" ||
    persistentPath(status.speculative.artifactDir) !==
      persistentPath(expectedSpeculative) ||
    persistentPath(status.speculative.canonicalArtifactDir) !==
      persistentPath(expectedCanonical)
  ) {
    fail("wave artifact paths do not match the reserved rounds");
  }
  for (const record of [status.lead, status.speculative]) {
    if (
      !record.process ||
      (record.process.pid !== null && typeof record.process.pid !== "number") ||
      (record.process.pid !== null &&
        (!Number.isInteger(record.process.pid) || record.process.pid < 1)) ||
      (record.process.signalPid !== null &&
        (!Number.isInteger(record.process.signalPid) ||
          record.process.signalPid < 1)) ||
      (record.process.supervisorNonce !== null &&
        (typeof record.process.supervisorNonce !== "string" ||
          record.process.supervisorNonce.length === 0)) ||
      (record.process.nativePidUnavailableReason !== null &&
        record.process.nativePidUnavailableReason !== undefined &&
        record.process.nativePidUnavailableReason !==
          "native-pid-handoff-failed")
    ) {
      fail("wave process identity is invalid");
    }
    const processRecord = record.process;
    const nativePidUnavailable =
      processRecord.nativePidUnavailableReason ===
      "native-pid-handoff-failed";
    if (
      ![processRecord.startedAt, processRecord.finishedAt].every(
        (value) => value === null || typeof value === "string",
      ) ||
      (processRecord.exitCode !== null &&
        (!Number.isInteger(processRecord.exitCode) ||
          processRecord.exitCode < 0)) ||
      !new Set([null, "process", "reconstructed"]).has(
        processRecord.exitCodeSource,
      ) ||
      (processRecord.signal !== null &&
        !new Set(["TERM", "INT", "HUP"]).has(processRecord.signal)) ||
      (processRecord.finishedAt !== null &&
        (processRecord.startedAt === null ||
          processRecord.exitCode === null ||
          processRecord.exitCodeSource === null)) ||
      (processRecord.finishedAt === null &&
        processRecord.exitCodeSource !== null) ||
      (processRecord.startedAt === null &&
        (processRecord.pid !== null ||
          processRecord.signalPid !== null ||
          processRecord.supervisorNonce !== null ||
          (processRecord.reviewersAuthorizedAt !== null &&
            processRecord.reviewersAuthorizedAt !== undefined))) ||
      (processRecord.startedAt !== null &&
        ((processRecord.pid === null && !nativePidUnavailable) ||
          (processRecord.pid !== null && nativePidUnavailable) ||
          processRecord.signalPid === null ||
          processRecord.supervisorNonce === null)) ||
      (processRecord.reviewersAuthorizedAt !== null &&
        processRecord.reviewersAuthorizedAt !== undefined &&
        typeof processRecord.reviewersAuthorizedAt !== "string") ||
      (record.executionEvidence !== null &&
        typeof record.executionEvidence !== "object") ||
      (nativePidUnavailable &&
        (processRecord.finishedAt === null ||
          processRecord.exitCodeSource !== "process" ||
          processRecord.signal !== status.termination?.signal ||
          processRecord.supervisorNonce !==
            status.termination?.supervisorNonce ||
          processRecord.reviewersAuthorizedAt !== null ||
          record.executionEvidence?.complete !== false ||
          status.reviewersReadyAt !== null ||
          status.reviewersReadyAt === undefined ||
          existsSync(filesystemPath(record.artifactDir)) ||
          record.state !==
            (record.role === "lead"
              ? "attempt-finished"
              : "completed-awaiting-decision")))
    ) {
      fail("wave process result is invalid");
    }
  }
  const leadStates = new Set([
    "reserved",
    "running",
    "attempt-finished",
    "canonical-complete",
    "canonical-failed",
  ]);
  const speculativeStates = new Set([
    "reserved",
    "running",
    "completed-awaiting-decision",
    ...TERMINAL_SPECULATIVE_STATES,
  ]);
  if (
    !leadStates.has(status.lead.state) ||
    !speculativeStates.has(status.speculative.state)
  ) {
    fail("wave lifecycle state is invalid");
  }
  if (TERMINAL_SPECULATIVE_STATES.has(status.speculative.state)) {
    const action = status.decision?.action;
    const expected =
      status.speculative.state === "promoted"
        ? ["promote", null]
        : status.speculative.state === "aborted-incomplete"
          ? ["promote", "incomplete-execution"]
        : status.speculative.state === "cancelled-after-convergence"
          ? ["converge", "convergence"]
          : status.speculative.state === "cancelled-after-prior-failure"
            ? ["prior-failure", "prior-round-failure"]
            : action === "converge"
              ? ["converge", "convergence"]
              : ["prior-failure", "prior-round-failure"];
    if (
      action !== expected[0] ||
      status.speculative.nonPromotionReason !== expected[1]
    ) {
      fail("terminal speculative state does not match its wave decision");
    }
    if (
      status.speculative.state === "aborted-incomplete" &&
      (status.speculative.process.finishedAt === null ||
        status.speculative.executionEvidence?.complete !== false ||
        pairFinished(status.speculative))
    ) {
      fail("aborted speculative state must retain incomplete execution evidence");
    }
  }
  return status;
}

function assertAttachableReservation(status) {
  if (
    status.termination !== null ||
    status.decision !== null ||
    status.speculative.promotion !== null ||
    status.speculative.nonPromotionReason !== null ||
    !new Set(["reserved", "running", "attempt-finished"]).has(
      status.lead.state,
    ) ||
    !new Set(["reserved", "running", "completed-awaiting-decision"]).has(
      status.speculative.state,
    )
  ) {
    fail("existing wave reservation cannot be attached before its decision");
  }
  for (const record of [status.lead, status.speculative]) {
    if (record.process.startedAt === null) {
      if (
        Object.values(record.process).some((value) => value !== null) ||
        record.executionEvidence !== null ||
        existsSync(filesystemPath(record.artifactDir))
      ) {
        fail("unclaimed wave role already has execution artifacts");
      }
    } else if (existsSync(filesystemPath(record.artifactDir))) {
      assertPlainDirectory(record.artifactDir, "attached wave role artifact");
    }
  }
}

function loadWave({ contextPath, statusPath }) {
  const loaded = loadContext(contextPath);
  const status = readJson(statusPath, "wave status");
  validateWaveIdentity(
    status,
    loaded.context,
    statusPath,
    loaded.phase4Real,
  );
  return {
    ...loaded,
    status,
    statusPath: realpathSync(filesystemPath(statusPath)),
  };
}

function updateWave({ contextPath, statusPath }, updater) {
  const release = acquireLock(statusPath);
  try {
    const loaded = loadWave({ contextPath, statusPath });
    const updated = updater(loaded.status, loaded);
    updated.revision = loaded.status.revision + 1;
    updated.updatedAt = now();
    validateWaveIdentity(
      updated,
      loaded.context,
      loaded.statusPath,
      loaded.phase4Real,
    );
    atomicWriteJson(loaded.statusPath, updated);
    return updated;
  } finally {
    release();
  }
}

function canonicalRoundDirectories(phase4Directory) {
  return readdirSync(phase4Directory, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^round-\d+$/u.test(entry.name))
    .map((entry) => Number(entry.name.slice("round-".length)))
    .sort((left, right) => left - right);
}

function verifyWavePrompt(context, promptPath, reviewer, round) {
  return verifyPromptManifest({
    context,
    promptPath,
    reviewer,
    phase: "convergence",
    round,
    purpose: "review",
  });
}

export function reserveWave({
  contextPath,
  firstRound,
  claudeLeadPrompt,
  codexLeadPrompt,
  claudeSpeculativePrompt,
  codexSpeculativePrompt,
  supervisorPid,
}) {
  const { context, artifactReal, phase4Directory, phase4Real } =
    loadContext(contextPath);
  const normalizedFirst = Number(firstRound);
  if (
    !Number.isInteger(normalizedFirst) ||
    normalizedFirst < 1 ||
    normalizedFirst >= MAX_ROUNDS
  ) {
    fail(`wave first round must be between 1 and ${MAX_ROUNDS - 1}`);
  }
  const wavesDirectory = path.join(phase4Real, "waves");
  assertPlainDirectory(wavesDirectory, "wave directory");
  const speculativeRound = normalizedFirst + 1;
  const waveDirectory = path.join(
    wavesDirectory,
    `wave-${normalizedFirst}-${speculativeRound}`,
  );
  const statusPath = path.join(waveDirectory, "status.json");
  const existingWave = existsSync(waveDirectory);
  const existingRounds = canonicalRoundDirectories(phase4Directory);
  const expectedRounds = Array.from(
    { length: normalizedFirst - 1 },
    (_, index) => index + 1,
  );
  const attachableRounds = [...expectedRounds, normalizedFirst];
  if (
    JSON.stringify(existingRounds) !== JSON.stringify(expectedRounds) &&
    (!existingWave ||
      JSON.stringify(existingRounds) !== JSON.stringify(attachableRounds))
  ) {
    fail("wave first round is not the next canonical convergence round");
  }
  if (!existingWave) {
    assertCanStartRound({
      phase4Directory,
      reviewRunId: context.reviewRunId,
      nextRound: normalizedFirst,
    });
  }
  const promptReceipts = {
    lead: {
      claude: verifyWavePrompt(
        context,
        claudeLeadPrompt,
        "claude",
        normalizedFirst,
      ),
      codex: verifyWavePrompt(
        context,
        codexLeadPrompt,
        "codex",
        normalizedFirst,
      ),
    },
    speculative: {
      claude: verifyWavePrompt(
        context,
        claudeSpeculativePrompt,
        "claude",
        speculativeRound,
      ),
      codex: verifyWavePrompt(
        context,
        codexSpeculativePrompt,
        "codex",
        speculativeRound,
      ),
    },
  };

  const priorWaves = inspectReviewWaves({
    context,
    artifactDirectory: artifactReal,
    ignoredPristineStatusPath: existingWave ? statusPath : null,
  });
  if (
    JSON.stringify(priorWaves.canonicalRounds) !==
    JSON.stringify(expectedRounds)
  ) {
    fail("canonical rounds do not match the prior wave sequence");
  }
  if (
    priorWaves.waves.at(-1)?.status.speculative.state ===
    "aborted-incomplete"
  ) {
    fail("an aborted speculative wave requires a new review run");
  }

  claimPhase4Mode(
    { context, artifactReal, phase4Directory, phase4Real },
    "wave",
  );

  if (existsSync(waveDirectory)) {
    const status = updateWave(
      { contextPath, statusPath },
      (existingStatus, loaded) => {
        assertAttachableReservation(existingStatus);
        validatePromptReceipts(existingStatus, loaded.context);
        if (
          JSON.stringify(existingStatus.lead.prompts) !==
            JSON.stringify(promptReceipts.lead) ||
          JSON.stringify(existingStatus.speculative.prompts) !==
            JSON.stringify(promptReceipts.speculative)
        ) {
          fail("existing wave reservation uses different prompts");
        }
        if (lockOwnerIsAlive(existingStatus.supervisor.pid)) {
          fail("existing wave reservation has an active supervisor");
        }
        existingStatus.supervisor = newSupervisorOwner(Number(supervisorPid));
        return existingStatus;
      },
    );
    return {
      statusPath: persistentPath(realpathSync(filesystemPath(statusPath))),
      status,
      reattached: true,
      launch: {
        lead: status.lead.process.startedAt === null,
        speculative: status.speculative.process.startedAt === null,
      },
    };
  }

  const stagingDirectory = path.join(
    wavesDirectory,
    `.wave-${normalizedFirst}-${speculativeRound}.reserving-${process.pid}-${randomUUID()}`,
  );
  mkdirSync(stagingDirectory, { mode: 0o700 });
  chmodSync(stagingDirectory, 0o700);
  const timestamp = now();
  const processRecord = () => ({
    pid: null,
    signalPid: null,
    supervisorNonce: null,
    nativePidUnavailableReason: null,
    reviewersAuthorizedAt: null,
    startedAt: null,
    finishedAt: null,
    exitCode: null,
    exitCodeSource: null,
    signal: null,
  });
  const status = {
    schema: SCHEMA,
    reviewRunId: context.reviewRunId,
    revision: 1,
    firstRound: normalizedFirst,
    speculativeRound,
    createdAt: timestamp,
    updatedAt: timestamp,
    supervisor: newSupervisorOwner(Number(supervisorPid)),
    reviewersReadyAt: null,
    termination: null,
    decision: null,
    lead: {
      round: normalizedFirst,
      role: "lead",
      state: "reserved",
      artifactDir: persistentPath(
        path.join(phase4Real, `round-${normalizedFirst}`),
      ),
      prompts: promptReceipts.lead,
      process: processRecord(),
      executionEvidence: null,
    },
    speculative: {
      round: speculativeRound,
      role: "speculative",
      state: "reserved",
      artifactDir: persistentPath(
        path.join(waveDirectory, `speculative-round-${speculativeRound}`),
      ),
      canonicalArtifactDir: persistentPath(
        path.join(phase4Real, `round-${speculativeRound}`),
      ),
      prompts: promptReceipts.speculative,
      process: processRecord(),
      executionEvidence: null,
      promotion: null,
      nonPromotionReason: null,
    },
  };
  try {
    atomicWriteJson(path.join(stagingDirectory, "status.json"), status);
    renameSync(stagingDirectory, waveDirectory);
    return {
      statusPath: persistentPath(statusPath),
      status,
      reattached: false,
      launch: { lead: true, speculative: true },
    };
  } catch (error) {
    rmSync(stagingDirectory, { recursive: true, force: true });
    throw error;
  }
}

export function authorizeWavePair({
  contextPath,
  statusPath,
  role,
  round,
  attempt,
  reviewer,
  claudePrompt,
  claudePromptPurpose,
  codexPrompt,
  codexPromptPurpose,
  supervisorNonce,
  processPid,
  signalPid,
}) {
  const normalizedRound = Number(round);
  const normalizedAttempt = Number(attempt);
  if (!new Set(["lead", "speculative"]).has(role)) {
    fail("wave role must be lead or speculative");
  }
  if (!Number.isInteger(normalizedAttempt) || normalizedAttempt < 1) {
    fail("wave attempt must be a positive integer");
  }
  if (!new Set(["both", "claude", "codex"]).has(reviewer)) {
    fail("wave reviewer must be both, claude, or codex");
  }
  const authorize = (status, loaded) => {
    const record = status[role];
    if (record.round !== normalizedRound) {
      fail("wave role does not match the requested round");
    }
    if (role === "lead") {
      if (normalizedAttempt === 1) {
        assertCanStartRound({
          phase4Directory: loaded.phase4Directory,
          reviewRunId: loaded.context.reviewRunId,
          nextRound: normalizedRound,
        });
      }
      if (status.decision !== null) {
        fail("lead round cannot run after the wave decision is fixed");
      }
    } else {
      if (normalizedAttempt !== 1) {
        fail("speculative retry requires promotion to the canonical round");
      }
      if (status.decision !== null) {
        fail("speculative attempt cannot start after a wave decision");
      }
    }
    const requestedReviewers =
      reviewer === "both" ? ["claude", "codex"] : [reviewer];
    for (const requested of requestedReviewers) {
      const supplied = requested === "claude" ? claudePrompt : codexPrompt;
      const purpose =
        requested === "claude" ? claudePromptPurpose : codexPromptPurpose;
      if (!new Set(["review", "resume"]).has(purpose)) {
        fail(`${requested} wave prompt purpose is invalid`);
      }
      if (purpose === "resume" && (role !== "lead" || normalizedAttempt === 1)) {
        fail("only a lead retry may use a resume prompt");
      }
      const receipt = verifyPromptManifest({
        context: loaded.context,
        promptPath: supplied,
        reviewer: requested,
        phase: "convergence",
        round: normalizedRound,
        purpose,
      });
      if (
        purpose === "review" &&
        receipt.promptPath !== record.prompts[requested].promptPath
      ) {
        fail(`${requested} prompt does not match the reserved wave prompt`);
      }
    }
    return record;
  };
  let loaded;
  let record;
  if (normalizedAttempt === 1) {
    const normalizedProcessPid = Number(processPid);
    const normalizedSignalPid = Number(signalPid);
    if (
      typeof supervisorNonce !== "string" ||
      supervisorNonce.length === 0 ||
      !Number.isInteger(normalizedProcessPid) ||
      normalizedProcessPid < 1 ||
      !Number.isInteger(normalizedSignalPid) ||
      normalizedSignalPid < 1
    ) {
      fail("wave attempt 1 requires a valid launch claim");
    }
    const status = updateWave(
      { contextPath, statusPath },
      (current, currentLoaded) => {
        record = authorize(current, currentLoaded);
        if (current.supervisor.nonce !== supervisorNonce) {
          fail("wave launch belongs to a superseded supervisor");
        }
        if (record.process.startedAt !== null) {
          fail("wave role launch has already been claimed");
        }
        record.process.pid = normalizedProcessPid;
        record.process.signalPid = normalizedSignalPid;
        record.process.supervisorNonce = supervisorNonce;
        record.process.startedAt = now();
        record.state = "running";
        loaded = currentLoaded;
        return current;
      },
    );
    record = status[role];
  } else {
    loaded = loadWave({ contextPath, statusPath });
    record = authorize(loaded.status, loaded);
  }
  return {
    phaseDirectory: record.artifactDir,
    reviewRunId: loaded.context.reviewRunId,
    round: normalizedRound,
    role,
  };
}

export function recordWaveProcessStart({
  contextPath,
  statusPath,
  role,
  pid,
}) {
  const normalizedPid = Number(pid);
  if (!Number.isInteger(normalizedPid) || normalizedPid < 1) {
    fail("wave process pid must be a positive integer");
  }
  return updateWave({ contextPath, statusPath }, (status) => {
    const record = status[role];
    if (!record || record.process.startedAt !== null) {
      fail("wave process has already started or role is invalid");
    }
    record.process.pid = normalizedPid;
    record.process.signalPid = normalizedPid;
    record.process.supervisorNonce = status.supervisor.nonce;
    record.process.startedAt = now();
    record.state = "running";
    return status;
  });
}

export function authorizeWaveReviewerLaunch({
  contextPath,
  statusPath,
  role,
  supervisorNonce,
  processPid,
}) {
  if (!new Set(["lead", "speculative"]).has(role)) {
    fail("wave role must be lead or speculative");
  }
  const normalizedProcessPid = Number(processPid);
  let authorization = {
    authorized: true,
    pending: false,
    signal: null,
    source: null,
    supervisorNonce: null,
  };
  updateWave({ contextPath, statusPath }, (status) => {
    const record = status[role];
    if (
      typeof supervisorNonce !== "string" ||
      supervisorNonce.length === 0 ||
      !Number.isInteger(normalizedProcessPid) ||
      normalizedProcessPid < 1 ||
      record.process.supervisorNonce !== supervisorNonce ||
      record.process.pid !== normalizedProcessPid ||
      record.process.startedAt === null ||
      record.process.finishedAt !== null
    ) {
      fail("wave reviewer launch does not match its role claim");
    }
    authorization.supervisorNonce = status.supervisor.nonce;
    if (status.termination !== null) {
      authorization = {
        authorized: false,
        pending: false,
        signal: status.termination.signal,
        source: "wave-termination",
        supervisorNonce: status.supervisor.nonce,
      };
      return status;
    }
    if (
      role === "speculative" &&
      new Set(["converge", "prior-failure"]).has(status.decision?.action)
    ) {
      authorization = {
        authorized: false,
        pending: false,
        signal: "TERM",
        source: "wave-decision",
        supervisorNonce: status.supervisor.nonce,
      };
      return status;
    }
    if (status.reviewersReadyAt === null || status.reviewersReadyAt === undefined) {
      authorization = {
        authorized: false,
        pending: true,
        signal: null,
        source: "wave-role-claims",
        supervisorNonce: status.supervisor.nonce,
      };
      return status;
    }
    if (
      record.process.reviewersAuthorizedAt === null ||
      record.process.reviewersAuthorizedAt === undefined
    ) {
      record.process.reviewersAuthorizedAt = now();
    }
    return status;
  });
  return authorization;
}

export function expireWaveReviewerAuthorization({
  contextPath,
  statusPath,
  role,
  supervisorNonce,
  processPid,
  activeSupervisorNonce,
}) {
  if (!new Set(["lead", "speculative"]).has(role)) {
    fail("wave role must be lead or speculative");
  }
  const normalizedProcessPid = Number(processPid);
  if (
    typeof supervisorNonce !== "string" ||
    supervisorNonce.length === 0 ||
    !Number.isInteger(normalizedProcessPid) ||
    normalizedProcessPid < 1 ||
    typeof activeSupervisorNonce !== "string" ||
    activeSupervisorNonce.length === 0
  ) {
    fail("wave reviewer authorization timeout identity is invalid");
  }
  let expiration = {
    expired: false,
    signal: null,
    source: null,
    supervisorNonce: null,
  };
  updateWave({ contextPath, statusPath }, (status) => {
    const record = status[role];
    if (
      record.process.supervisorNonce !== supervisorNonce ||
      record.process.pid !== normalizedProcessPid ||
      record.process.startedAt === null ||
      record.process.finishedAt !== null
    ) {
      fail("wave reviewer authorization timeout does not match its role claim");
    }
    expiration.supervisorNonce = status.supervisor.nonce;
    if (status.termination !== null) {
      expiration.expired = true;
      expiration.signal = status.termination.signal;
      expiration.source = "wave-termination";
      return status;
    }
    if (
      status.supervisor.nonce !== activeSupervisorNonce ||
      (status.reviewersReadyAt !== null &&
        status.reviewersReadyAt !== undefined) ||
      status.decision !== null
    ) {
      return status;
    }
    status.termination = {
      signal: "TERM",
      requestedAt: now(),
      supervisorNonce: status.supervisor.nonce,
    };
    expiration.expired = true;
    expiration.signal = "TERM";
    expiration.source = "reviewer-authorization-timeout";
    return status;
  });
  return expiration;
}

export function markWaveReviewersReady({
  contextPath,
  statusPath,
  supervisorNonce,
}) {
  return updateWave({ contextPath, statusPath }, (status) => {
    if (
      typeof supervisorNonce !== "string" ||
      supervisorNonce.length === 0 ||
      status.supervisor.nonce !== supervisorNonce ||
      status.termination !== null ||
      status.decision !== null
    ) {
      fail("wave reviewers require the active undecided supervisor");
    }
    if (status.reviewersReadyAt !== null && status.reviewersReadyAt !== undefined) {
      return status;
    }
    if (
      [status.lead, status.speculative].some(
        (record) =>
          record.process.startedAt === null ||
          record.process.finishedAt !== null ||
          record.process.reviewersAuthorizedAt !== null,
      )
    ) {
      fail("wave reviewers require both live role claims");
    }
    status.reviewersReadyAt = now();
    return status;
  });
}

function pairStatusPath(record) {
  return path.join(filesystemPath(record.artifactDir), "status.json");
}

function pairFinished(record) {
  return existsSync(pairStatusPath(record));
}

function readPairStatus(record, reviewRunId) {
  const status = readJson(pairStatusPath(record), "wave pair status");
  if (
    status.schema !== "deep-review-pair/v6" ||
    status.reviewRunId !== reviewRunId ||
    status.phase !== "convergence" ||
    status.round !== record.round ||
    !Array.isArray(status.attempts) ||
    status.attempts.length === 0
  ) {
    fail("wave pair status identity is invalid");
  }
  return status;
}

function firstAttemptExitCode(pairStatus) {
  const attempt = pairStatus.attempts.find((candidate) => candidate.attempt === 1);
  if (!attempt) fail("wave pair status is missing attempt 1");
  const requested = ["claude", "codex"].filter(
    (reviewer) => attempt[reviewer]?.requested === true,
  );
  if (requested.length === 0) fail("wave attempt 1 has no requested reviewer");
  return reviewPairExitCode(
    requested.map((reviewer) => attempt[reviewer].exitCode),
  );
}

function reconcileRecordFromPairStatus(status, role) {
  const record = status[role];
  if (!pairFinished(record)) return false;
  const pairStatus = readPairStatus(record, status.reviewRunId);
  if (
    record.process.finishedAt === null &&
    ((record.process.pid !== null && lockOwnerIsAlive(record.process.pid)) ||
      (record.process.supervisorNonce === status.supervisor.nonce &&
        lockOwnerIsAlive(status.supervisor.pid)))
  ) {
    return true;
  }
  if (record.process.startedAt === null) record.process.startedAt = now();
  if (record.process.finishedAt === null) {
    record.process.finishedAt = now();
    record.process.exitCode = firstAttemptExitCode(pairStatus);
    record.process.exitCodeSource = "reconstructed";
    record.process.signal = null;
  }
  record.executionEvidence = buildExecutionEvidence(record, status.reviewRunId);
  if (role === "lead" && status.decision === null) {
    record.state = "attempt-finished";
  } else if (
    role === "speculative" &&
    !TERMINAL_SPECULATIVE_STATES.has(record.state)
  ) {
    record.state = "completed-awaiting-decision";
  }
  return true;
}

function fileReceipt(filePath, label) {
  const real = assertRegularFile(filePath, label);
  const content = readFileSync(real);
  return {
    path: persistentPath(real),
    bytes: content.length,
    sha256: sha256(content),
  };
}

function buildExecutionEvidence(record, reviewRunId) {
  const statusPath = pairStatusPath(record);
  if (!existsSync(statusPath)) {
    const attempts = [];
    const artifactDirectory = filesystemPath(record.artifactDir);
    if (existsSync(artifactDirectory)) {
      assertPlainDirectory(artifactDirectory, "partial wave artifact");
      for (const entry of readdirSync(artifactDirectory, {
        withFileTypes: true,
      }).sort((left, right) => left.name.localeCompare(right.name))) {
        if (!entry.isDirectory() || !/^attempt-\d+$/u.test(entry.name)) continue;
        const attemptDirectory = path.join(artifactDirectory, entry.name);
        const attempt = { attempt: Number(entry.name.slice(8)) };
        for (const reviewer of ["claude", "codex"]) {
          attempt[reviewer] = {};
          for (const stream of ["stdout", "stderr"]) {
            const filePath = path.join(
              attemptDirectory,
              `${reviewer}.${stream === "stdout" ? "out" : "err"}`,
            );
            attempt[reviewer][stream] = existsSync(filePath)
              ? fileReceipt(filePath, `partial ${reviewer} wave ${stream}`)
              : null;
          }
        }
        attempts.push(attempt);
      }
    }
    const evidence = {
      schema: "deep-review-wave-execution-evidence/v1",
      complete: false,
      pairStatus: null,
      attempts,
    };
    return {
      ...evidence,
      sha256: sha256(Buffer.from(JSON.stringify(evidence), "utf8")),
    };
  }
  const pairStatus = readPairStatus(record, reviewRunId);
  const evidence = {
    schema: "deep-review-wave-execution-evidence/v1",
    complete: true,
    pairStatus: fileReceipt(statusPath, "wave pair status"),
    attempts: pairStatus.attempts.map((attempt) => {
      const result = {
        attempt: attempt.attempt,
        interrupted: attempt.interrupted,
      };
      for (const reviewer of ["claude", "codex"]) {
        const reviewerAttempt = attempt[reviewer];
        result[reviewer] = reviewerAttempt.requested
          ? {
              exitCode: reviewerAttempt.exitCode,
              stdout: fileReceipt(
                reviewerAttempt.stdout,
                `${reviewer} wave stdout`,
              ),
              stderr: fileReceipt(
                reviewerAttempt.stderr,
                `${reviewer} wave stderr`,
              ),
              outputEvidence: reviewerAttempt.evidence,
            }
          : null;
      }
      return result;
    }),
  };
  return {
    ...evidence,
    sha256: sha256(Buffer.from(JSON.stringify(evidence), "utf8")),
  };
}

function validateExecutionEvidence(record, reviewRunId) {
  if (
    JSON.stringify(record.executionEvidence) !==
    JSON.stringify(buildExecutionEvidence(record, reviewRunId))
  ) {
    fail("wave execution evidence no longer matches its artifacts");
  }
}

function replacePrefix(value, sourcePrefix, destinationPrefix) {
  if (typeof value === "string") {
    return replacePortablePathPrefix(value, sourcePrefix, destinationPrefix);
  }
  if (Array.isArray(value)) {
    return value.map((item) =>
      replacePrefix(item, sourcePrefix, destinationPrefix),
    );
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        replacePrefix(item, sourcePrefix, destinationPrefix),
      ]),
    );
  }
  return value;
}

function copyPlainTree(source, destination) {
  mkdirSync(destination, { mode: 0o700 });
  for (const entry of readdirSync(source, { withFileTypes: true })) {
    const sourcePath = path.join(source, entry.name);
    const destinationPath = path.join(destination, entry.name);
    const stat = lstatSync(sourcePath);
    if (stat.isSymbolicLink()) fail("speculative artifact contains a symlink");
    if (entry.isDirectory()) {
      copyPlainTree(sourcePath, destinationPath);
    } else if (entry.isFile()) {
      copyFileSync(sourcePath, destinationPath, 0);
      chmodSync(destinationPath, stat.mode & 0o777);
    } else {
      fail("speculative artifact contains an unsupported filesystem entry");
    }
  }
}

function removeAbandonedPromotionStaging(phase4Directory, round) {
  const prefix = `.round-${round}.promoting-`;
  for (const entry of readdirSync(phase4Directory, { withFileTypes: true })) {
    if (!entry.name.startsWith(prefix)) continue;
    const candidate = path.join(phase4Directory, entry.name);
    const stat = lstatSync(candidate);
    if (stat.isSymbolicLink() || !entry.isDirectory()) {
      fail("abandoned promotion staging path is not a plain directory");
    }
    rmSync(candidate, { recursive: true, force: true });
  }
}

function rewritePromotedStatuses(root, sourcePrefix, destinationPrefix) {
  const statusPaths = [path.join(root, "status.json")];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (entry.isDirectory() && /^attempt-\d+$/u.test(entry.name)) {
      statusPaths.push(path.join(root, entry.name, "status.json"));
    }
  }
  for (const statusPath of statusPaths) {
    const rewritten = replacePrefix(
      readJson(statusPath, "promoted pair status"),
      sourcePrefix,
      destinationPrefix,
    );
    atomicWriteJson(statusPath, rewritten);
  }
}

function comparableTreeDigest(root, pathPrefix = root) {
  const entries = [];
  function walk(directory, relativeDirectory = "") {
    for (const entry of readdirSync(directory, { withFileTypes: true }).sort(
      (left, right) => left.name.localeCompare(right.name),
    )) {
      const absolute = path.join(directory, entry.name);
      const relative = path.join(relativeDirectory, entry.name);
      const stat = lstatSync(absolute);
      if (stat.isSymbolicLink()) fail("wave artifact contains a symlink");
      if (entry.isDirectory()) {
        entries.push(`d\0${relative}\0`);
        walk(absolute, relative);
      } else if (entry.isFile()) {
        let content = readFileSync(absolute);
        if (
          entry.name === "status.json" &&
          (relativeDirectory === "" || /^attempt-\d+$/u.test(relativeDirectory))
        ) {
          const normalized = replacePrefix(
            JSON.parse(content.toString("utf8")),
            pathPrefix,
            "$ROUND_DIR",
          );
          content = Buffer.from(`${JSON.stringify(normalized)}\n`, "utf8");
        }
        entries.push(`f\0${relative}\0${sha256(content)}\0`);
      } else {
        fail("wave artifact contains an unsupported filesystem entry");
      }
    }
  }
  walk(root);
  return sha256(Buffer.from(entries.join(""), "utf8"));
}

function promoteCompletedSpeculative(status, loaded) {
  const sourceIdentity = status.speculative.artifactDir;
  const destinationIdentity = status.speculative.canonicalArtifactDir;
  const source = filesystemPath(sourceIdentity);
  const destination = filesystemPath(destinationIdentity);
  assertPlainDirectory(source, "speculative round artifact");
  readPairStatus(status.speculative, status.reviewRunId);
  removeAbandonedPromotionStaging(
    loaded.phase4Real,
    status.speculativeRound,
  );
  const staging = path.join(
    loaded.phase4Real,
    `.round-${status.speculativeRound}.promoting-${process.pid}-${randomUUID()}`,
  );
  try {
    const sourceDigest = comparableTreeDigest(source, sourceIdentity);
    if (existsSync(destination)) {
      assertPlainDirectory(destination, "canonical speculative round artifact");
      if (
        sourceDigest !==
        comparableTreeDigest(destination, destinationIdentity)
      ) {
        fail("existing canonical round differs from its speculative source");
      }
    } else {
      copyPlainTree(source, staging);
      rewritePromotedStatuses(
        staging,
        sourceIdentity,
        destinationIdentity,
      );
      const stagingDigest = comparableTreeDigest(
        staging,
        destinationIdentity,
      );
      if (sourceDigest !== stagingDigest) {
        fail("promoted round differs from its speculative source");
      }
      renameSync(staging, destination);
    }
    const receiptFilePath = path.join(
      path.dirname(loaded.statusPath),
      "promotion.json",
    );
    const receiptPath = persistentPath(receiptFilePath);
    let receipt;
    if (existsSync(receiptFilePath)) {
      receipt = readJson(receiptFilePath, "promotion receipt");
      if (
        receipt.schema !== "deep-review-wave-promotion/v1" ||
        receipt.reviewRunId !== status.reviewRunId ||
        receipt.round !== status.speculativeRound ||
        receipt.sourceArtifactDir !== sourceIdentity ||
        receipt.canonicalArtifactDir !== destinationIdentity ||
        receipt.comparableTreeSha256 !== sourceDigest ||
        typeof receipt.promotedAt !== "string"
      ) {
        fail("existing promotion receipt does not match the recovered promotion");
      }
    } else {
      receipt = {
        schema: "deep-review-wave-promotion/v1",
        reviewRunId: status.reviewRunId,
        round: status.speculativeRound,
        sourceArtifactDir: sourceIdentity,
        canonicalArtifactDir: destinationIdentity,
        comparableTreeSha256: sourceDigest,
        promotedAt: now(),
      };
      atomicWriteJson(receiptFilePath, receipt);
    }
    status.speculative.state = "promoted";
    status.speculative.promotion = {
      path: receiptPath,
      sha256: sha256(readFileSync(receiptFilePath)),
      promotedAt: receipt.promotedAt,
    };
    status.speculative.nonPromotionReason = null;
  } catch (error) {
    rmSync(staging, { recursive: true, force: true });
    throw error;
  }
}

function finalizeDecision(status, loaded) {
  if (!status.decision) return;
  if (status.speculative.state === "aborted-incomplete") return;
  reconcileRecordFromPairStatus(status, "speculative");
  if (status.speculative.process.finishedAt === null) return;
  if (status.decision.action === "promote") {
    if (!pairFinished(status.speculative)) {
      status.speculative.executionEvidence = buildExecutionEvidence(
        status.speculative,
        status.reviewRunId,
      );
      status.speculative.state = "aborted-incomplete";
      status.speculative.nonPromotionReason = "incomplete-execution";
      return;
    }
    if (status.speculative.state !== "promoted") {
      promoteCompletedSpeculative(status, loaded);
    }
    return;
  }
  if (!new Set(["converge", "prior-failure"]).has(status.decision.action)) {
    fail("wave decision action is invalid");
  }
  if (
    !pairFinished(status.speculative) &&
    status.speculative.process.finishedAt === null
  ) {
    return;
  }
  status.speculative.executionEvidence = buildExecutionEvidence(
    status.speculative,
    status.reviewRunId,
  );
  const interrupted = pairFinished(status.speculative)
    ? readPairStatus(status.speculative, status.reviewRunId).attempts.some(
        (attempt) => attempt.interrupted === true,
      )
    : true;
  if (status.decision.action === "converge") {
    status.speculative.state = interrupted
      ? "cancelled-after-convergence"
      : "completed-but-not-promoted";
    status.speculative.nonPromotionReason = "convergence";
  } else {
    status.speculative.state = interrupted
      ? "cancelled-after-prior-failure"
      : "completed-but-not-promoted";
    status.speculative.nonPromotionReason = "prior-round-failure";
  }
}

export function recoverAttachedWaveProcess({
  contextPath,
  statusPath,
  role,
  supervisorNonce,
}) {
  return updateWave({ contextPath, statusPath }, (status, loaded) => {
    if (status.supervisor.nonce !== supervisorNonce) {
      fail("wave recovery belongs to a superseded supervisor");
    }
    const record = status[role];
    if (!record || record.process.startedAt === null) {
      fail("attached wave process has not started or role is invalid");
    }
    if (record.process.supervisorNonce === supervisorNonce) {
      fail("current supervisor must record its own wave process result");
    }
    if (record.process.finishedAt !== null) {
      finalizeDecision(status, loaded);
      return status;
    }
    if (lockOwnerIsAlive(record.process.pid)) return status;
    if (pairFinished(record)) {
      reconcileRecordFromPairStatus(status, role);
      finalizeDecision(status, loaded);
      return status;
    }
    record.process.finishedAt = now();
    record.process.exitCode = 1;
    record.process.exitCodeSource = "reconstructed";
    record.process.signal = null;
    record.executionEvidence = buildExecutionEvidence(
      record,
      status.reviewRunId,
    );
    if (role === "lead") {
      record.state = "attempt-finished";
    } else if (!TERMINAL_SPECULATIVE_STATES.has(record.state)) {
      record.state = "completed-awaiting-decision";
    }
    finalizeDecision(status, loaded);
    return status;
  });
}

export function recordWaveProcessResult({
  contextPath,
  statusPath,
  role,
  exitCode,
  signal = null,
  supervisorNonce = null,
  processPid = null,
}) {
  const normalizedExit = Number(exitCode);
  if (!Number.isInteger(normalizedExit) || normalizedExit < 0) {
    fail("wave process exit code must be a non-negative integer");
  }
  return updateWave({ contextPath, statusPath }, (status, loaded) => {
    const record = status[role];
    if (!record || record.process.startedAt === null) {
      fail("wave process has not started or role is invalid");
    }
    if (supervisorNonce !== null || processPid !== null) {
      const normalizedProcessPid = Number(processPid);
      if (
        typeof supervisorNonce !== "string" ||
        supervisorNonce.length === 0 ||
        !Number.isInteger(normalizedProcessPid) ||
        normalizedProcessPid < 1 ||
        record.process.supervisorNonce !== supervisorNonce ||
        record.process.pid !== normalizedProcessPid
      ) {
        fail("wave process result does not match its launch claim");
      }
    }
    if (record.process.finishedAt !== null) {
      if (record.state === "aborted-incomplete") {
        fail("wave process result arrived after incomplete execution was finalized");
      }
      if (record.process.exitCodeSource === "reconstructed") {
        fail(
          "wave process result arrived after recovered result was finalized",
        );
      }
      if (record.process.exitCode !== normalizedExit) {
        fail("wave process result conflicts with its recorded exit code");
      }
      if (
        signal !== null &&
        record.process.signal !== null &&
        record.process.signal !== signal
      ) {
        fail("wave process result conflicts with its recorded signal");
      }
      if (signal !== null) record.process.signal = signal;
      record.executionEvidence = buildExecutionEvidence(
        record,
        status.reviewRunId,
      );
      finalizeDecision(status, loaded);
      return status;
    }
    record.process.finishedAt = now();
    record.process.exitCode = normalizedExit;
    record.process.exitCodeSource = "process";
    record.process.signal = signal;
    record.executionEvidence = buildExecutionEvidence(
      record,
      status.reviewRunId,
    );
    if (role === "lead") {
      record.state = "attempt-finished";
    } else if (!TERMINAL_SPECULATIVE_STATES.has(record.state)) {
      record.state = "completed-awaiting-decision";
    }
    finalizeDecision(status, loaded);
    return status;
  });
}

export function abortUnclaimedWaveProcess({
  contextPath,
  statusPath,
  role,
  exitCode,
  signal,
  supervisorNonce,
  processPid,
  signalPid,
}) {
  const normalizedExit = Number(exitCode);
  const normalizedProcessPid = Number(processPid);
  const normalizedSignalPid = Number(signalPid);
  if (
    !new Set(["lead", "speculative"]).has(role) ||
    !Number.isInteger(normalizedExit) ||
    normalizedExit < 0 ||
    !new Set(["TERM", "INT", "HUP"]).has(signal) ||
    typeof supervisorNonce !== "string" ||
    supervisorNonce.length === 0 ||
    !Number.isInteger(normalizedProcessPid) ||
    normalizedProcessPid < 1 ||
    !Number.isInteger(normalizedSignalPid) ||
    normalizedSignalPid < 1
  ) {
    fail("aborted wave process identity is invalid");
  }
  return updateWave({ contextPath, statusPath }, (status, loaded) => {
    if (status.supervisor.nonce !== supervisorNonce) {
      fail("aborted wave process belongs to a superseded supervisor");
    }
    const record = status[role];
    if (record.process.startedAt === null) {
      record.process.pid = normalizedProcessPid;
      record.process.signalPid = normalizedSignalPid;
      record.process.supervisorNonce = supervisorNonce;
      record.process.startedAt = now();
      record.state = "running";
    } else if (
      record.process.pid !== normalizedProcessPid ||
      record.process.signalPid !== normalizedSignalPid ||
      record.process.supervisorNonce !== supervisorNonce
    ) {
      fail("aborted wave process does not match its launch claim");
    }
    if (record.process.finishedAt !== null) {
      if (
        record.process.exitCodeSource === "reconstructed" ||
        record.process.exitCode !== normalizedExit ||
        (record.process.signal !== null && record.process.signal !== signal)
      ) {
        fail("aborted wave process conflicts with its recorded result");
      }
      record.process.signal = signal;
      record.executionEvidence = buildExecutionEvidence(
        record,
        status.reviewRunId,
      );
      finalizeDecision(status, loaded);
      return status;
    }
    record.process.finishedAt = now();
    record.process.exitCode = normalizedExit;
    record.process.exitCodeSource = "process";
    record.process.signal = signal;
    record.executionEvidence = buildExecutionEvidence(
      record,
      status.reviewRunId,
    );
    if (role === "lead") {
      record.state = "attempt-finished";
    } else if (!TERMINAL_SPECULATIVE_STATES.has(record.state)) {
      record.state = "completed-awaiting-decision";
    }
    finalizeDecision(status, loaded);
    return status;
  });
}

export function recordWavePidHandoffFailure({
  contextPath,
  statusPath,
  role,
  exitCode,
  signal,
  supervisorNonce,
  signalPid,
}) {
  const normalizedExit = Number(exitCode);
  const normalizedSignalPid = Number(signalPid);
  if (
    !new Set(["lead", "speculative"]).has(role) ||
    !Number.isInteger(normalizedExit) ||
    normalizedExit < 0 ||
    !new Set(["TERM", "INT", "HUP"]).has(signal) ||
    typeof supervisorNonce !== "string" ||
    supervisorNonce.length === 0 ||
    !Number.isInteger(normalizedSignalPid) ||
    normalizedSignalPid < 1
  ) {
    fail("wave PID handoff failure identity is invalid");
  }
  return updateWave({ contextPath, statusPath }, (status) => {
    if (
      status.supervisor.nonce !== supervisorNonce ||
      status.termination?.signal !== signal ||
      status.termination?.supervisorNonce !== supervisorNonce
    ) {
      fail("wave PID handoff failure does not match its termination intent");
    }
    const record = status[role];
    if (
      record.state !== "reserved" ||
      record.process.startedAt !== null ||
      existsSync(filesystemPath(record.artifactDir))
    ) {
      fail("wave PID handoff failure requires an unclaimed role");
    }
    const timestamp = now();
    record.process.signalPid = normalizedSignalPid;
    record.process.supervisorNonce = supervisorNonce;
    record.process.nativePidUnavailableReason =
      "native-pid-handoff-failed";
    record.process.startedAt = timestamp;
    record.process.finishedAt = timestamp;
    record.process.exitCode = normalizedExit;
    record.process.exitCodeSource = "process";
    record.process.signal = signal;
    record.executionEvidence = buildExecutionEvidence(
      record,
      status.reviewRunId,
    );
    if (record.executionEvidence.complete !== false) {
      fail("wave PID handoff failure cannot retain complete execution evidence");
    }
    record.state =
      role === "lead" ? "attempt-finished" : "completed-awaiting-decision";
    return status;
  });
}

function readCanonicalAdjudications(phase4Directory, lastRound, reviewRunId) {
  const adjudications = [];
  for (let round = 1; round <= lastRound; round += 1) {
    const adjudication = readJson(
      path.join(phase4Directory, `round-${round}`, "adjudication.json"),
      `round ${round} adjudication`,
    );
    if (
      adjudication.schema !== "deep-review-adjudication/v1" ||
      adjudication.reviewRunId !== reviewRunId ||
      adjudication.phase !== "convergence" ||
      adjudication.round !== round
    ) {
      fail(`round ${round} adjudication identity is invalid`);
    }
    adjudications.push(adjudication);
  }
  return adjudications;
}

function leadHasExhaustedFailure(status) {
  const pairStatus = readPairStatus(status.lead, status.reviewRunId);
  if (pairStatus.complete === true) return false;
  const failedReviewers = ["claude", "codex"].filter(
    (reviewer) => pairStatus.canonical?.[reviewer]?.exitCode !== 0,
  );
  return failedReviewers.length > 0 && failedReviewers.every((reviewer) => {
    const attempts = pairStatus.attempts.filter(
      (attempt) => attempt[reviewer]?.requested === true,
    );
    return attempts.length >= 2;
  });
}

function leadFailedWithoutPairStatus(status) {
  return (
    !pairFinished(status.lead) &&
    status.lead.process.finishedAt !== null &&
    status.lead.process.exitCode !== null &&
    status.lead.process.exitCode !== 0 &&
    status.lead.executionEvidence?.complete === false
  );
}

export function requestWaveDecision({ contextPath, statusPath, action }) {
  if (!new Set(["promote", "converge", "prior-failure"]).has(action)) {
    fail("wave decision must be promote, converge, or prior-failure");
  }
  return updateWave({ contextPath, statusPath }, (status, loaded) => {
    if (status.speculative.process.startedAt === null) {
      fail("wave decision requires every role launch to be claimed");
    }
    if (status.decision !== null) {
      if (status.decision.action !== action) {
        fail("wave decision is already fixed to a different action");
      }
      reconcileRecordFromPairStatus(status, "lead");
      finalizeDecision(status, loaded);
      return status;
    }
    const leadStatusAvailable = pairFinished(status.lead);
    const unrecoverableLeadFailure = leadFailedWithoutPairStatus(status);
    if (
      !leadStatusAvailable &&
      !(action === "prior-failure" && unrecoverableLeadFailure)
    ) {
      fail("lead round has not reached a recoverable terminal state");
    }
    if (leadStatusAvailable) {
      reconcileRecordFromPairStatus(status, "lead");
    }
    const leadStatus = leadStatusAvailable
      ? readPairStatus(status.lead, status.reviewRunId)
      : null;
    const adjudications =
      action === "prior-failure"
        ? []
        : readCanonicalAdjudications(
            loaded.phase4Directory,
            status.firstRound,
            status.reviewRunId,
          );
    const convergenceEndIndex = firstConvergenceEndIndex(adjudications);
    if (action === "converge") {
      if (
        !leadStatus?.complete ||
        convergenceEndIndex !== status.firstRound - 1
      ) {
        fail("lead adjudication does not establish convergence");
      }
    } else if (action === "promote") {
      if (!leadStatus?.complete || convergenceEndIndex >= 0) {
        fail("speculative round cannot be promoted after failure or convergence");
      }
      assertCanStartRound({
        phase4Directory: loaded.phase4Directory,
        reviewRunId: status.reviewRunId,
        nextRound: status.speculativeRound,
      });
    } else if (
      !unrecoverableLeadFailure &&
      !leadHasExhaustedFailure(status)
    ) {
      fail("prior-failure decision requires an exhausted lead reviewer failure");
    }
    status.decision = { action, decidedAt: now(), signal: null };
    status.lead.state = leadStatus?.complete
      ? "canonical-complete"
      : "canonical-failed";
    reconcileRecordFromPairStatus(status, "speculative");
    finalizeDecision(status, loaded);
    return status;
  });
}

export function recordWaveDecisionSignal({
  contextPath,
  statusPath,
  signal,
}) {
  if (!new Set(["TERM", "INT", "HUP"]).has(signal)) {
    fail("wave decision signal must be TERM, INT, or HUP");
  }
  return updateWave({ contextPath, statusPath }, (status) => {
    if (!new Set(["converge", "prior-failure"]).has(status.decision?.action)) {
      fail("wave decision does not permit speculative cancellation");
    }
    if (status.decision.signal !== null) {
      if (status.decision.signal.name !== signal) {
        fail("wave decision signal is already recorded differently");
      }
      return status;
    }
    status.decision.signal = { name: signal, sentAt: now() };
    return status;
  });
}

export function requestWaveTermination({
  contextPath,
  statusPath,
  signal,
  supervisorNonce,
}) {
  if (!new Set(["TERM", "INT", "HUP"]).has(signal)) {
    fail("wave termination signal must be TERM, INT, or HUP");
  }
  return updateWave({ contextPath, statusPath }, (status) => {
    if (status.supervisor.nonce !== supervisorNonce) {
      fail("wave termination belongs to a superseded supervisor");
    }
    if (status.termination !== null) {
      if (
        status.termination.signal !== signal ||
        status.termination.supervisorNonce !== supervisorNonce
      ) {
        fail("wave termination intent is already fixed differently");
      }
      return status;
    }
    status.termination = {
      signal,
      requestedAt: now(),
      supervisorNonce,
    };
    return status;
  });
}

export function wavePairCancellationState({
  contextPath,
  statusPath,
  role,
  supervisorNonce,
  processPid,
}) {
  if (!new Set(["lead", "speculative"]).has(role)) {
    fail("wave role must be lead or speculative");
  }
  const normalizedProcessPid = Number(processPid);
  const { status } = loadWave({ contextPath, statusPath });
  const record = status[role];
  if (
    typeof supervisorNonce !== "string" ||
    supervisorNonce.length === 0 ||
    !Number.isInteger(normalizedProcessPid) ||
    normalizedProcessPid < 1 ||
    record.process.supervisorNonce !== supervisorNonce ||
    record.process.pid !== normalizedProcessPid ||
    record.process.startedAt === null
  ) {
    fail("wave cancellation observer does not match its launch claim");
  }
  if (record.process.finishedAt !== null) {
    return { cancel: false, done: true, signal: null, source: null };
  }
  if (status.termination !== null) {
    return {
      cancel: true,
      done: false,
      signal: status.termination.signal,
      source: "wave-termination",
    };
  }
  if (
    role === "speculative" &&
    new Set(["converge", "prior-failure"]).has(status.decision?.action)
  ) {
    return {
      cancel: true,
      done: false,
      signal: "TERM",
      source: "wave-decision",
    };
  }
  return { cancel: false, done: false, signal: null, source: null };
}

export function waitForWavePairCancellation(options) {
  const sleeper = new Int32Array(new SharedArrayBuffer(4));
  while (true) {
    const state = wavePairCancellationState(options);
    if (state.cancel || state.done) return state;
    Atomics.wait(sleeper, 0, 0, 200);
  }
}

export function speculativeControlState({ contextPath, statusPath }) {
  const { status } = loadWave({ contextPath, statusPath });
  return {
    state: status.speculative.state,
    pid: status.speculative.process.pid,
    finishedAt: status.speculative.process.finishedAt,
    pairFinished: pairFinished(status.speculative),
    terminal: TERMINAL_SPECULATIVE_STATES.has(status.speculative.state),
    decision: status.decision,
  };
}

export function waveRoleState({ contextPath, statusPath, role }) {
  const { status } = loadWave({ contextPath, statusPath });
  if (!new Set(["lead", "speculative"]).has(role)) {
    fail("wave role must be lead or speculative");
  }
  return {
    state: status[role].state,
    process: status[role].process,
  };
}

function validatePromptReceipts(status, context) {
  for (const [role, round] of [
    ["lead", status.firstRound],
    ["speculative", status.speculativeRound],
  ]) {
    for (const reviewer of ["claude", "codex"]) {
      const receipt = status[role].prompts?.[reviewer];
      const actual = verifyPromptManifest({
        context,
        promptPath: receipt?.promptPath,
        reviewer,
        phase: "convergence",
        round,
        purpose: "review",
      });
      if (JSON.stringify(receipt) !== JSON.stringify(actual)) {
        fail("wave prompt receipt no longer matches its manifest");
      }
    }
  }
}

function validatePromotion(status, statusPath) {
  const receiptIdentity = status.speculative.promotion?.path;
  const receiptPath = filesystemPath(receiptIdentity);
  const sourcePath = filesystemPath(status.speculative.artifactDir);
  const receipt = readJson(receiptPath, "wave promotion receipt");
  if (
    receipt.schema !== "deep-review-wave-promotion/v1" ||
    receipt.reviewRunId !== status.reviewRunId ||
    receipt.round !== status.speculativeRound ||
    receipt.sourceArtifactDir !== status.speculative.artifactDir ||
    receipt.canonicalArtifactDir !== status.speculative.canonicalArtifactDir ||
    status.speculative.promotion.sha256 !== sha256(readFileSync(receiptPath)) ||
    receipt.comparableTreeSha256 !==
      comparableTreeDigest(sourcePath, status.speculative.artifactDir) ||
    !sameNativeParentDirectory(receiptPath, filesystemPath(statusPath))
  ) {
    fail("wave promotion receipt is invalid");
  }
  const sourceStatus = readPairStatus(status.speculative, status.reviewRunId);
  const canonicalRecord = {
    ...status.speculative,
    artifactDir: status.speculative.canonicalArtifactDir,
  };
  const canonicalStatus = readPairStatus(canonicalRecord, status.reviewRunId);
  const expectedAttempt = replacePrefix(
    sourceStatus.attempts[0],
    status.speculative.artifactDir,
    status.speculative.canonicalArtifactDir,
  );
  if (
    JSON.stringify(canonicalStatus.attempts[0]) !==
      JSON.stringify(expectedAttempt) ||
    comparableTreeDigest(
      path.join(sourcePath, "attempt-1"),
      status.speculative.artifactDir,
    ) !==
      comparableTreeDigest(
        path.join(
          filesystemPath(status.speculative.canonicalArtifactDir),
          "attempt-1",
        ),
        status.speculative.canonicalArtifactDir,
      )
  ) {
    fail("promoted attempt 1 no longer matches its speculative source");
  }
}

export function inspectReviewWaves({
  context,
  artifactDirectory,
  ignoredPristineStatusPath = null,
}) {
  const artifactReal = assertPlainDirectory(
    artifactDirectory ?? context.reviewArtifactDir,
    "review artifact directory",
  );
  const phase4Real = assertPlainDirectory(
    path.join(artifactReal, "phase4"),
    "Phase 4 directory",
  );
  const executionMode = readPhase4Mode({ context, phase4Real });
  const wavesDirectory = path.join(phase4Real, "waves");
  if (!existsSync(wavesDirectory)) {
    if (executionMode?.mode === "wave") {
      fail("wave execution mode is missing its wave directory");
    }
    return { enabled: false, waves: [], canonicalRounds: [] };
  }
  assertPlainDirectory(wavesDirectory, "Phase 4 waves directory");
  const statuses = [];
  for (const entry of readdirSync(wavesDirectory, { withFileTypes: true })) {
    if (
      /^\.wave-\d+-\d+\.reserving-\d+-[0-9a-f-]+$/u.test(entry.name)
    ) {
      if (!entry.isDirectory() || entry.isSymbolicLink()) {
        fail("wave reservation staging entry is not a plain directory");
      }
      continue;
    }
    if (!entry.isDirectory() || !/^wave-\d+-\d+$/u.test(entry.name)) {
      fail(`unexpected Phase 4 wave entry: ${entry.name}`);
    }
    const statusPath = path.join(wavesDirectory, entry.name, "status.json");
    const status = readJson(statusPath, "wave status");
    validateWaveIdentity(status, context, statusPath, phase4Real);
    validatePromptReceipts(status, context);
    if (ignoredPristineStatusPath === statusPath) {
      assertAttachableReservation(status);
      continue;
    }
    statuses.push({ status, statusPath });
  }
  if (statuses.length === 0) {
    return {
      enabled: executionMode?.mode === "wave",
      waves: [],
      canonicalRounds: [],
    };
  }
  if (executionMode?.mode === "sequential") {
    fail("sequential execution mode contains wave artifacts");
  }
  statuses.sort((left, right) => left.status.firstRound - right.status.firstRound);
  const canonicalRounds = [];
  for (let index = 0; index < statuses.length; index += 1) {
    const { status, statusPath } = statuses[index];
    const expectedFirst = canonicalRounds.length + 1;
    if (status.firstRound !== expectedFirst) {
      fail("wave canonical round sequence is not contiguous");
    }
    if (!TERMINAL_SPECULATIVE_STATES.has(status.speculative.state)) {
      fail("report contains an unfinished speculative wave");
    }
    if (
      [status.lead, status.speculative].some(
        (record) =>
          record.process.exitCodeSource === "reconstructed" &&
          record.process.supervisorNonce === status.supervisor.nonce,
      ) &&
      lockOwnerIsAlive(status.supervisor.pid)
    ) {
      fail("recovered wave process result still has a live supervisor");
    }
    canonicalRounds.push(status.firstRound);
    assertPlainDirectory(status.lead.artifactDir, "wave lead artifact");
    validateExecutionEvidence(status.lead, status.reviewRunId);
    if (
      existsSync(
        path.join(
          filesystemPath(status.speculative.artifactDir),
          "adjudication.json",
        ),
      )
    ) {
      fail("speculative source artifact must never be adjudicated");
    }
    if (status.speculative.state === "promoted") {
      if (status.decision?.action !== "promote") {
        fail("promoted speculative round is missing its decision");
      }
      assertPlainDirectory(
        status.speculative.artifactDir,
        "speculative source artifact",
      );
      assertPlainDirectory(
        status.speculative.canonicalArtifactDir,
        "promoted canonical artifact",
      );
      validatePromotion(status, statusPath);
      canonicalRounds.push(status.speculativeRound);
    } else {
      if (index !== statuses.length - 1) {
        fail("a non-promoted speculative round must terminate the wave sequence");
      }
      if (existsSync(filesystemPath(status.speculative.canonicalArtifactDir))) {
        fail("non-promoted speculative round has a canonical artifact");
      }
      if (
        status.speculative.state === "cancelled-after-convergence" ||
        (status.speculative.state === "completed-but-not-promoted" &&
          status.speculative.nonPromotionReason === "convergence")
      ) {
        const adjudications = readCanonicalAdjudications(
          phase4Real,
          status.firstRound,
          status.reviewRunId,
        );
        if (firstConvergenceEndIndex(adjudications) !== status.firstRound - 1) {
          fail("non-promoted convergence wave does not end at first convergence");
        }
      }
    }
    if (existsSync(filesystemPath(status.speculative.artifactDir))) {
      assertPlainDirectory(
        status.speculative.artifactDir,
        "speculative wave artifact",
      );
    } else if (
      (!status.speculative.state.startsWith("cancelled-") &&
        status.speculative.state !== "aborted-incomplete") ||
      status.speculative.executionEvidence?.complete !== false
    ) {
      fail("speculative wave artifact is missing");
    }
    validateExecutionEvidence(status.speculative, status.reviewRunId);
  }
  return {
    enabled: true,
    waves: statuses,
    canonicalRounds,
  };
}

function parseOptions(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined) {
      fail(`invalid argument: ${flag ?? "<missing>"}`);
    }
    const key = flag
      .slice(2)
      .replace(/-([a-z])/gu, (_, letter) => letter.toUpperCase());
    if (parsed[key] !== undefined) fail(`duplicate argument: ${flag}`);
    parsed[key] = value;
  }
  return parsed;
}

function requireOptions(parsed, names) {
  for (const name of names) {
    if (!parsed[name]) fail(`missing required argument: --${name}`);
  }
}

function main(argv) {
  const command = argv[0];
  const options = parseOptions(argv.slice(1));
  if (command === "reserve") {
    requireOptions(options, [
      "context",
      "firstRound",
      "supervisorPid",
      "claudeLeadPrompt",
      "codexLeadPrompt",
      "claudeSpeculativePrompt",
      "codexSpeculativePrompt",
    ]);
    return reserveWave({ contextPath: options.context, ...options });
  }
  if (command === "claim-sequential") {
    requireOptions(options, ["context"]);
    return claimSequentialPhase4({ contextPath: options.context });
  }
  if (command === "authorize-sequential") {
    requireOptions(options, ["context", "round"]);
    return authorizeSequentialPhase4({
      contextPath: options.context,
      round: options.round,
    });
  }
  if (command === "authorize") {
    requireOptions(options, [
      "context",
      "status",
      "role",
      "round",
      "attempt",
      "reviewer",
    ]);
    return authorizeWavePair({
      contextPath: options.context,
      statusPath: options.status,
      ...options,
    });
  }
  if (command === "record-start") {
    requireOptions(options, ["context", "status", "role", "pid"]);
    return recordWaveProcessStart({
      contextPath: options.context,
      statusPath: options.status,
      ...options,
    });
  }
  if (command === "authorize-reviewers") {
    requireOptions(options, [
      "context",
      "status",
      "role",
      "supervisorNonce",
      "processPid",
    ]);
    return authorizeWaveReviewerLaunch({
      contextPath: options.context,
      statusPath: options.status,
      role: options.role,
      supervisorNonce: options.supervisorNonce,
      processPid: options.processPid,
    });
  }
  if (command === "expire-reviewer-authorization") {
    requireOptions(options, [
      "context",
      "status",
      "role",
      "supervisorNonce",
      "processPid",
      "activeSupervisorNonce",
    ]);
    return expireWaveReviewerAuthorization({
      contextPath: options.context,
      statusPath: options.status,
      role: options.role,
      supervisorNonce: options.supervisorNonce,
      processPid: options.processPid,
      activeSupervisorNonce: options.activeSupervisorNonce,
    });
  }
  if (command === "mark-reviewers-ready") {
    requireOptions(options, [
      "context",
      "status",
      "supervisorNonce",
    ]);
    return markWaveReviewersReady({
      contextPath: options.context,
      statusPath: options.status,
      supervisorNonce: options.supervisorNonce,
    });
  }
  if (command === "record-result") {
    requireOptions(options, ["context", "status", "role", "exitCode"]);
    return recordWaveProcessResult({
      contextPath: options.context,
      statusPath: options.status,
      ...options,
    });
  }
  if (command === "abort-unclaimed") {
    requireOptions(options, [
      "context",
      "status",
      "role",
      "exitCode",
      "signal",
      "supervisorNonce",
      "processPid",
      "signalPid",
    ]);
    return abortUnclaimedWaveProcess({
      contextPath: options.context,
      statusPath: options.status,
      ...options,
    });
  }
  if (command === "record-handoff-failure") {
    requireOptions(options, [
      "context",
      "status",
      "role",
      "exitCode",
      "signal",
      "supervisorNonce",
      "signalPid",
    ]);
    return recordWavePidHandoffFailure({
      contextPath: options.context,
      statusPath: options.status,
      ...options,
    });
  }
  if (command === "recover-role") {
    requireOptions(options, [
      "context",
      "status",
      "role",
      "supervisorNonce",
    ]);
    return recoverAttachedWaveProcess({
      contextPath: options.context,
      statusPath: options.status,
      ...options,
    });
  }
  if (command === "decide") {
    requireOptions(options, ["context", "status", "action"]);
    return requestWaveDecision({
      contextPath: options.context,
      statusPath: options.status,
      action: options.action,
    });
  }
  if (command === "record-signal") {
    requireOptions(options, ["context", "status", "signal"]);
    return recordWaveDecisionSignal({
      contextPath: options.context,
      statusPath: options.status,
      signal: options.signal,
    });
  }
  if (command === "request-termination") {
    requireOptions(options, [
      "context",
      "status",
      "signal",
      "supervisorNonce",
    ]);
    return requestWaveTermination({
      contextPath: options.context,
      statusPath: options.status,
      signal: options.signal,
      supervisorNonce: options.supervisorNonce,
    });
  }
  if (command === "cancellation-state") {
    requireOptions(options, [
      "context",
      "status",
      "role",
      "supervisorNonce",
      "processPid",
    ]);
    return wavePairCancellationState({
      contextPath: options.context,
      statusPath: options.status,
      role: options.role,
      supervisorNonce: options.supervisorNonce,
      processPid: options.processPid,
    });
  }
  if (command === "wait-cancellation") {
    requireOptions(options, [
      "context",
      "status",
      "role",
      "supervisorNonce",
      "processPid",
    ]);
    return waitForWavePairCancellation({
      contextPath: options.context,
      statusPath: options.status,
      role: options.role,
      supervisorNonce: options.supervisorNonce,
      processPid: options.processPid,
    });
  }
  if (command === "control-state") {
    requireOptions(options, ["context", "status"]);
    return speculativeControlState({
      contextPath: options.context,
      statusPath: options.status,
    });
  }
  if (command === "role-state") {
    requireOptions(options, ["context", "status", "role"]);
    return waveRoleState({
      contextPath: options.context,
      statusPath: options.status,
      role: options.role,
    });
  }
  fail("unknown review wave command");
}

const invokedPath = process.argv[1];
if (
  invokedPath &&
  import.meta.url === pathToFileURL(path.resolve(invokedPath)).href
) {
  try {
    const result = main(process.argv.slice(2));
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
