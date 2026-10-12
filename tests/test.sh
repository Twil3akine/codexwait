#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CODEX_HOME="$TMP/codex"
export HOME="$TMP/home"
mkdir -p "$CODEX_HOME/sessions/2026/10/13" "$HOME" "$TMP/bin"

UUID='01a1302e-0872-79b2-98c2-93f4299c6339'
touch "$CODEX_HOME/sessions/2026/10/13/rollout-2026-10-13T00-00-00-$UUID.jsonl"

cat > "$TMP/bin/codex" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
count_file="${CODEXWAIT_TEST_COUNT:?}"
count=0
[[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf '%s\n' "$*" >> "${CODEXWAIT_TEST_ARGS:?}"
if (( count < 2 )); then
  echo "You've hit your usage limit. Try again later." >&2
  exit 1
fi
echo "resumed"
SCRIPT
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"
export CODEXWAIT_TEST_COUNT="$TMP/count"
export CODEXWAIT_TEST_ARGS="$TMP/args"

CODEXWAIT_INTERVAL=1 "$ROOT/src/codexwait.sh" 01a1302e >/dev/null

grep -q "$UUID" "$CODEXWAIT_TEST_ARGS"
[[ "$(cat "$CODEXWAIT_TEST_COUNT")" == "2" ]]

echo "ok: prefix resolution + limit retry"

# Ambiguous prefix must fail without invoking Codex.
UUID2='01a1302e-1111-2222-3333-444444444444'
touch "$CODEX_HOME/sessions/2026/10/13/rollout-2026-10-13T00-00-01-$UUID2.jsonl"
: > "$CODEXWAIT_TEST_ARGS"
if CODEXWAIT_INTERVAL=1 "$ROOT/src/codexwait.sh" 01a1302e >/dev/null 2>&1; then
  echo "expected ambiguous prefix to fail" >&2
  exit 1
fi
[[ ! -s "$CODEXWAIT_TEST_ARGS" ]]
echo "ok: ambiguous prefix rejected"
