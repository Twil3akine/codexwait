# codexwait

`codexwait` is a small wrapper around the Codex CLI that waits for usage/rate limits to recover and then resumes an existing Codex session.

It retries **only** when the Codex output looks like a usage/rate-limit failure. Other failures stop immediately.

## Usage

```sh
# Full UUID
codexwait 01a1302e-0872-79b2-98c2-93f4299c6339

# Unique UUID prefix (8+ hex chars)
codexwait 01a1302e

# Most recent session
codexwait --last

# Retry every 15 minutes
codexwait --interval 900 01a1302e

# Keep a Mac awake while waiting
codexwait --keep-awake 01a1302e
```

By default, retries happen every 600 seconds.

## Why the UUID prefix works

Codex stores session rollout files under `$CODEX_HOME/sessions` (normally `~/.codex/sessions`). `codexwait` scans rollout filenames, expands a unique 8+ character UUID prefix to the full session UUID, and refuses ambiguous prefixes.

This filesystem layout is an implementation detail of Codex rather than a stable public API, so a future Codex release may require an update to `codexwait`.

## Resume prompt

The default prompt is intentionally conservative:

> Resume the previous work. First inspect the current git status and existing artifacts. Do not repeat completed work; continue from the unfinished part.

Override it with:

```sh
codexwait --prompt 'Continue the unfinished benchmark work.' 01a1302e
```

or `CODEXWAIT_PROMPT`.

## Safety behavior

- Successful Codex exit: stop.
- Usage/rate-limit-looking failure: wait and retry.
- Any other non-zero exit: stop immediately.
- Ambiguous session prefix: stop before running Codex.
- `--max-attempts N`: optionally cap retry attempts.

The limit-detection regex can be overridden with `CODEXWAIT_LIMIT_REGEX` if Codex changes its error wording.

## Nix

Run directly:

```sh
nix run github:OWNER/codexwait -- 01a1302e
```

Or add the package to your flake and include `codexwait` in `environment.systemPackages` / `home.packages`.

## Development

```sh
bash tests/test.sh
nix flake check
```

## License

MIT
