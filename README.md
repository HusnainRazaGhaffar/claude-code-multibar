# claude-code-multibar

A single-file, pure-bash statusline for [Claude Code](https://claude.com/claude-code) that renders multiple usage bars on one line, plus a git and location line. Ships with an optional companion script that does the same for the sub-agent panel (see [Sub-agent statusline](#sub-agent-statusline)).

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
| ⚡ | Anthropic models: the 5-hour session rate limit, with a countdown and the clock time it resets. GLM models: the same emoji shows GLM Coding Plan token quota instead. OpenAI models: the ChatGPT/Codex 5-hour window, fetched from the local `codex app-server`. Only one of these appears, gated on which model is active. |
| 📅 | Anthropic models: the 7-day, all-models weekly rate limit, with a countdown to reset (no clock time shown). OpenAI models: the Codex weekly window. Grok models: SuperGrok weekly credit usage; hidden when there is no readable Grok login file on this machine, and shown as `Grok N/A` when one exists but no usable number comes back. |
| ⏳ | Any other Codex rate-limit window whose duration is neither 5 hours nor 7 days. |
| 💰 | Session cost in USD, straight from Claude Code's own `cost.total_cost_usd` field (shown next to the model). For Kimi models a second 💰 segment showing the Moonshot account balance appears as well, so cost and balance can sit side by side. |
| 📖 | A weekly limit scoped to a specific promotional model (for example Fable), parsed generically from the usage API's `limits[]` array. Absent entirely when the API sends none. |
| 💳 | Extra-usage (pay-per-use) credit consumption. Hidden unless extra usage is enabled on the account and utilization has reached at least 1%. |
| 🎵 / 🎭 | Legacy weekly Sonnet / Opus limits. Rendered only if the usage API still sends `seven_day_sonnet` / `seven_day_opus`; the API has largely moved this data into the `limits[]` array (see 📖 above), so these may rarely show up. |
| 🕐 | Local time the snapshot was rendered. |
| 🌿 | Git branch (or short commit SHA in detached HEAD), with `*` for uncommitted changes and `↑N` / `↓N` for commits ahead or behind the upstream branch. |

Max context, the denominator in the 🧠 segment, is auto-detected per model: 200k for most Claude models, 256k for Kimi, 1M for Fable and the Sonnet/Opus `1M` variants, 500k for Grok 4.5, and 128k to 1M for GLM depending on version. The script uses whichever is larger, its own table or the size Claude Code reports, since Claude Code can under-report context size for non-Anthropic models.

## Features

- **Single file, no daemon.** One bash script; it runs once per statusline refresh and exits. Nothing to install as a service.
- **Multi-provider usage.** The context-window bar works for every model, sourced directly from Claude Code's own session data. On top of that: Anthropic OAuth usage (5-hour and weekly rate limits), ChatGPT/Codex rate-limit windows (via the local `codex app-server`), Grok SuperGrok weekly credits, Moonshot Kimi balance, and Z.ai/Bigmodel GLM Coding Plan quota, each gated on the model actually active in your session, so you only see numbers relevant to what you're running.
- **Session cost segment.** When Claude Code reports a running cost for the session, a 💰 segment renders it next to the model name; it self-hides at $0.
- **Six-tier fallback chain for usage data:** fresh shared cache -> failure backoff -> flock-serialized API fetch -> stale cache -> persistent last-good cache -> manual cache. The line keeps showing usage numbers even when the API is briefly unreachable.
- **Cache-stampede protection.** Concurrent Claude Code sessions serialize their usage-API fetch through `flock`. Where `flock` isn't available (stock macOS), the fetch proceeds unlocked instead of being skipped.
- **Color-coded thresholds.** Bars turn yellow at 50% used and red at 80% (dim below 10%).
- **Context-delta tracking.** Shows the change in context tokens since the last render (`+9k`), and flags a sharp drop as `(cleared)` when it looks like a compaction happened.
- **Actionable empty state (Anthropic models).** If Anthropic usage data can't be fetched at all, the line shows a login hint when no credentials exist (file or macOS Keychain), or an `N/A` placeholder when credentials exist but every fallback tier failed. Kimi and GLM segments self-hide silently instead, matching their own gating.
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
| `python3` | Optional | Last-resort timestamp parser; also decodes the Grok token's expiry (from the token itself) to avoid needless refreshes, and powers the sub-agent script's transcript-based token counts. |
| `codex` | Optional | The OpenAI Codex CLI. Only used when an OpenAI model is active, to ask its local `app-server` for rate-limit windows. Without it, the Codex bars self-hide. |
| `security` | Optional | Ships with macOS. Used twice: to read the Anthropic OAuth token from the login Keychain when the credentials file yields none, and to check (without reading any secret) whether a Keychain login exists before showing the login hint. Not present on Linux, where only the file is used. |

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
| `STATUSLINE_CODEX_TTL` | `300` | How long, in seconds, the Codex rate-limit cache is considered fresh. |
| `STATUSLINE_GROK_TTL` | `300` | How long, in seconds, the Grok weekly-credit cache is considered fresh. |
| `STATUSLINE_KIMI_TTL` | `300` | How long, in seconds, the Kimi balance cache is considered fresh. |
| `STATUSLINE_GLM_TTL` | `300` | How long, in seconds, the GLM quota cache is considered fresh. |
| `STATUSLINE_DEBUG` | `false` | Set to `true` to print `[DEBUG]` diagnostics to stderr. |
| `STATUSLINE_USAGE_FAIL_BACKOFF` | `300` | Seconds to wait before retrying the usage API after a failed fetch. |
| `STATUSLINE_CODEX_FAIL_BACKOFF` | `60` | Seconds to wait before retrying the Codex app-server after a failed fetch. |
| `STATUSLINE_GROK_FAIL_BACKOFF` | `60` | Seconds to wait before retrying the Grok billing API after a failed fetch. |
| `MOONSHOT_API_KEY` | (unset) | Your Moonshot API key. Enables the 💰 Kimi balance segment; without it, the segment is skipped even when a Kimi model is active. |
| `ANTHROPIC_AUTH_TOKEN` | (unset) | Required to enable the GLM Coding Plan quota fetch. |
| `ANTHROPIC_BASE_URL` | `https://api.z.ai/api/anthropic` (script's internal default) | Selects the GLM quota endpoint: URLs containing `open.bigmodel.cn` route to Bigmodel, everything else routes to Z.ai. Normally already set by whatever GLM Coding Plan integration you're using. |

## Privacy and security

Read this before pointing the script at a real session.

- The script reads your Claude Code OAuth access token from `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json` if you have relocated Claude Code's config directory). On macOS, where Claude Code typically keeps that token in the login Keychain rather than a file, it falls back to reading the Keychain item named `Claude Code-credentials` with the `security` tool that ships with macOS; it also probes that item's existence (attributes only, never the secret) to decide between the login hint and the N/A placeholder. Wherever it came from, the token goes to exactly one place: `https://api.anthropic.com/api/oauth/usage`. That endpoint is undocumented, it isn't part of Anthropic's public API, and it can change or break without notice.
- No token or API key is ever passed as a command-line argument. Every credential the script sends (Anthropic, Grok, Kimi, GLM) is handed to `curl` through a small config block piped over stdin, so none of them show up in `ps` output or shell history.
- Successful responses are cached on disk so the statusline doesn't have to call the API on every render: a shared cache under `$XDG_RUNTIME_DIR` (falling back to `$TMPDIR`, then `/tmp`) at `claude-statusline-<uid>/`, and a persistent "last known good" copy at `~/.claude/usage_api_last_good.json`, tried after the shared cache and a live fetch have both failed (the optional manual `usage_cache.json` is the true last resort). The script creates its cache directories with `chmod 700`, and cache files are written atomically through `mktemp`, whose default permissions are `0600` (owner read/write only).
- These cached files contain the full raw response from the usage endpoint, whatever fields it happens to include. Treat them as sensitive: don't commit them or paste them into a bug report. This repo's `.gitignore` already excludes `usage_api_last_good.json`, `usage_cache.json` (an optional manual-seed fallback), and the runtime cache directories.
- If an OpenAI model is active and the `codex` CLI is installed, the script talks to Codex's own local `app-server` over a pipe to read the rate-limit windows Codex itself displays. It never reads or copies your OpenAI OAuth token; only the sanitized window numbers (percent used, duration, reset time) are cached.
- If a Grok model is active, the script reads the access token from the Grok CLI's own auth file at `~/.grok/auth.json` and calls `cli-chat-proxy.grok.com` for your SuperGrok weekly credit usage. When that token is expired or about to expire, the script refreshes it against `auth.x.ai` (the Grok CLI's own OAuth endpoint) and **writes the refreshed token back into `~/.grok/auth.json`**, atomically, under a `flock` lock, preserving every other entry in the file, with permissions forced to owner-only. Two honest caveats: the lock only coordinates this script's own concurrent renders, not the Grok CLI itself, so if the CLI rotates the token during the script's refresh call (a window of a few seconds), the CLI's newer token can be overwritten; and where `flock` doesn't exist (stock macOS), the script never refreshes at all, it only reads whatever valid token is already in the file. This is the one place the script modifies another tool's file; if you would rather it never did that, don't use it with Grok models.
- If a Kimi model is active and `MOONSHOT_API_KEY` is set, the script also calls `api.moonshot.cn` for your balance. If a GLM model is active and `ANTHROPIC_AUTH_TOKEN` is set, it calls `api.z.ai` (or `open.bigmodel.cn`, depending on `ANTHROPIC_BASE_URL`) for your quota. All of these follow the same "only while that model is active" gating as their segments.
- The optional sub-agent statusline reads your local Claude Code sub-agent transcripts and their `agent-*.meta.json` sidecar files (under `~/.claude/projects/`) to compute per-agent token counts and nested-agent counts when the panel payload lacks them. Transcript content never leaves your machine and is never printed; only three numbers per agent (a byte offset and two token counters) are cached, in a directory the script refuses to use unless it owns it (`0700`, symlinks rejected).
- Roughly one render in twenty, the script runs a background cleanup pass that deletes per-session cache directories older than 24 hours and leftover temp files older than an hour. It runs detached, so it doesn't block your statusline.
- No telemetry, no analytics, no data leaves your machine except the provider API calls described above, and only when the corresponding model or credentials are actually in play.

## Sub-agent statusline

`subagent-statusline.sh` is an optional second script for Claude Code's sub-agent panel (the task rows shown while agents run). It replaces each default row with a denser one:

```text
  code-reviewer (+1) 🤖 Opus (max) 🧠 27%[==--------]54k/200k ⏱️ 12m 34s · Review the polish diff
✓ shell                            🧠 0.0k                    ⏱️ 1m 1s   · npm test
```

Columns are padded so rows align like a table. Finished agents get a status mark (✓ done, ✗ failed, ⊘ cancelled); running ones rely on the panel's own activity dot. The 🧠 bar mirrors the main statusline. When Claude Code's payload reports no token count for an agent (it happens with some providers), the script recomputes it from that agent's local transcript, reading incrementally so only lines added since the last render are parsed; `python3` is optional and only used for that.

Two extras the default panel doesn't show:

- **Effort in parentheses** (`Opus (max)`). Claude Code only puts an effort value in the panel payload when the agent definition pins one. Agents without a pinned effort run at the main session's level, so the main `statusline.sh` publishes that level to a small shared cache file and this script fills it in for Claude-family rows. That inheritance display therefore needs both scripts installed; with only this one, effort still appears for agents that pin their own.
- **`(+N)` after the name**: how many live nested agents that agent has spawned itself. Read from the `agent-*.meta.json` sidecar files Claude Code writes next to sub-agent transcripts; an agent counts as live while its transcript was written to in the last 90 seconds.

Install it alongside the main script (needs a Claude Code with the `subagentStatusLine` setting; written and verified against 2.1.220):

```bash
cp subagent-statusline.sh ~/.claude/subagent-statusline.sh
chmod +x ~/.claude/subagent-statusline.sh
```

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  },
  "subagentStatusLine": {
    "type": "command",
    "command": "~/.claude/subagent-statusline.sh"
  }
}
```

On any failure (old bash, missing `jq`, malformed payload) it exits with no output on stdout, so the panel keeps its default rows; a one-line diagnostic goes to stderr, which Claude Code only surfaces in debug mode. Untrusted text from task descriptions is sanitized before it reaches your terminal: control and escape bytes are stripped so a hostile description cannot smuggle terminal escape sequences.

## How it works

Claude Code pipes a JSON snapshot of the session (model, context window, effort level, session ID, transcript path, working directory) to the script's stdin on every statusline refresh. The script parses that JSON with one merged `jq` call rather than one call per field, then decides which usage source to query based on the active model (Anthropic, OpenAI/Codex, Grok, Kimi, or GLM), checking cache before ever touching the network. The Anthropic usage fetch falls back through the full six-tier chain described above; the Kimi and GLM fetches use a simpler fresh-cache, live-fetch, stale-cache fallback. Each metric becomes a small emoji-plus-percentage-plus-bar segment with a threshold-based color, and the whole thing prints as exactly two lines: context, model, and usage segments on the first line, git branch and location on the second.

## Similar projects

- [ccstatusline](https://github.com/sirmalloc/ccstatusline): listed in Claude Code's own documentation as a community statusline project, written in TypeScript with a themeable, configurable architecture (10k+ GitHub stars). If you want a polished, actively maintained option with a broader feature set, start there.
- [ccusage](https://github.com/ccusage/ccusage): a usage analytics CLI for Claude Code. An earlier, private version of this script shelled out to `ccusage` for usage numbers before this from-scratch OAuth rewrite.

## Acknowledgements

Built with the help of [Claude Code](https://claude.com/claude-code).

## License

[MIT](LICENSE)
