#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export CODEX_HOME="$TMP/codex"
export CODEXWAIT_LOCK_DIR="$TMP/locks"
mkdir -p "$HOME" "$CODEX_HOME/sessions/2026/10/13" "$CODEXWAIT_LOCK_DIR" "$TMP/bin" "$TMP/project-a" "$TMP/project-b"

UUID1='01a1302e-0872-79b2-98c2-93f4299c6339'
UUID2='01a1302e-08a4-7343-8254-19d0945b49f1'
UUID3='01a130ff-1111-2222-3333-444444444444'
ROLLOUT1="$CODEX_HOME/sessions/2026/10/13/rollout-a-$UUID1.jsonl"
ROLLOUT2="$CODEX_HOME/sessions/2026/10/13/rollout-b-$UUID2.jsonl"
ROLLOUT3="$CODEX_HOME/sessions/2026/10/13/rollout-c-$UUID3.jsonl"

printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"meta\":{\"cwd\":\"$TMP/project-a\"}}}" > "$ROLLOUT3"
sleep 1
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"meta\":{\"cwd\":\"$TMP/project-a\"}}}" > "$ROLLOUT1"
sleep 1
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"meta\":{\"cwd\":\"$TMP/project-b\"}}}" > "$ROLLOUT2"

list_out="$TMP/list.out"
"$ROOT/src/codexwait.sh" list --limit 3 > "$list_out"
[[ "$(grep -Fc "$TMP/project-a" "$list_out")" == 1 ]]
[[ "$(grep -Fc "$TMP/project-b" "$list_out")" == 1 ]]
[[ "$(grep -c 'LAST USED' "$list_out")" == 2 ]]
project_b_line="$(grep -nF "$TMP/project-b" "$list_out" | cut -d: -f1)"
project_a_line="$(grep -nF "$TMP/project-a" "$list_out" | cut -d: -f1)"
(( project_b_line < project_a_line ))
uuid1_line="$(grep -n '01a1302e-087' "$list_out" | cut -d: -f1)"
uuid3_line="$(grep -n '01a130ff' "$list_out" | cut -d: -f1)"
(( uuid1_line < uuid3_line ))
grep -Eq '[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' "$list_out"
echo "ok: grouped recent session list"

cat > "$TMP/bin/codex" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count_file="${CODEXWAIT_TEST_COUNT:?}"
count=0
[[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
if (( count == 1 )); then
  echo "You've hit your usage limit. try again at ${CODEXWAIT_TEST_RESET_TIME:?}" >&2
  exit 1
fi
SCRIPT

cat > "$TMP/bin/date" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == '+%H %M %S' ]]; then
  printf '%s\n' "${CODEXWAIT_TEST_NOW_HMS:?}"
else
  printf '%s\n' '2026-10-13 03:20:30'
fi
SCRIPT

cat > "$TMP/bin/sleep" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${CODEXWAIT_TEST_SLEEPS:?}"
SCRIPT

chmod +x "$TMP/bin/codex" "$TMP/bin/date" "$TMP/bin/sleep"
export PATH="$TMP/bin:$PATH"
export CODEXWAIT_TEST_COUNT="$TMP/count"
export CODEXWAIT_TEST_SLEEPS="$TMP/sleeps"

rm -f "$CODEXWAIT_TEST_COUNT" "$CODEXWAIT_TEST_SLEEPS"
CODEXWAIT_TEST_RESET_TIME='3:21 AM' \
CODEXWAIT_TEST_NOW_HMS='03 20 30' \
CODEXWAIT_RESET_DELAY=10 \
  "$ROOT/src/codexwait.sh" "$UUID1" > "$TMP/reset-am.out"
[[ "$(cat "$CODEXWAIT_TEST_COUNT")" == 2 ]]
[[ "$(cat "$CODEXWAIT_TEST_SLEEPS")" == 40 ]]
grep -q 'reported reset time found, retrying in 40s' "$TMP/reset-am.out"
echo "ok: reported AM reset time"

rm -f "$CODEXWAIT_TEST_COUNT" "$CODEXWAIT_TEST_SLEEPS"
CODEXWAIT_TEST_RESET_TIME='12:01 AM' \
CODEXWAIT_TEST_NOW_HMS='23 59 50' \
CODEXWAIT_RESET_DELAY=10 \
  "$ROOT/src/codexwait.sh" "$UUID1" >/dev/null
[[ "$(cat "$CODEXWAIT_TEST_SLEEPS")" == 80 ]]
echo "ok: reset time midnight rollover"

cat > "$TMP/bin/codex" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count_file="${CODEXWAIT_TEST_COUNT:?}"
count=0
[[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
if (( count == 1 )); then
  echo 'usage limit; try again later' >&2
  exit 1
fi
SCRIPT
chmod +x "$TMP/bin/codex"

rm -f "$CODEXWAIT_TEST_COUNT" "$CODEXWAIT_TEST_SLEEPS"
CODEXWAIT_INTERVAL=7 "$ROOT/src/codexwait.sh" "$UUID1" >/dev/null
[[ "$(cat "$CODEXWAIT_TEST_SLEEPS")" == 7 ]]
echo "ok: reset parse fallback interval"
