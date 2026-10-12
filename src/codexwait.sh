#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PROMPT='Resume the previous work. First inspect the current git status and existing artifacts. Do not repeat completed work; continue from the unfinished part.'
DEFAULT_LIMIT_REGEX='usage limit|rate limit|quota exceeded|too many requests|limit reached|try again (after|at)|reset at|reset.*[0-9]'
DEFAULT_ACTIVE_WRITER_REGEX='already has an active writer|thread-store conflict'

interval="${CODEXWAIT_INTERVAL:-600}"
reset_delay="${CODEXWAIT_RESET_DELAY:-10}"
prompt="${CODEXWAIT_PROMPT:-$DEFAULT_PROMPT}"
limit_regex="${CODEXWAIT_LIMIT_REGEX:-$DEFAULT_LIMIT_REGEX}"
active_writer_regex="${CODEXWAIT_ACTIVE_WRITER_REGEX:-$DEFAULT_ACTIVE_WRITER_REGEX}"
max_attempts="${CODEXWAIT_MAX_ATTEMPTS:-0}"
keep_awake=0
use_last=0
list_mode=0
list_limit=10
session=""
cwd_override="${CODEXWAIT_CWD:-}"

usage() {
  cat <<'USAGE'
Usage:
  codexwait [OPTIONS] [SESSION]
  codexwait list [--limit N]

SESSION may be:
  - a full Codex session UUID
  - a unique UUID prefix (8+ hexadecimal characters, hyphens optional)
  - a Codex session name

Commands:
  list                   Show recent Codex sessions grouped by working directory.

Options:
  --last                 Resume the most recent session.
  -i, --interval SEC     Fallback retry interval in seconds (default: 600).
  -p, --prompt TEXT      Prompt appended when resuming.
  --max-attempts N       Stop after N attempts (0 = unlimited, default).
  -C, --cwd DIR          Override the working directory used to resume.
  --keep-awake           On macOS, use caffeinate while codexwait is running.
  -h, --help             Show this help.

Environment:
  CODEX_HOME                    Codex data directory (default: ~/.codex).
  CODEXWAIT_INTERVAL            Fallback retry interval.
  CODEXWAIT_RESET_DELAY         Safety delay after a reported reset time (default: 10).
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

if [[ "${1:-}" == "list" ]]; then
  list_mode=1
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--limit)
        [[ $# -ge 2 ]] || fail "$1 requires a value"
        list_limit="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown list option: $1"
        ;;
    esac
  done
else
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
fi

is_uint "$interval" || fail "interval must be a non-negative integer"
(( interval > 0 )) || fail "interval must be greater than zero"
is_uint "$reset_delay" || fail "reset delay must be a non-negative integer"
is_uint "$max_attempts" || fail "max-attempts must be a non-negative integer"
is_uint "$list_limit" || fail "list limit must be a positive integer"
(( list_limit > 0 )) || fail "list limit must be greater than zero"

if (( use_last )) && [[ -n "$session" ]]; then
  fail "--last and SESSION cannot be used together"
fi

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

  if [[ "$value" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi

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

if (( ! list_mode )); then
  if [[ -n "$session" ]]; then
    session="$(resolve_session "$session")"
    echo "Resolved session: $session"
  elif (( ! use_last )); then
    fail "specify SESSION or --last"
  fi
fi

find_rollout_for_uuid() {
  local uuid="$1"
  local sessions_dir="$codex_home/sessions"
  local best='' file

  [[ -d "$sessions_dir" ]] || return 1

  while IFS= read -r -d '' file; do
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

file_mtime_epoch() {
  local file="$1" value

  value="$(stat -f '%m' "$file" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  value="$(stat -c '%Y' "$file" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

format_epoch_local() {
  local epoch="$1" value
  value="$(date -r "$epoch" '+%m-%d %H:%M' 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  value="$(date -d "@$epoch" '+%m-%d %H:%M' 2>/dev/null || true)"
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

display_cwd() {
  local value="$1"
  if [[ -n "${HOME:-}" && "$value" == "$HOME" ]]; then
    printf '~\n'
  elif [[ -n "${HOME:-}" && "$value" == "$HOME/"* ]]; then
    local tilde='~'
    printf '%s/%s\n' "$tilde" "${value#"$HOME/"}"
  else
    printf '%s\n' "$value"
  fi
}

list_sessions() {
  local sessions_dir="$codex_home/sessions"
  [[ -d "$sessions_dir" ]] || fail "session directory does not exist: $sessions_dir"
  command -v jq >/dev/null 2>&1 || fail "jq is required to list sessions"

  local tmp_rows
  tmp_rows="$(mktemp "${TMPDIR:-/tmp}/codexwait-list.XXXXXX")"
  trap 'rm -f "$tmp_rows"' RETURN

  local file base uuid mtime
  while IFS= read -r -d '' file; do
    base="${file##*/}"
    if [[ "$base" =~ ([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}) ]]; then
      uuid="${BASH_REMATCH[1]}"
      mtime="$(file_mtime_epoch "$file" || true)"
      [[ -n "$mtime" ]] || continue
      printf '%s\t%s\n' "$mtime" "$uuid" >> "$tmp_rows"
    fi
  done < <(find "$sessions_dir" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)

  [[ -s "$tmp_rows" ]] || {
    echo "No Codex sessions found."
    return 0
  }

  local -a ordered=() ordered_mtimes=() all_sessions=()
  local row_mtime row_uuid seen=''
  while IFS=$'\t' read -r row_mtime row_uuid; do
    [[ -n "$row_uuid" ]] || continue
    if [[ "$seen" == *$'\n'"$row_uuid"$'\n'* ]]; then
      continue
    fi
    seen+=$'\n'"$row_uuid"$'\n'
    ordered+=("$row_uuid")
    ordered_mtimes+=("$row_mtime")
  done < <(sort -t $'\t' -k1,1nr "$tmp_rows")

  all_sessions=("${ordered[@]}")

  local selected_count="${#ordered[@]}"
  (( selected_count > list_limit )) && selected_count="$list_limit"

  local -a selected_uuids=() selected_mtimes=() selected_cwds=() selected_prefixes=()
  local i rollout recorded shown_cwd prefix
  for ((i = 0; i < selected_count; i++)); do
    uuid="${ordered[$i]}"
    rollout="$(find_rollout_for_uuid "$uuid" || true)"
    recorded=''
    [[ -z "$rollout" ]] || recorded="$(read_recorded_cwd "$rollout" || true)"
    if [[ -n "$recorded" ]]; then
      shown_cwd="$(display_cwd "$recorded")"
    else
      shown_cwd='(unknown)'
    fi
    prefix="$(shortest_unique_prefix "$uuid" "${all_sessions[@]}")"
    selected_uuids+=("$uuid")
    selected_mtimes+=("${ordered_mtimes[$i]}")
    selected_cwds+=("$shown_cwd")
    selected_prefixes+=("$prefix")
  done

  printf 'Recent Codex sessions:\n\n'

  local printed_groups=$'\n' group j last_used
  for ((i = 0; i < selected_count; i++)); do
    group="${selected_cwds[$i]}"
    if [[ "$printed_groups" == *$'\n'"$group"$'\n'* ]]; then
      continue
    fi
    printed_groups+="$group"$'\n'

    printf '%s\n' "$group"
    printf '  %-24s %s\n' 'SESSION' 'LAST USED'
    for ((j = 0; j < selected_count; j++)); do
      [[ "${selected_cwds[$j]}" == "$group" ]] || continue
      last_used="$(format_epoch_local "${selected_mtimes[$j]}" || printf '?')"
      printf '  %-24s %s\n' "${selected_prefixes[$j]}" "$last_used"
    done
    printf '\n'
  done
}

if (( list_mode )); then
  list_sessions
  exit 0
fi

command -v codex >/dev/null 2>&1 || {
  echo "codexwait: codex command not found" >&2
  exit 127
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

reported_reset_sleep_seconds() {
  local output_file="$1"
  local match parsed hour minute ampm hour24 now_h now_m now_s now_seconds target_seconds delay

  match="$(grep -Eio 'try again at[[:space:]]+[0-9]{1,2}:[0-9]{2}[[:space:]]*(AM|PM)' "$output_file" | tail -n 1 || true)"
  [[ -n "$match" ]] || return 1

  parsed="$(printf '%s\n' "$match" | sed -E 's/.*[Aa][Tt][[:space:]]+([0-9]{1,2}):([0-9]{2})[[:space:]]*([AaPp][Mm]).*/\1 \2 \3/')"
  read -r hour minute ampm <<< "$parsed"

  [[ "$hour" =~ ^[0-9]{1,2}$ && "$minute" =~ ^[0-9]{2}$ && "$ampm" =~ ^[AaPp][Mm]$ ]] || return 1
  hour=$((10#$hour))
  minute=$((10#$minute))
  (( hour >= 1 && hour <= 12 && minute >= 0 && minute <= 59 )) || return 1

  hour24=$((hour % 12))
  if [[ "${ampm^^}" == "PM" ]]; then
    hour24=$((hour24 + 12))
  fi

  read -r now_h now_m now_s <<< "$(date '+%H %M %S')"
  [[ "$now_h" =~ ^[0-9]{2}$ && "$now_m" =~ ^[0-9]{2}$ && "$now_s" =~ ^[0-9]{2}$ ]] || return 1

  now_seconds=$((10#$now_h * 3600 + 10#$now_m * 60 + 10#$now_s))
  target_seconds=$((hour24 * 3600 + minute * 60))
  delay=$((target_seconds - now_seconds))
  if (( delay <= 0 )); then
    delay=$((delay + 86400))
  fi

  printf '%d\n' "$((delay + reset_delay))"
}

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

  reset_sleep="$(reported_reset_sleep_seconds "$tmp" || true)"
  if [[ -n "$reset_sleep" ]]; then
    printf '[%s] usage/rate limit detected; reported reset time found, retrying in %ds.\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reset_sleep"
    sleep "$reset_sleep"
  else
    printf '[%s] usage/rate limit detected; retrying in %ds.\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$interval"
    sleep "$interval"
  fi
done
