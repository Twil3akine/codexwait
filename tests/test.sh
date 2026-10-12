#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CODEX_HOME="$TMP/codex"
export CODEXWAIT_LOCK_DIR="$TMP/locks"
export HOME="$TMP/home"
SESSION_CWD="$TMP/project"
ALT_CWD="$TMP/alternate-project"
mkdir -p "$CODEX_HOME/sessions/2026/10/13" "$HOME" "$TMP/bin" "$CODEXWAIT_LOCK_DIR" "$SESSION_CWD" "$ALT_CWD"
# macOS exposes /var through /private/var; compare physical paths so tests do not
# fail only because mktemp returns the symlinked spelling.
SESSION_CWD_REAL="$(cd "$SESSION_CWD" && pwd -P)"
ALT_CWD_REAL="$(cd "$ALT_CWD" && pwd -P)"

UUID='01a1302e-0872-79b2-98c2-93f4299c6339'
ROLLOUT="$CODEX_HOME/sessions/2026/10/13/rollout-2026-10-13T00-00-00-$UUID.jsonl"
printf '%s\n' \
  "{\"timestamp\":\"2026-10-13T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"meta\":{\"cwd\":\"$SESSION_CWD\"}}}" \
  "{\"timestamp\":\"2026-10-13T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"cwd\":\"$ALT_CWD\"}}" \
  > "$ROLLOUT"

cat > "$TMP/bin/codex" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count_file="${CODEXWAIT_TEST_COUNT:?}"
count=0
[[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf '%s\n' "$*" >> "${CODEXWAIT_TEST_ARGS:?}"
pwd >> "${CODEXWAIT_TEST_PWD:?}"

case "${CODEXWAIT_TEST_MODE:-limit-then-success}" in
  limit-then-success)
    if (( count < 2 )); then
      echo "You've hit your usage limit. Try again later." >&2
      exit 1
    fi
    echo "resumed"
    ;;
  always-limit)
    echo "You've hit your usage limit. Try again later." >&2
    exit 1
    ;;
  active-writer)
    echo "thread-store conflict: thread 01 already has an active writer" >&2
    exit 1
    ;;
  success)
    echo "resumed"
    ;;
  *)
    echo "unknown test mode" >&2
    exit 99
    ;;
esac
SCRIPT
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"
export CODEXWAIT_TEST_COUNT="$TMP/count"
export CODEXWAIT_TEST_ARGS="$TMP/args"
export CODEXWAIT_TEST_PWD="$TMP/pwd"

reset_fake() {
  rm -f "$CODEXWAIT_TEST_COUNT" "$CODEXWAIT_TEST_ARGS" "$CODEXWAIT_TEST_PWD"
  : > "$CODEXWAIT_TEST_ARGS"
  : > "$CODEXWAIT_TEST_PWD"
}

assert_all_pwd() {
  local expected="$1"
  [[ -s "$CODEXWAIT_TEST_PWD" ]]
  while IFS= read -r actual; do
    [[ "$actual" == "$expected" ]] || {
      echo "expected Codex cwd '$expected', got '$actual'" >&2
      exit 1
    }
  done < "$CODEXWAIT_TEST_PWD"
}

# Explicit UUID/prefix should restore the creation-time session cwd. A later
# turn_context deliberately points somewhere else to model a bad resume attempt.
export CODEXWAIT_TEST_MODE=limit-then-success
reset_fake
(
  cd "$TMP"
  CODEXWAIT_INTERVAL=1 "$ROOT/src/codexwait.sh" 01a1302e-0872 >/dev/null
)
grep -q "$UUID" "$CODEXWAIT_TEST_ARGS"
[[ "$(cat "$CODEXWAIT_TEST_COUNT")" == "2" ]]
assert_all_pwd "$SESSION_CWD_REAL"
echo "ok: prefix resolution + limit retry + original session cwd"

# --cwd must override rollout metadata.
export CODEXWAIT_TEST_MODE=success
reset_fake
(
  cd "$TMP"
  "$ROOT/src/codexwait.sh" --cwd "$ALT_CWD" "$UUID" >/dev/null
)
[[ "$(cat "$CODEXWAIT_TEST_COUNT")" == "1" ]]
assert_all_pwd "$ALT_CWD_REAL"
echo "ok: explicit cwd override"

# --last is unsafe without an explicit cwd because codex exec resume would inherit caller cwd.
reset_fake
last_err="$TMP/last.err"
if "$ROOT/src/codexwait.sh" --last >/dev/null 2>"$last_err"; then
  echo "expected --last without --cwd to fail" >&2
  exit 1
fi
[[ ! -s "$CODEXWAIT_TEST_ARGS" ]]
grep -q -- '--last requires --cwd DIR' "$last_err"
echo "ok: --last requires explicit cwd"

# Ambiguous prefix must fail without invoking Codex and should suggest longer prefixes.
UUID2='01a1302e-08a4-7343-8254-19d0945b49f1'
ROLLOUT2="$CODEX_HOME/sessions/2026/10/13/rollout-2026-10-13T00-00-01-$UUID2.jsonl"
printf '%s\n' "{\"timestamp\":\"2026-10-13T00:00:01Z\",\"type\":\"session_meta\",\"payload\":{\"meta\":{\"cwd\":\"$SESSION_CWD\"}}}" > "$ROLLOUT2"
reset_fake
ambiguous_err="$TMP/ambiguous.err"
if CODEXWAIT_INTERVAL=1 "$ROOT/src/codexwait.sh" 01a1302e >/dev/null 2>"$ambiguous_err"; then
  echo "expected ambiguous prefix to fail" >&2
  exit 1
fi
[[ ! -s "$CODEXWAIT_TEST_ARGS" ]]
grep -q 'try:' "$ambiguous_err"
echo "ok: ambiguous prefix rejected with suggestions"

# An active Codex writer is not retryable: show a friendly error and stop immediately.
export CODEXWAIT_TEST_MODE=active-writer
reset_fake
writer_err="$TMP/writer.err"
if "$ROOT/src/codexwait.sh" "$UUID" >/dev/null 2>"$writer_err"; then
  echo "expected active-writer conflict to fail" >&2
  exit 1
fi
[[ "$(cat "$CODEXWAIT_TEST_COUNT")" == "1" ]]
assert_all_pwd "$SESSION_CWD_REAL"
grep -q 'already open elsewhere' "$writer_err"
grep -q 'Close the existing Codex session' "$writer_err"
echo "ok: active writer stops with friendly error"

# A second codexwait for the same explicit session must be rejected before Codex starts.
export CODEXWAIT_TEST_MODE=always-limit
reset_fake
CODEXWAIT_INTERVAL=1 "$ROOT/src/codexwait.sh" --max-attempts 2 "$UUID" >"$TMP/first.out" 2>"$TMP/first.err" &
first_pid=$!

for _ in $(seq 1 50); do
  if find "$CODEXWAIT_LOCK_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.lock' | grep -q .; then
    break
  fi
  sleep 0.05
done

second_err="$TMP/second.err"
if "$ROOT/src/codexwait.sh" "$UUID" >/dev/null 2>"$second_err"; then
  echo "expected duplicate waiter to fail" >&2
  wait "$first_pid" 2>/dev/null || true
  exit 1
fi
grep -q 'already reserved by another codexwait process' "$second_err"
grep -q "$UUID" "$second_err"
grep -q "target:  $SESSION_CWD_REAL" "$second_err"
wait "$first_pid" 2>/dev/null || true

echo "ok: duplicate waiter rejected"

# A stale lock left by a dead owner should be replaced automatically.
lock_dir="$(find "$CODEXWAIT_LOCK_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.lock' | head -n 1 || true)"
if [[ -z "$lock_dir" ]]; then
  checksum="$(printf '%s' "$UUID" | cksum)"
  read -r sum bytes _ <<< "$checksum"
  lock_dir="$CODEXWAIT_LOCK_DIR/${sum}-${bytes}.lock"
fi
mkdir -p "$lock_dir"
printf '%s\n' '99999999' > "$lock_dir/pid"
printf '%s\n' "$UUID" > "$lock_dir/session"
printf '%s\n' 'stale' > "$lock_dir/started_at"
printf '%s\n' '/tmp/stale' > "$lock_dir/cwd"
printf '%s\n' "$SESSION_CWD" > "$lock_dir/target_cwd"

export CODEXWAIT_TEST_MODE=success
reset_fake
"$ROOT/src/codexwait.sh" "$UUID" >/dev/null
[[ "$(cat "$CODEXWAIT_TEST_COUNT")" == "1" ]]
assert_all_pwd "$SESSION_CWD_REAL"
[[ ! -e "$lock_dir" ]]
echo "ok: stale waiter lock recovered"

# list should show sessions newest-first with unique short prefixes and creation-time cwd.
# Make UUID2 newer than UUID without relying on platform-specific touch -t syntax.
sleep 1
touch "$ROLLOUT2"
list_out="$TMP/list.out"
"$ROOT/src/codexwait.sh" list --limit 2 >"$list_out"
first_session_line="$(grep -E '^  01a1302e-' "$list_out" | head -n 1)"
[[ "$first_session_line" == *'01a1302e-08a'* ]] || {
  echo "expected newest session first, got: $first_session_line" >&2
  exit 1
}
grep -q '01a1302e-087' "$list_out"
grep -q "$SESSION_CWD" "$list_out" || grep -q "$SESSION_CWD_REAL" "$list_out"
echo "ok: recent session list"
