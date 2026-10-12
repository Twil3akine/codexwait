#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PROMPT='Resume the previous work. First inspect the current git status and existing artifacts. Do not repeat completed work; continue from the unfinished part.'
DEFAULT_LIMIT_REGEX='usage limit|rate limit|quota exceeded|too many requests|limit reached|try again after|reset at|reset.*[0-9]'
DEFAULT_ACTIVE_WRITER_REGEX='already has an active writer|thread-store conflict'

interval="${CODEXWAIT_INTERVAL:-600}"
prompt="${CODEXWAIT_PROMPT:-$DEFAULT_PROMPT}"
limit_regex="${CODEXWAIT_LIMIT_REGEX:-$DEFAULT_LIMIT_REGEX}"
active_writer_regex="${CODEXWAIT_ACTIVE_WRITER_REGEX:-$DEFAULT_ACTIVE_WRITER_REGEX}"
max_attempts="${CODEXWAIT_MAX_ATTEMPTS:-0}"
keep_awake=0
use_last=0
session=""
cwd_override="${CODEXWAIT_CWD:-}"

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
  -C, --cwd DIR         Override the working directory used to resume.
  --keep-awake           On macOS, use caffeinate while codexwait is running.
  -h, --help             Show this help.

Environment:
  CODEX_HOME                    Codex data directory (default: ~/.codex).
  CODEXWAIT_INTERVAL            Default retry interval.
  CODEXWAIT_PROMPT              Default resume prompt.
  CODEXWAIT_LIMIT_REGEX         Regex used to recognize usage/rate-limit failures.
  CODEXWAIT_ACTIVE_WRITER_REGEX Regex used to recognize Codex active-writer conflicts.
  CODEXWAIT_MAX_ATTEMPTS        Default maximum attempts (0 = unlimited).
  CODEXWAIT_CWD                 Override the resume working directory.
  CODEXWAIT_LOCK_DIR            Override reservation-lock directory.
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
    -C|--cwd)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      cwd_override="$2"
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

shortest_unique_prefix() {
  local candidate="$1"
  shift
  local -a candidates=("$@")
  local length prefix other count

  for ((length = 8; length <= ${#candidate}; length++)); do
    prefix="${candidate:0:length}"
    count=0
    for other in "${candidates[@]}"; do
      if [[ "${other,,}" == "${prefix,,}"* ]]; then
        count=$((count + 1))
      fi
    done
    if (( count == 1 )); then
      printf '%s\n' "$prefix"
      return 0
    fi
  done

  printf '%s\n' "$candidate"
}

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
      local match suggestion
      for match in "${matches[@]}"; do
        suggestion="$(shortest_unique_prefix "$match" "${matches[@]}")"
        printf '  %s  (try: %s)\n' "$match" "$suggestion" >&2
      done
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

find_rollout_for_uuid() {
  local uuid="$1"
  local sessions_dir="$codex_home/sessions"
  local best='' file

  [[ -d "$sessions_dir" ]] || return 1

  while IFS= read -r -d '' file; do
    # Prefer the earliest rollout path for this UUID. A later resume attempt can
    # record a different turn cwd, but the creation-time session_meta is the
    # stable project directory we want for unattended resume.
    if [[ -z "$best" || "$file" < "$best" ]]; then
      best="$file"
    fi
  done < <(find "$sessions_dir" -type f -name "rollout-*-$uuid.jsonl" -print0 2>/dev/null)

  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

read_recorded_cwd() {
  local rollout="$1"
  local recorded

  command -v jq >/dev/null 2>&1 || fail "jq is required to read the recorded session cwd; install jq or pass --cwd DIR"

  recorded="$(
    jq -r '
      select(.type == "session_meta")
      | (.payload.meta.cwd // .payload.cwd // empty)
    ' "$rollout" 2>/dev/null | head -n 1
  )"

  [[ -n "$recorded" && "$recorded" != "null" ]] || return 1
  printf '%s\n' "$recorded"
}

normalize_cwd() {
  local value="$1"
  [[ -d "$value" ]] || fail "working directory does not exist: $value"
  (cd "$value" && pwd -P)
}

resume_cwd=''
if [[ -n "$cwd_override" ]]; then
  resume_cwd="$(normalize_cwd "$cwd_override")"
elif (( use_last )); then
  fail "--last requires --cwd DIR so codexwait does not resume the selected session from the wrong repository"
elif [[ "$session" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  rollout_file="$(find_rollout_for_uuid "$session" || true)"
  [[ -n "$rollout_file" ]] || fail "cannot find rollout metadata for session $session; pass --cwd DIR"
  recorded_cwd="$(read_recorded_cwd "$rollout_file" || true)"
  [[ -n "$recorded_cwd" ]] || fail "cannot determine the recorded cwd for session $session; pass --cwd DIR"
  [[ -d "$recorded_cwd" ]] || fail "recorded session cwd no longer exists: $recorded_cwd (use --cwd DIR to override)"
  resume_cwd="$(normalize_cwd "$recorded_cwd")"
else
  fail "named sessions require --cwd DIR because codexwait cannot safely map the name to rollout metadata"
fi

echo "Session cwd: $resume_cwd"
if [[ "$(pwd -P)" != "$resume_cwd" ]]; then
  echo "Current cwd: $(pwd -P)"
  echo "Resuming from session cwd."
fi

if [[ -n "${CODEXWAIT_LOCK_DIR:-}" ]]; then
  lock_root="$CODEXWAIT_LOCK_DIR"
elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  lock_root="$XDG_RUNTIME_DIR/codexwait"
else
  lock_root="${TMPDIR:-/tmp}/codexwait-${UID:-$(id -u)}"
fi
mkdir -p "$lock_root"
chmod 700 "$lock_root" 2>/dev/null || true

lock_target="$session"
if (( use_last )); then
  # --last cannot be mapped to a stable session UUID before Codex resolves it,
  # so reserve a singleton --last slot. Explicit session reservations remain separate.
  lock_target='__last__'
fi

lock_checksum="$(printf '%s' "$lock_target" | cksum)"
read -r lock_sum lock_bytes _ <<< "$lock_checksum"
lock_dir="$lock_root/${lock_sum}-${lock_bytes}.lock"
lock_owned=0
caffeinate_pid=""
tmp=""

cleanup() {
  if [[ -n "$caffeinate_pid" ]]; then
    kill "$caffeinate_pid" 2>/dev/null || true
    wait "$caffeinate_pid" 2>/dev/null || true
  fi
  [[ -z "$tmp" ]] || rm -f "$tmp"
  if (( lock_owned )); then
    rm -rf "$lock_dir"
  fi
}
trap cleanup EXIT INT TERM

write_lock_metadata() {
  printf '%s\n' "$$" > "$lock_dir/pid"
  printf '%s\n' "$lock_target" > "$lock_dir/session"
  printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$lock_dir/started_at"
  pwd > "$lock_dir/cwd"
  printf '%s\n' "$resume_cwd" > "$lock_dir/target_cwd"
}

report_existing_lock() {
  local owner_pid='unknown' owner_started='unknown' owner_cwd='unknown' owner_target_cwd='unknown'
  [[ ! -r "$lock_dir/pid" ]] || owner_pid="$(cat "$lock_dir/pid")"
  [[ ! -r "$lock_dir/started_at" ]] || owner_started="$(cat "$lock_dir/started_at")"
  [[ ! -r "$lock_dir/cwd" ]] || owner_cwd="$(cat "$lock_dir/cwd")"
  [[ ! -r "$lock_dir/target_cwd" ]] || owner_target_cwd="$(cat "$lock_dir/target_cwd")"

  cat >&2 <<EOF_LOCK
codexwait: this session is already reserved by another codexwait process.

session: $lock_target
pid:     $owner_pid
since:   $owner_started
cwd:     $owner_cwd
target:  $owner_target_cwd
EOF_LOCK
}

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    lock_owned=1
    write_lock_metadata
    return 0
  fi

  local owner_pid=''
  [[ ! -r "$lock_dir/pid" ]] || owner_pid="$(cat "$lock_dir/pid")"

  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    report_existing_lock
    return 1
  fi

  # Dead/missing owner: treat as stale and replace once.
  rm -rf "$lock_dir"
  if mkdir "$lock_dir" 2>/dev/null; then
    lock_owned=1
    write_lock_metadata
    return 0
  fi

  report_existing_lock
  return 1
}

acquire_lock || exit 2

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
    (cd "$resume_cwd" && codex exec resume --last "$prompt") 2>&1 | tee "$tmp"
  else
    (cd "$resume_cwd" && codex exec resume "$session" "$prompt") 2>&1 | tee "$tmp"
  fi
  status=${PIPESTATUS[0]}
  set -e

  if (( status == 0 )); then
    printf '[%s] Codex exited successfully.\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    exit 0
  fi

  if grep -Eiq "$active_writer_regex" "$tmp"; then
    cat >&2 <<'EOF_WRITER'
codexwait: this Codex session is already open elsewhere.
Close the existing Codex session, then run codexwait again.
EOF_WRITER
    exit "$status"
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
