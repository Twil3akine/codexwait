# codexwait

**English** | [日本語](./README.ja.md)

`codexwait` is a small wrapper around the Codex CLI that waits for usage/rate limits to recover and then resumes an existing Codex session.

It retries **only** when the Codex output looks like a usage/rate-limit failure. Other failures stop immediately.

## Requirements

- Codex CLI installed and authenticated (`codex` on `PATH`).
- An existing Codex session to resume.
- macOS or Linux. `--keep-awake` uses macOS `caffeinate` when available.

When installed through Nix, `jq` and the other helper utilities used by `codexwait` are included automatically.

## Usage

```sh
# Show recent sessions, newest first
codexwait list

# Show more sessions
codexwait list --limit 20

# Full UUID
codexwait 01a1302e-0872-79b2-98c2-93f4299c6339

# Unique UUID prefix
codexwait 01a1302e-0872

# Most recent session (explicit cwd required for safety)
codexwait --last --cwd /path/to/project

# Retry every 15 minutes
codexwait --interval 900 01a1302e-0872

# Override the recorded working directory
codexwait --cwd /path/to/project 01a1302e-0872

# Keep a Mac awake while waiting
codexwait --keep-awake 01a1302e-0872
```

By default, retries happen every 600 seconds.

## Session listing

`codexwait list` scans `$CODEX_HOME/sessions` and prints recent sessions in rollout-file modification order, which approximates most-recently-used order. It shows a short prefix that is unique among the sessions currently found plus the creation-time working directory recorded by Codex.

```text
Recent Codex sessions:

  SESSION                  DIRECTORY
  01a1302e-087             ~/src/macos-programmable-shell
  01a1302e-08a             ~/src/codexwait
```

The session store is an internal Codex format, so listing may need updates if Codex changes its rollout layout.

## UUID prefixes

Codex stores session rollout files under `$CODEX_HOME/sessions` (normally `~/.codex/sessions`). `codexwait` scans rollout filenames and expands a unique 8+ character UUID prefix to the full session UUID.

Many Codex session UUIDs can share the same leading characters, so a short prefix such as `01a1302e` may be ambiguous. In that case `codexwait` refuses to guess and prints a shortest useful prefix suggestion for each matching session:

```text
codexwait: session prefix '01a1302e' is ambiguous:
  01a1302e-0872-...  (try: 01a1302e-087)
  01a1302e-08a4-...  (try: 01a1302e-08a)
```

This filesystem layout is an implementation detail of Codex rather than a stable public API, so a future Codex release may require an update to `codexwait`.

## Working directory safety

`codex exec resume` can resume a thread from the caller's current directory instead of the directory recorded in the thread. That is dangerous for an unattended retry wrapper because the model may continue work in the wrong repository.

For an explicit UUID or UUID prefix, `codexwait` reads the creation-time `session_meta.cwd` from the session rollout and resumes from that directory. It deliberately does **not** use the latest `turn_context.cwd`: a failed or accidental resume from the wrong repository can itself append a newer turn context and would otherwise poison future retries. It prints the selected directory before starting Codex:

```text
Resolved session: 01a1302e-0872-79b2-98c2-93f4299c6339
Session cwd: /Users/me/src/project
Current cwd: /Users/me/src/codexwait
Resuming from session cwd.
```

The original recorded directory must still exist. If the session was intentionally moved to another checkout/worktree, override it explicitly:

```sh
codexwait --cwd /new/path/to/project 01a1302e-0872
```

`--last` and named sessions cannot currently be mapped to rollout metadata safely by `codexwait`, so they require `--cwd DIR`. The Nix package includes `jq`, which is used to read rollout JSONL metadata. When running `src/codexwait.sh` directly, install `jq` or use `--cwd DIR`.

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
- Explicit UUID/prefix sessions resume from their recorded working directory unless `--cwd` overrides it.
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

### From a local clone

Run without installing:

```sh
nix run . -- list
nix run . -- 01a1302e-0872
```

Install into your user profile:

```sh
nix profile install .
codexwait list
```

### From GitHub

After the repository is published, replace `<owner>` with the GitHub owner:

```sh
nix run github:<owner>/codexwait -- list
nix profile install github:<owner>/codexwait
```

### nix-darwin / Home Manager

Add the flake as an input:

```nix
inputs.codexwait.url = "github:<owner>/codexwait";
```

Then add the package where you manage packages:

```nix
environment.systemPackages = [
  inputs.codexwait.packages.${pkgs.system}.default
];
```

For Home Manager, put the same package in `home.packages` instead.

The Codex CLI itself is intentionally not bundled; `codexwait` expects an authenticated `codex` command to already be available.

## Development

```sh
bash tests/test.sh
nix flake check
```

## License

MIT
