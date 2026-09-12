#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE_EXPLICIT="${DEEP_REVIEW_CONFIG_FILE:-}"
if [ -n "$CONFIG_FILE_EXPLICIT" ]; then
  CONFIG_FILE="$CONFIG_FILE_EXPLICIT"
elif [ -n "${HOME:-}" ]; then
  CONFIG_FILE="$HOME/.config/deep-review-with-claude-and-codex/reviewer.env"
else
  CONFIG_FILE=""
fi

FILE_CLAUDE_REVIEW_MODEL=""
FILE_CLAUDE_REVIEW_EFFORT=""
FILE_CODEX_REVIEW_MODEL=""
FILE_CODEX_REVIEW_REASONING_EFFORT=""
FILE_CLAUDE_REVIEW_ENABLED=""
FILE_CODEX_REVIEW_ENABLED=""
SEEN_CLAUDE_REVIEW_MODEL=0
SEEN_CLAUDE_REVIEW_EFFORT=0
SEEN_CODEX_REVIEW_MODEL=0
SEEN_CODEX_REVIEW_REASONING_EFFORT=0
SEEN_CLAUDE_REVIEW_ENABLED=0
SEEN_CODEX_REVIEW_ENABLED=0

fail() {
  printf 'ERROR: reviewer config: %s\n' "$1" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_value() {
  local key="$1"
  local value="$2"
  case "$value" in
    "") fail "$key must be nonempty" ;;
    *[[:space:]]*) fail "$key must not contain whitespace" ;;
  esac
  case "$key" in
    CLAUDE_REVIEW_ENABLED|CODEX_REVIEW_ENABLED)
      case "$value" in
        true|false) ;;
        *) fail "$key must be true or false" ;;
      esac
      ;;
  esac
}

set_file_value() {
  local key="$1"
  local value="$2"
  validate_value "$key" "$value"
  case "$key" in
    CLAUDE_REVIEW_ENABLED)
      [ "$SEEN_CLAUDE_REVIEW_ENABLED" -eq 0 ] || fail "duplicate key: $key"
      FILE_CLAUDE_REVIEW_ENABLED="$value"
      SEEN_CLAUDE_REVIEW_ENABLED=1
      ;;
    CODEX_REVIEW_ENABLED)
      [ "$SEEN_CODEX_REVIEW_ENABLED" -eq 0 ] || fail "duplicate key: $key"
      FILE_CODEX_REVIEW_ENABLED="$value"
      SEEN_CODEX_REVIEW_ENABLED=1
      ;;
    CLAUDE_REVIEW_MODEL)
      [ "$SEEN_CLAUDE_REVIEW_MODEL" -eq 0 ] || fail "duplicate key: $key"
      FILE_CLAUDE_REVIEW_MODEL="$value"
      SEEN_CLAUDE_REVIEW_MODEL=1
      ;;
    CLAUDE_REVIEW_EFFORT)
      [ "$SEEN_CLAUDE_REVIEW_EFFORT" -eq 0 ] || fail "duplicate key: $key"
      FILE_CLAUDE_REVIEW_EFFORT="$value"
      SEEN_CLAUDE_REVIEW_EFFORT=1
      ;;
    CODEX_REVIEW_MODEL)
      [ "$SEEN_CODEX_REVIEW_MODEL" -eq 0 ] || fail "duplicate key: $key"
      FILE_CODEX_REVIEW_MODEL="$value"
      SEEN_CODEX_REVIEW_MODEL=1
      ;;
    CODEX_REVIEW_REASONING_EFFORT)
      [ "$SEEN_CODEX_REVIEW_REASONING_EFFORT" -eq 0 ] || fail "duplicate key: $key"
      FILE_CODEX_REVIEW_REASONING_EFFORT="$value"
      SEEN_CODEX_REVIEW_REASONING_EFFORT=1
      ;;
    *) fail "unsupported key: $key" ;;
  esac
}

if [ -n "$CONFIG_FILE" ] && [ -e "$CONFIG_FILE" ]; then
  [ -f "$CONFIG_FILE" ] || fail "config path is not a regular file: $CONFIG_FILE"
  [ -r "$CONFIG_FILE" ] || fail "config file is not readable: $CONFIG_FILE"
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line="${raw_line%$'\r'}"
    line=$(trim "$line")
    case "$line" in
      ""|\#*) continue ;;
    esac
    case "$line" in
      export[[:space:]]*) line=$(trim "${line#export}") ;;
    esac
    case "$line" in
      *=*)
        key=$(trim "${line%%=*}")
        value=$(trim "${line#*=}")
        ;;
      *) fail "expected KEY=VALUE: $line" ;;
    esac
    case "$key" in
      ""|*[!A-Z0-9_]*) fail "invalid key: $key" ;;
    esac
    set_file_value "$key" "$value"
  done < "$CONFIG_FILE"
elif [ -n "$CONFIG_FILE_EXPLICIT" ]; then
  fail "explicit config file does not exist: $CONFIG_FILE_EXPLICIT"
fi

resolve_enabled() {
  local key="$1"
  local file_key="FILE_$1"
  local resolved source
  if [ -n "${!key:-}" ]; then
    resolved="${!key}"
    source="environment"
  elif [ -n "${!file_key}" ]; then
    resolved="${!file_key}"
    source="config-file"
  else
    resolved=true
    source="default"
  fi
  validate_value "$key" "$resolved"
  printf -v "${key}_RESOLVED" '%s' "$resolved"
  printf -v "${key}_SOURCE" '%s' "$source"
}

resolve_value() {
  local key="$1"
  local enabled="$2"
  local file_key="FILE_$1"
  local resolved="" source=""
  if [ -n "${!key:-}" ]; then
    resolved="${!key}"
    source="environment"
  elif [ -n "${!file_key}" ]; then
    resolved="${!file_key}"
    source="config-file"
  elif [ "$enabled" = true ]; then
    fail "$key is not configured"
  fi
  if [ -n "$resolved" ]; then validate_value "$key" "$resolved"; fi
  printf -v "${key}_RESOLVED" '%s' "$resolved"
  printf -v "${key}_SOURCE" '%s' "$source"
}

resolve_enabled CLAUDE_REVIEW_ENABLED
resolve_enabled CODEX_REVIEW_ENABLED
if [ "$CLAUDE_REVIEW_ENABLED_RESOLVED" = false ] && [ "$CODEX_REVIEW_ENABLED_RESOLVED" = false ]; then
  fail "at least one reviewer must be enabled"
fi
resolve_value CLAUDE_REVIEW_MODEL "$CLAUDE_REVIEW_ENABLED_RESOLVED"
resolve_value CLAUDE_REVIEW_EFFORT "$CLAUDE_REVIEW_ENABLED_RESOLVED"
resolve_value CODEX_REVIEW_MODEL "$CODEX_REVIEW_ENABLED_RESOLVED"
resolve_value CODEX_REVIEW_REASONING_EFFORT "$CODEX_REVIEW_ENABLED_RESOLVED"

jq -n \
  --argjson claudeEnabled "$CLAUDE_REVIEW_ENABLED_RESOLVED" \
  --argjson codexEnabled "$CODEX_REVIEW_ENABLED_RESOLVED" \
  --arg claudeModel "$CLAUDE_REVIEW_MODEL_RESOLVED" \
  --arg claudeEffort "$CLAUDE_REVIEW_EFFORT_RESOLVED" \
  --arg codexModel "$CODEX_REVIEW_MODEL_RESOLVED" \
  --arg codexEffort "$CODEX_REVIEW_REASONING_EFFORT_RESOLVED" \
  --arg claudeEnabledSource "$CLAUDE_REVIEW_ENABLED_SOURCE" \
  --arg codexEnabledSource "$CODEX_REVIEW_ENABLED_SOURCE" \
  --arg claudeModelSource "$CLAUDE_REVIEW_MODEL_SOURCE" \
  --arg claudeEffortSource "$CLAUDE_REVIEW_EFFORT_SOURCE" \
  --arg codexModelSource "$CODEX_REVIEW_MODEL_SOURCE" \
  --arg codexEffortSource "$CODEX_REVIEW_REASONING_EFFORT_SOURCE" \
  'def optional: if . == "" then null else . end;
    {reviewerConfig:{
      claude:{enabled:$claudeEnabled,model:($claudeModel|optional),effort:($claudeEffort|optional)},
      codex:{enabled:$codexEnabled,model:($codexModel|optional),reasoningEffort:($codexEffort|optional)}
    },reviewerConfigSources:{
      claude:{enabled:$claudeEnabledSource,model:($claudeModelSource|optional),effort:($claudeEffortSource|optional)},
      codex:{enabled:$codexEnabledSource,model:($codexModelSource|optional),reasoningEffort:($codexEffortSource|optional)}
    }}'
