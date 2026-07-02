# claude-code-multibar

A single-file, pure-bash statusline for [Claude Code](https://claude.com/claude-code) that renders multiple usage bars on one line, plus a git and location line.

[![Built with Claude Code](https://img.shields.io/badge/Built%20with-Claude%20Code-D97757)](https://claude.com/claude-code)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/HusnainRazaGhaffar/claude-code-multibar/actions/workflows/lint.yml/badge.svg)](https://github.com/HusnainRazaGhaffar/claude-code-multibar/actions/workflows/lint.yml)

## What it looks like

```text
🧠 17%[=---------]174k/1000k 🤖 Fable 5 (max) ⚡ 26%[==--------]56m → 01:20 📅 11%[=---------]4d 6h 📖 4%[----------]4d 6h 🕐 00:23
🌿 (main*) user@host:~/projects/demo
```

That's real script output (colors are ANSI escape codes, stripped here for readability; `user`, `host`, and the path are placeholders).

## Segment legend

Every segment is self-contained. Most hide themselves entirely when there's nothing to show, no credentials, no data in the API response, or a value below its display threshold, instead of printing a placeholder.

| Segment | Meaning |
|---|---|
| 🧠 | Context window: percent used, a progress bar, tokens used / max tokens, and the change since the last render (for example `+9k`). |
| 🤖 | The active model, plus its reasoning effort level in parentheses when the model reports one (for example `Fable 5 (max)`). |
| ⚡ | Anthropic models: the 5-hour session rate limit, with a countdown and the clock time it resets. GLM models: the same emoji shows GLM Coding Plan token quota instead (percent, bar, and a countdown or window-length label). The two never appear together, they're gated on which model is active. |
| 📅 | The 7-day, all-models weekly rate limit, with a countdown to reset (no clock time shown). |
| 📖 | A weekly limit scoped to a specific promotional model (for example Fable), parsed generically from the usage API's `limits[]` array. Absent entirely when the API sends none. |
| 💳 | Extra-usage (pay-per-use) credit consumption. Hidden unless extra usage is enabled on the account and utilization has reached at least 1%. |
| 🎵 / 🎭 | Legacy weekly Sonnet / Opus limits. Rendered only if the usage API still sends `seven_day_sonnet` / `seven_day_opus`; the API has largely moved this data into the `limits[]` array (see 📖 above), so these may rarely show up. |
| 💰 | Moonshot (Kimi) account balance. Shown only when a Kimi model is active and `MOONSHOT_API_KEY` is set. |
| 🕐 | Local time the snapshot was rendered. |
| 🌿 | Git branch (or short commit SHA in detached HEAD), with `*` for uncommitted changes and `↑N` / `↓N` for commits ahead or behind the upstream branch. |

Max context, the denominator in the 🧠 segment, is auto-detected per model: 200k for most Claude models, 256k for Kimi, 1M for Fable and the Sonnet/Opus `1M` variants, and 128k to 1M for GLM depending on version. The script uses whichever is larger, its own table or the size Claude Code reports, since Claude Code can under-report context size for non-Anthropic models.

## Features

- **Single file, no daemon.** One bash script; it runs once per statusline refresh and exits. Nothing to install as a service.
- **Multi-provider usage.** The context-window bar works for every model, sourced directly from Claude Code's own session data. On top of that: Anthropic OAuth usage (5-hour and weekly rate limits), Moonshot Kimi balance, and Z.ai/Bigmodel GLM Coding Plan quota, each gated on the model actually active in your session, so you only see numbers relevant to what you're running.
- **Six-tier fallback chain for usage data:** fresh shared cache -> failure backoff -> flock-serialized API fetch -> stale cache -> persistent last-good cache -> manual cache. The line keeps showing usage numbers even when the API is briefly unreachable.
- **Cache-stampede protection.** Concurrent Claude Code sessions serialize their usage-API fetch through `flock`. Where `flock` isn't available (stock macOS), the fetch proceeds unlocked instead of being skipped.
- **Color-coded thresholds.** Bars turn yellow at 50% used and red at 80% (dim below 10%).
- **Context-delta tracking.** Shows the change in context tokens since the last render (`+9k`), and flags a sharp drop as `(cleared)` when it looks like a compaction happened.
- **Actionable empty state (Anthropic models).** If Anthropic usage data can't be fetched at all (not logged in, or every fallback tier failed), the line shows a hint instead of going blank. Kimi and GLM segments self-hide silently instead, matching their own gating.
- **Fork-frugal bash.** ANSI colors are precomputed once; the input JSON is parsed with a single merged `jq` call, and each provider's response with one merged extraction call (plus one small validation call on a live, uncached fetch); `$EPOCHSECONDS` is used instead of shelling out to `date` on bash >= 5.

## Requirements

Pure bash: no package manager, no build step.

| Tool | Required | Why |
|---|---|---|
| `bash` >= 4.4 | Yes | Needs named file descriptors, `printf '%(...)T'`, and empty-array handling under `set -u`. The script checks its own version and exits with a clear message if it's too old. macOS ships bash 3.2 as `/bin/bash`; install a newer one with `brew install bash`. The shebang is `#!/usr/bin/env bash`, so a Homebrew bash earlier on `PATH` is picked up automatically. |
| `jq` | Yes | Parses the JSON Claude Code sends on stdin, and every provider's API response. |
| `curl` | Yes\* | Fetches usage/balance/quota data from the Anthropic, Moonshot, and Z.ai/Bigmodel APIs. |
| `flock` (util-linux) | Optional | Serializes concurrent usage-API fetches across sessions. If missing, fetches proceed unlocked rather than being skipped. |
| `git` | Optional | Powers the 🌿 branch/dirty/ahead-behind segment. Skipped outside a git repo or without git installed. |
| `sha256sum` | Optional | Hashes the parent PID for the cache directory name when no session ID is available. Falls back to the raw PID if missing. |
| `python3` | Optional | Last-resort timestamp parser, used only if GNU `date`, `gdate`, and BSD `date` all fail to parse a reset time. |

\* Unlike `bash`/`jq`, a missing `curl` doesn't crash the script; every usage segment just self-hides. "Yes" means required for the usage bars to ever populate, not required for the script to run.

## Install

1. Copy the script into your Claude Code config directory and make it executable:

   ```bash
   cp statusline.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

2. Add a `statusLine` entry to `~/.claude/settings.json` (or your project's `.claude/settings.json`):

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh"
     }
   }
   ```

3. Settings reload automatically; the statusline appears on your next interaction with Claude Code. See the [statusline docs](https://code.claude.com/docs/en/statusline) for extra options such as `padding` and `refreshInterval`.

## Configuration

Everything below is an environment variable with a built-in default, so the script works unconfigured.

| Variable | Default | Purpose |
|---|---|---|
| `STATUSLINE_CACHE_TTL` | `30` | Reserved fallback TTL inside the internal cache helper; currently unused because every call site passes its own TTL (one of the four variables below). Setting it has no effect today. |
| `STATUSLINE_USAGE_TTL` | `300` | How long, in seconds, the shared Anthropic usage-API cache is considered fresh. |
| `STATUSLINE_KIMI_TTL` | `300` | How long, in seconds, the Kimi balance cache is considered fresh. |
| `STATUSLINE_GLM_TTL` | `300` | How long, in seconds, the GLM quota cache is considered fresh. |
| `STATUSLINE_DEBUG` | `false` | Set to `true` to print `[DEBUG]` diagnostics to stderr. |
| `STATUSLINE_USAGE_FAIL_BACKOFF` | `300` | Seconds to wait before retrying the usage API after a failed fetch. |
| `MOONSHOT_API_KEY` | (unset) | Your Moonshot API key. Enables the 💰 Kimi balance segment; without it, the segment is skipped even when a Kimi model is active. |
| `ANTHROPIC_AUTH_TOKEN` | (unset) | Required to enable the GLM Coding Plan quota fetch. |
| `ANTHROPIC_BASE_URL` | `https://api.z.ai/api/anthropic` (script's internal default) | Selects the GLM quota endpoint: URLs containing `open.bigmodel.cn` route to Bigmodel, everything else routes to Z.ai. Normally already set by whatever GLM Coding Plan integration you're using. |

## Privacy and security

Read this before pointing the script at a real session.

- The script reads your Claude Code OAuth access token from `~/.claude/.credentials.json` and sends it to exactly one place: `https://api.anthropic.com/api/oauth/usage`. That endpoint is undocumented, it isn't part of Anthropic's public API, and it can change or break without notice.
- The token is never passed as a command-line argument. It's handed to `curl` through a small config block piped over stdin, so it never shows up in `ps` output or shell history.
- Successful responses are cached on disk so the statusline doesn't have to call the API on every render: a shared cache under `$XDG_RUNTIME_DIR` (falling back to `$TMPDIR`, then `/tmp`) at `claude-statusline-<uid>/`, and a persistent "last known good" copy at `~/.claude/usage_api_last_good.json`, tried after the shared cache and a live fetch have both failed (the optional manual `usage_cache.json` is the true last resort). The script creates its cache directories with `chmod 700`, and cache files are written atomically through `mktemp`, whose default permissions are `0600` (owner read/write only).
- These cached files contain the full raw response from the usage endpoint, whatever fields it happens to include. Treat them as sensitive: don't commit them or paste them into a bug report. This repo's `.gitignore` already excludes `usage_api_last_good.json`, `usage_cache.json` (an optional manual-seed fallback), and the runtime cache directories.
- If a Kimi model is active and `MOONSHOT_API_KEY` is set, the script also calls `api.moonshot.cn` for your balance. If a GLM model is active and `ANTHROPIC_AUTH_TOKEN` is set, it calls `api.z.ai` (or `open.bigmodel.cn`, depending on `ANTHROPIC_BASE_URL`) for your quota. Both follow the same "only while that model is active" gating as their segments.
- Roughly one render in twenty, the script runs a background cleanup pass that deletes per-session cache directories older than 24 hours and leftover temp files older than an hour. It runs detached, so it doesn't block your statusline.
- No telemetry, no analytics, no data leaves your machine except the provider API calls described above, and only when the corresponding model or credentials are actually in play.

## How it works

Claude Code pipes a JSON snapshot of the session (model, context window, effort level, session ID, transcript path, working directory) to the script's stdin on every statusline refresh. The script parses that JSON with one merged `jq` call rather than one call per field, then decides which usage API to query based on the active model (Anthropic, Kimi, or GLM), checking cache before ever touching the network. The Anthropic usage fetch falls back through the full six-tier chain described above; the Kimi and GLM fetches use a simpler fresh-cache, live-fetch, stale-cache fallback. Each metric becomes a small emoji-plus-percentage-plus-bar segment with a threshold-based color, and the whole thing prints as exactly two lines: context, model, and usage segments on the first line, git branch and location on the second.

## Similar projects

- [ccstatusline](https://github.com/sirmalloc/ccstatusline): listed in Claude Code's own documentation as a community statusline project, written in TypeScript with a themeable, configurable architecture (10k+ GitHub stars). If you want a polished, actively maintained option with a broader feature set, start there.
- [ccusage](https://github.com/ccusage/ccusage): a usage analytics CLI for Claude Code. An earlier, private version of this script shelled out to `ccusage` for usage numbers before this from-scratch OAuth rewrite.

## Acknowledgements

Built with the help of [Claude Code](https://claude.com/claude-code).

## License

[MIT](LICENSE)
