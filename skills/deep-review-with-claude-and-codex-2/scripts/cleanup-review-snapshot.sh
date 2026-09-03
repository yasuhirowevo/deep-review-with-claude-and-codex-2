#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  cleanup-review-snapshot.sh [--temp-root <path>] <snapshot-path>
  cleanup-review-snapshot.sh [--temp-root <path>] --stale

Deletes only snapshots created by build-review-snapshot.mjs for the current user.
USAGE
}

TEMP_ROOT_INPUT=""
if [[ "${1:-}" == "--temp-root" ]]; then
  if [[ -z "${2:-}" ]]; then
    usage >&2
    exit 2
  fi
  TEMP_ROOT_INPUT="$2"
  shift 2
fi

TMP_ROOT="$(node -e '
const fs = require("node:fs");
const os = require("node:os");
function toBashAbsolutePath(filePath) {
  if (process.platform !== "win32") return filePath;
  const normalized = filePath.replaceAll("\\", "/");
  const match = /^([A-Za-z]):(\/.*)?$/.exec(normalized);
  return match ? `/${match[1].toLowerCase()}${match[2] || "/"}` : normalized;
}
process.stdout.write(
  toBashAbsolutePath(fs.realpathSync(process.argv[1] || os.tmpdir())),
);
' "${TEMP_ROOT_INPUT}")"

cleanup_one() {
  local candidate="$1"
  if [[ ! -d "${candidate}" || -L "${candidate}" || ! -O "${candidate}" ]]; then
    printf 'ERROR: refusing unsafe snapshot path: %s\n' "${candidate}" >&2
    return 1
  fi

  local resolved
  resolved="$(node -e '
const fs = require("node:fs");
function toBashAbsolutePath(filePath) {
  if (process.platform !== "win32") return filePath;
  const normalized = filePath.replaceAll("\\", "/");
  const match = /^([A-Za-z]):(\/.*)?$/.exec(normalized);
  return match ? `/${match[1].toLowerCase()}${match[2] || "/"}` : normalized;
}
process.stdout.write(toBashAbsolutePath(fs.realpathSync(process.argv[1])));
' "${candidate}")"
  case "${resolved}" in
    "${TMP_ROOT}"/deep-review-head.*) ;;
    *)
      printf 'ERROR: snapshot is outside the managed temp root: %s\n' "${resolved}" >&2
      return 1
      ;;
  esac

  local metadata="${resolved}.metadata.json"
  if [[ ! -f "${metadata}" || -L "${metadata}" || ! -O "${metadata}" ]]; then
    printf 'ERROR: managed snapshot metadata is missing or unsafe: %s\n' "${resolved}" >&2
    return 1
  fi
  if find "${resolved}" -type l -print -quit | grep -q .; then
    printf 'ERROR: refusing snapshot containing a live symlink: %s\n' "${resolved}" >&2
    return 1
  fi
  node -e '
const fs = require("node:fs");
const metadata = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (metadata.creator !== "deep-review-with-claude-and-codex") {
  throw new Error("unexpected snapshot creator");
}
if (metadata.state !== "building" && metadata.state !== "complete") {
  throw new Error("unexpected snapshot state");
}
if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) {
  throw new Error("snapshot owner does not match current user");
}
' "${metadata}"

  chmod -R u+w "${resolved}"
  rm -rf -- "${resolved}"
  chmod u+w "${metadata}"
  rm -f -- "${metadata}"
}

if [[ $# -eq 1 && "$1" == "--stale" ]]; then
  while IFS= read -r -d '' candidate; do
    if ! cleanup_one "${candidate}"; then
      printf 'WARNING: skipped unsafe stale snapshot: %s\n' "${candidate}" >&2
    fi
  done < <(node -e '
const fs = require("node:fs");
const path = require("node:path");
const tempRoot = process.argv[1];
const cutoff = Date.now() - 24 * 60 * 60 * 1000;
function toBashAbsolutePath(filePath) {
  if (process.platform !== "win32") return filePath;
  const normalized = filePath.replaceAll("\\", "/");
  const match = /^([A-Za-z]):(\/.*)?$/.exec(normalized);
  return match ? `/${match[1].toLowerCase()}${match[2] || "/"}` : normalized;
}
for (const entry of fs.readdirSync(tempRoot)) {
  if (!entry.startsWith("deep-review-head.")) continue;
  const candidate = path.join(tempRoot, entry);
  let stat;
  try {
    stat = fs.lstatSync(candidate);
  } catch {
    continue;
  }
  if (stat.isDirectory() && !stat.isSymbolicLink() && stat.mtimeMs < cutoff) {
    process.stdout.write(`${toBashAbsolutePath(candidate)}\0`);
  }
}
' "${TMP_ROOT}")
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi
cleanup_one "$1"
