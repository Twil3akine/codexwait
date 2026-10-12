#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PROMPT='Resume the previous work. First inspect the current git status and existing artifacts. Do not repeat completed work; continue from the unfinished part.'
DEFAULT_LIMIT_REGEX='usage limit|rate limit|quota exceeded|too many requests|limit reached|try again after|reset at|reset.*[0-9]'

interval="${CODEXWAIT_INTERVAL:-600}"
prompt="${CODEXWAIT_PROMPT:-$DEFAULT_PROMPT}"
limit_regex="${CODEXWAIT_LIMIT_REGEX:-$DEFAULT_LIMIT_REGEX}"
max_attempts="${CODEXWAIT_MAX_ATTEMPTS:-0}"
keep_awake=0
use_last=0
session=""

usage() {
  cat <<'USAGE'
Usage:
  codexwait [OPTIONS] [SESSION]

SESSION may be:
  - a full Codex session UUID
  - a unique UUID prefix (8+ hexadecimal characters, hyphens optional)
  - a Codex session name

Options:
  --last                 Resume the most recent session.
  -i, --interval SEC     Retry interval in seconds (default: 600).
  -p, --prompt TEXT      Prompt appended when resuming.
  --max-attempts N       Stop after N attempts (0 = unlimited, default).
  --keep-awake           On macOS, use caffeinate while codexwait is running.
  -h, --help             Show this help.

Environment:
  CODEX_HOME             Codex data directory (default: ~/.codex).
  CODEXWAIT_INTERVAL     Default retry interval.
  CODEXWAIT_PROMPT       Default resume prompt.
  CODEXWAIT_LIMIT_REGEX  Regex used to recognize usage/rate-limit failures.
  CODEXWAIT_MAX_ATTEMPTS Default maximum attempts (0 = unlimited).
USAGE
}

fail() {
  echo "codexwait: $*" >&2
  exit 2
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)
      use_last=1
      shift
      ;;
    -i|--interval)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      interval="$2"
      shift 2
      ;;
    -p|--prompt)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      prompt="$2"
      shift 2
      ;;
    --max-attempts)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      max_attempts="$2"
      shift 2
      ;;
    --keep-awake)
      keep_awake=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      [[ $# -le 1 ]] || fail "too many positional arguments"
      [[ $# -eq 0 ]] || session="$1"
      break
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$session" ]] || fail "only one SESSION may be specified"
      session="$1"
      shift
      ;;
  esac
done

is_uint "$interval" || fail "interval must be a non-negative integer"
(( interval > 0 )) || fail "interval must be greater than zero"
is_uint "$max_attempts" || fail "max-attempts must be a non-negative integer"

if (( use_last )) && [[ -n "$session" ]]; then
  fail "--last and SESSION cannot be used together"
fi

command -v codex >/dev/null 2>&1 || {
  echo "codexwait: codex command not found" >&2
  exit 127
}

codex_home="${CODEX_HOME:-$HOME/.codex}"

resolve_session() {
  local value="$1"
  local compact
  compact="$(printf '%s' "$value" | tr -d '-')"

  # Full UUID: pass through unchanged.
  if [[ "$value" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  # Only treat 8+ hex chars as a UUID prefix. Other values are session names.
  if [[ ! "$compact" =~ ^[0-9A-Fa-f]{8,31}$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  local sessions_dir="$codex_home/sessions"
  [[ -d "$sessions_dir" ]] || fail "cannot resolve UUID prefix: $sessions_dir does not exist"

  local -a matches=()
  local file base uuid uuid_compact
  while IFS= read -r -d '' file; do
    base="${file##*/}"
    if [[ "$base" =~ ([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}) ]]; then
      uuid="${BASH_REMATCH[1]}"
      uuid_compact="${uuid//-/}"
      if [[ "${uuid_compact,,}" == "${compact,,}"* ]]; then
        matches+=("$uuid")
      fi
    fi
  done < <(find "$sessions_dir" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)

  # Deduplicate IDs, because a session can have more than one rollout file.
  if ((${#matches[@]} > 0)); then
    mapfile -t matches < <(printf '%s\n' "${matches[@]}" | sort -u)
  fi

  case "${#matches[@]}" in
    0)
      fail "no session matches UUID prefix '$value'"
      ;;
    1)
      printf '%s\n' "${matches[0]}"
      ;;
    *)
      echo "codexwait: session prefix '$value' is ambiguous:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      exit 2
      ;;
  esac
}

if [[ -n "$session" ]]; then
  session="$(resolve_session "$session")"
  echo "Resolved session: $session"
elif (( ! use_last )); then
  fail "specify SESSION or --last"
fi

caffeinate_pid=""
cleanup() {
  if [[ -n "$caffeinate_pid" ]]; then
    kill "$caffeinate_pid" 2>/dev/null || true
    wait "$caffeinate_pid" 2>/dev/null || true
  fi
  [[ -z "${tmp:-}" ]] || rm -f "$tmp"
}
trap cleanup EXIT INT TERM

if (( keep_awake )); then
  if [[ "$(uname -s)" == "Darwin" ]] && command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -w $$ &
    caffeinate_pid=$!
  else
    echo "codexwait: --keep-awake requested, but caffeinate is unavailable; continuing" >&2
  fi
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/codexwait.XXXXXX")"
attempt=0

while :; do
  attempt=$((attempt + 1))
  : > "$tmp"
  printf '[%s] attempt %d: resuming Codex\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$attempt"

  set +e
  if (( use_last )); then
    codex exec resume --last "$prompt" 2>&1 | tee "$tmp"
  else
    codex exec resume "$session" "$prompt" 2>&1 | tee "$tmp"
  fi
  status=${PIPESTATUS[0]}
  set -e

  if (( status == 0 )); then
    printf '[%s] Codex exited successfully.\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    exit 0
  fi

  if ! grep -Eiq "$limit_regex" "$tmp"; then
    printf '[%s] non-limit failure (exit %d); stopping.\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$status" >&2
    exit "$status"
  fi

  if (( max_attempts > 0 && attempt >= max_attempts )); then
    printf '[%s] reached max attempts (%d); stopping.\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$max_attempts" >&2
    exit "$status"
  fi

  printf '[%s] usage/rate limit detected; retrying in %ds.\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$interval"
  sleep "$interval"
done
