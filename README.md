# codexwait

`codexwait` is a small wrapper around the Codex CLI that waits for usage/rate limits to recover and then resumes an existing Codex session.

It retries **only** when the Codex output looks like a usage/rate-limit failure. Other failures stop immediately.

## Usage

```sh
# Full UUID
codexwait 01a1302e-0872-79b2-98c2-93f4299c6339

# Unique UUID prefix
codexwait 01a1302e-0872

# Most recent session
codexwait --last

# Retry every 15 minutes
codexwait --interval 900 01a1302e-0872

# Keep a Mac awake while waiting
codexwait --keep-awake 01a1302e-0872
```

By default, retries happen every 600 seconds.

## UUID prefixes

Codex stores session rollout files under `$CODEX_HOME/sessions` (normally `~/.codex/sessions`). `codexwait` scans rollout filenames and expands a unique 8+ character UUID prefix to the full session UUID.

Many Codex session UUIDs can share the same leading characters, so a short prefix such as `01a1302e` may be ambiguous. In that case `codexwait` refuses to guess and prints a shortest useful prefix suggestion for each matching session:

```text
codexwait: session prefix '01a1302e' is ambiguous:
  01a1302e-0872-...  (try: 01a1302e-087)
  01a1302e-08a4-...  (try: 01a1302e-08a)
```

This filesystem layout is an implementation detail of Codex rather than a stable public API, so a future Codex release may require an update to `codexwait`.

## Resume prompt

The default prompt is intentionally conservative:

> Resume the previous work. First inspect the current git status and existing artifacts. Do not repeat completed work; continue from the unfinished part.

Override it with:

```sh
codexwait --prompt 'Continue the unfinished benchmark work.' 01a1302e-0872
```

or `CODEXWAIT_PROMPT`.

## Safety behavior

- Successful Codex exit: stop.
- Usage/rate-limit-looking failure: wait and retry.
- Codex reports that the session already has an active writer: stop and ask you to close the existing Codex session first.
- Any other non-zero exit: stop immediately.
- Ambiguous session prefix: stop before running Codex and suggest longer prefixes.
- `--max-attempts N`: optionally cap retry attempts.

### One waiter per session

For an explicit session, `codexwait` creates a per-session reservation lock before invoking Codex. A second `codexwait` targeting the same session is rejected immediately and reports the owning PID, start time, and working directory.

Locks are removed on normal exit, `Ctrl-C`, `SIGINT`, and `SIGTERM`. If a process dies without cleanup (for example `kill -9`), the next `codexwait` checks the recorded PID and automatically replaces a stale lock when that PID is no longer alive.

`--last` uses a singleton `--last` reservation because Codex itself resolves which session `--last` means. An explicit-session waiter and a `--last` waiter are therefore not guaranteed to collide at the `codexwait` lock layer; Codex's own active-writer protection still applies.

The lock directory defaults to `$XDG_RUNTIME_DIR/codexwait` when available, otherwise `${TMPDIR:-/tmp}/codexwait-$UID`. Tests or advanced setups can override it with `CODEXWAIT_LOCK_DIR`.

The limit-detection and active-writer regexes can be overridden with `CODEXWAIT_LIMIT_REGEX` and `CODEXWAIT_ACTIVE_WRITER_REGEX` if Codex changes its error wording.

## Nix

Run directly:

```sh
nix run github:OWNER/codexwait -- 01a1302e-0872
```

Or add the package to your flake and include `codexwait` in `environment.systemPackages` / `home.packages`.

## Development

```sh
bash tests/test.sh
nix flake check
```

## License

MIT
