#!/usr/bin/env bash
# Optimized statusline for Claude Code
# Requires bash >= 4.4 (named FDs, printf %(...)T, empty-array nounset
# semantics). macOS: install a modern bash (brew install bash); flock(1)
# is optional for read-only fetches (they proceed unlocked without it), but
# the Grok token refresh REQUIRES it and is skipped when absent (fail closed:
# an unlocked concurrent refresh can revoke the token family).
# v4.0 - Provider hardening + sub-agent companion
# - Grok: refresh fail-closed without flock; refresh token moved off curl argv
#   (config via stdin); segment self-hides when no ~/.grok/auth.json exists;
#   hour-old orphaned auth temp files swept.
# - Codex: bounded coproc reap (stdin EOF, short poll, then pkill the tree);
#   fd redirect order keeps bash diagnostics out of the panel; float duration
#   and epoch resetsAt normalized defensively.
# - Publishes the session effort level to the shared cache so the companion
#   subagent-statusline.sh can render inherited effort per agent row.
# v3.9 - macOS credentials + debug polish
# - Keychain-aware login hint (credentials_present, presence-only probe, cached).
# - CLAUDE_CONFIG_DIR / CLAUDE_SECURESTORAGE_CONFIG_DIR honored for the
#   credentials file; gtimeout fallback for the stdin read.
# - STATUSLINE_DEBUG output actually reaches stderr (call-site and exec
#   redirect scoping); shared run_with_timeout helper.
# v3.8 - Grok weekly credit limit
# - When the active model is Grok, render SuperGrok weekly credit usage
#   (creditUsagePercent + period end) from cli-chat-proxy billing?format=credits.
# - OIDC access-token refresh against auth.x.ai, written back to ~/.grok/auth.json.
# v3.7 - OpenAI quota progress bars
# - Render Codex 5-hour and weekly utilization with the same colored bars,
#   icons, and reset countdowns used by the other provider limit displays.
# v3.6 - Gateway quota and context metadata
# - Render ChatGPT/Codex quota windows for OpenAI models by querying the
#   authenticated local `codex app-server`; no OAuth token parsing or copying.
# - Recognize Grok 4.5's documented 500K context window.
# - Session cost segment (💰) from Claude Code's cost.total_cost_usd.
# v3.5 - Publish hardening
# - chmod 700 on the shared cache root (was umask-dependent under /tmp fallback).
# - flock optional: fetch proceeds unlocked where flock(1) is absent (macOS).
# - Model matching normalized to lowercase (capitalized GLM names worked
#   nowhere); sha256sum guarded; dead variables removed.
# v3.4 - Extra-usage segment + fallback fixes
# - 💳 segment for extra_usage (pay-per-use credits), only when enabled
#   and utilization >= 1% (self-hiding).
# - get_max_context knows Fable (1M) and Opus 1M variants.
# - used_percentage tolerates float values.
# - $EPOCHSECONDS over $(date +%s) in hot paths (fewer forks on bash >= 5).
# v3.3 - Weekly model-scoped limits (Fable etc.)
# - Parse `.limits[]` entries with kind "weekly_scoped" (📖 bar, emoji only).
#   The API retired the flat seven_day_sonnet key in favor of these.
# v3.2 - Render timestamp on line 1
# - Line 1 ends with `🕐 HH:MM` showing when the snapshot was generated.
# v3.1 - OAuth usage + cache-stampede hardening
# - OAuth usage API with multi-tier fallback (shared cache, persistent
#   last-good at ~/.claude/usage_api_last_good.json, manual cache).
# - flock-based stampede protection + failure backoff for concurrent sessions.
# - Pre-computed ANSI color variables (eliminated ~30 forks).
# - Merged jq calls, replaced cat with $(<file), ${var%\%} over sed.
# - Periodic background cleanup of stale per-session cache dirs.
# - 2-line display: context + model + rate limits | git + location.

# Fail fast with a clear message instead of cryptic syntax/nounset errors
# on old interpreters (macOS ships bash 3.2 as /bin/bash).
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'statusline.sh: bash >= 4.4 required, found %s (macOS: brew install bash)\n' "$BASH_VERSION" >&2
    exit 1
fi

set -uo pipefail
IFS=$'\n\t'

# ---- Configuration ----
readonly STATUSLINE_CACHE_TTL="${STATUSLINE_CACHE_TTL:-30}"
readonly STATUSLINE_USAGE_TTL="${STATUSLINE_USAGE_TTL:-300}"
readonly STATUSLINE_CODEX_TTL="${STATUSLINE_CODEX_TTL:-300}"
readonly STATUSLINE_KIMI_TTL="${STATUSLINE_KIMI_TTL:-300}"
readonly STATUSLINE_GLM_TTL="${STATUSLINE_GLM_TTL:-300}"
readonly STATUSLINE_GROK_TTL="${STATUSLINE_GROK_TTL:-300}"
readonly STATUSLINE_DEBUG="${STATUSLINE_DEBUG:-false}"
readonly STATUSLINE_USAGE_FAIL_BACKOFF="${STATUSLINE_USAGE_FAIL_BACKOFF:-300}"
readonly STATUSLINE_CODEX_FAIL_BACKOFF="${STATUSLINE_CODEX_FAIL_BACKOFF:-60}"
readonly STATUSLINE_GROK_FAIL_BACKOFF="${STATUSLINE_GROK_FAIL_BACKOFF:-60}"
readonly PROGRESS_BAR_WIDTH=10
readonly TRANSCRIPT_TAIL_LINES=20

# ---- Debug Helper ----
debug_log() {
    [[ "$STATUSLINE_DEBUG" == "true" ]] && printf '[DEBUG] %s\n' "$*" >&2
}

# ---- Pre-computed color variables (eliminates ~30 forks) ----
use_color=1
[[ -n "${NO_COLOR:-}" ]] && use_color=0

if [[ "$use_color" -eq 1 ]]; then
    RST=$'\033[0m'
    C_GREEN=$'\033[38;5;114m'
    C_YELLOW=$'\033[38;5;220m'
    C_RED=$'\033[38;5;203m'
    C_MODEL=$'\033[38;5;147m'
    C_GIT=$'\033[38;5;150m'
    C_USER=$'\033[01;32m'
    C_PATH=$'\033[01;34m'
    C_DIM=$'\033[38;5;240m'
    C_MUTED=$'\033[38;5;245m'
else
    RST='' C_GREEN='' C_YELLOW='' C_RED='' C_MODEL=''
    C_GIT='' C_USER='' C_PATH='' C_DIM='' C_MUTED=''
fi

# ---- Detect stat variant once ----
if stat -f %m /dev/null >/dev/null 2>&1; then
    file_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
    file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

# ---- Helper Functions ----
command_exists() { command -v "$1" >/dev/null 2>&1; }

# run_with_timeout SECS CMD...: GNU timeout, gtimeout (macOS + coreutils),
# or plain CMD on stock macOS, where Claude Code closes stdin so reads return
run_with_timeout() {
    local secs="$1"; shift
    if command_exists timeout; then
        timeout "$secs" "$@"
    elif command_exists gtimeout; then
        gtimeout "$secs" "$@"
    else
        "$@"
    fi
}

# Claude Code relocates its config dir via these env vars; the statusline inherits its env
readonly CLAUDE_CFG_DIR="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}}"
readonly CREDENTIALS_FILE="$CLAUDE_CFG_DIR/.credentials.json"

# Keychain item holding the OAuth blob on a default-config macOS install
readonly KEYCHAIN_SERVICE="Claude Code-credentials"

# Presence check only: no -w, so the secret is never read here
credentials_present() {
    [[ -f "$CREDENTIALS_FILE" ]] && return 0
    command_exists security || return 1
    # Relocated config dir salts the keychain item name with a path hash; it cannot
    # be probed by name, so abstain (treat as logged in) rather than nag falsely
    [[ -n "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-}}" ]] && return 0
    # Cache the probe: security can stall on a locked keychain, and this path runs every render that has no usage data
    local probe_cache="$BASE_CACHE_DIR/keychain_present"
    if ! is_cache_valid "$probe_cache" 60; then
        local found=0
        security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 && found=1
        write_cache_atomic "$probe_cache" "$found"
    fi
    local cached=""
    [[ -r "$probe_cache" ]] && cached=$(<"$probe_cache")
    [[ "$cached" == "1" ]]
}

# Atomic file write
write_cache_atomic() {
    local file="${1:-}" content="${2:-}"
    [[ -z "$file" ]] && return 1
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 1
    if printf '%s\n' "$content" > "$temp_file" 2>/dev/null; then
        mv -f "$temp_file" "$file" 2>/dev/null
    else
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi
}

# Periodic cleanup of stale session caches and orphaned temp files
maybe_cleanup_sessions() {
    (( RANDOM % 20 != 0 )) && return 0
    [[ -z "${BASE_CACHE_DIR:-}" ]] && return 0
    find "$BASE_CACHE_DIR" -maxdepth 1 -name 'session_*' -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null
    find "$BASE_CACHE_DIR" -maxdepth 2 -type f -mmin +60 \
        \( -name 'usage_api_shared.??????' \
        -o -name 'usage_api.fail.??????' \
        -o -name 'codex_rate_limits_shared.??????' \
        -o -name 'codex_rate_limits.fail.??????' \
        -o -name 'kimi_balance.??????' \
        -o -name 'glm_quota.??????' \
        -o -name 'grok_billing_shared.??????' \
        -o -name 'grok_billing.fail.??????' \
        -o -name 'context_*.??????' \
        -o -name 'previous_tokens.??????' \) \
        -delete 2>/dev/null
    # write_cache_atomic leaves its mktemp file behind when the script is
    # killed between mktemp and mv; the persistent cache lives in ~/.claude.
    find "${HOME}/.claude" -maxdepth 1 -type f -mmin +60 \
        -name 'usage_api_last_good.json.??????' -delete 2>/dev/null
    # Lock files are deliberately not swept: unlinking a held lock makes the
    # next opener lock a different inode, breaking mutual exclusion.
    # A render killed mid-refresh can orphan a mktemp file holding tokens
    find "${HOME}/.grok" -maxdepth 1 -name 'auth.json.??????' -type f -mmin +60 \
        -delete 2>/dev/null
}

# Cache validity check
is_cache_valid() {
    local cache_file="${1:-}" ttl="${2:-$STATUSLINE_CACHE_TTL}"
    [[ ! -f "$cache_file" ]] && return 1
    local file_age=$(( ${EPOCHSECONDS:-$(date +%s)} - $(file_mtime "$cache_file") ))
    [[ "$file_age" -lt "$ttl" ]]
}

# Read and validate input (no IFS save/restore needed - subshell isolation)
input=$(run_with_timeout 2 cat)
if ! printf '%s\n' "$input" | jq empty >/dev/null 2>&1; then
    echo "Error: Invalid JSON input" >&2
    exit 1
fi

# ---- Parse JSON input (single merged jq call) ----
if command_exists jq; then
    # join("\u001f"): unit separator (0x1F) is non-whitespace, so empty fields are
    # preserved by read (tab is IFS whitespace: consecutive tabs collapse and
    # shift every later field left)
    json_values=$(printf '%s\n' "$input" | jq -r '
        [
            (.model.display_name // "Sonnet 4"),
            (.version // "v1.0.85"),
            (.session_id // ""),
            (.workspace.current_dir // .cwd // ""),
            (.transcript_path // ""),
            (.context_window.context_window_size // ""),
            (.context_window.used_percentage // ""),
            (.context_window.current_usage.input_tokens // ""),
            (.context_window.current_usage.cache_creation_input_tokens // ""),
            (.context_window.current_usage.cache_read_input_tokens // ""),
            (.effort.level // ""),
            ((((.cost.total_cost_usd // 0) | tonumber? // 0) * 100 | round) as $k
             | if $k > 0 then "\($k / 100 | floor).\((($k % 100) + 100) | tostring[1:])" else "" end)
        ] | map(tostring) | join("\u001f")
    ' 2>/dev/null)

    if [[ -n "$json_values" ]]; then
        IFS=$'\x1f' read -r raw_model_name cc_version session_id current_dir transcript_path cw_size cw_used_pct cw_input cw_cache_create cw_cache_read effort_level cost_usd <<< "$json_values"
    else
        raw_model_name="Sonnet 4" cc_version="v1.0.85"
        session_id="" current_dir="" transcript_path="" cw_size=""
        cw_used_pct="" cw_input="" cw_cache_create="" cw_cache_read="" effort_level="" cost_usd=""
    fi
else
    raw_model_name="Sonnet 4" cc_version="v1.0.85"
    session_id="" current_dir="" transcript_path="" cw_size=""
    cw_used_pct="" cw_input="" cw_cache_create="" cw_cache_read="" effort_level="" cost_usd=""
fi

# Format model name
case "$raw_model_name" in
    *"kimi-k2"*"thinking"*|*"Kimi K2"*"Thinking"*) model_name="Kimi K2 Thinking" ;;
    *"kimi-k2.7-code"*|*"Kimi K2.7 Code"*) model_name="Kimi K2.7 Code" ;;
    *"kimi-k2.5"*|*"Kimi K2.5"*) model_name="Kimi K2.5" ;;
    *"kimi-k2"*|*"Kimi K2"*) model_name="Kimi K2" ;;
    *" context)"*)     model_name="${raw_model_name/ context/}" ;;  # (1M context) -> (1M)
    *)                  model_name="${raw_model_name}" ;;
esac

debug_log "Parsed: model=$model_name version=$cc_version cw_size=$cw_size"

# ---- Git information ----
git_branch="" git_dirty=""
if command_exists git && git rev-parse --git-dir >/dev/null 2>&1; then
    git_branch=$(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git_dirty="*"
    fi
    # Ahead/behind upstream
    git_ahead_behind=""
    # shellcheck disable=SC1083  # @{upstream} is git revision syntax; braces intended
    if ab=$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null); then
        IFS=$'\t' read -r ahead behind <<< "$ab"
        [[ "$ahead" =~ ^[0-9]+$ && "$ahead" -gt 0 ]] && git_ahead_behind+=" ↑${ahead}"
        [[ "$behind" =~ ^[0-9]+$ && "$behind" -gt 0 ]] && git_ahead_behind+=" ↓${behind}"
    fi
fi

# ---- User and path info ----
username="$(whoami 2>/dev/null || echo "user")"
hostname_short="$(hostname -s 2>/dev/null || echo "localhost")"
[[ -z "$current_dir" ]] && current_dir="$(pwd 2>/dev/null || echo "/")"

# ---- Max context detection ----
get_max_context() {
    # Lowercase once so matching never depends on how the app cases model names
    local m="${1,,}"
    case "$m" in
        # GLM (Zhipu AI): 4.5=128k, 4.6=200k, 5.2=200k (1M only via Claude Code [1m] variant)
        *"glm-4.5"*)               echo "128000" ;;
        *"glm-4."*)                echo "200000" ;;
        *"glm-5.2[1m]"*)          echo "1000000" ;;
        *"glm-5.2"*)               echo "200000" ;;
        # Kimi (Moonshot AI): K2 family shares one ~256k window
        *"kimi"*)                  echo "256000" ;;
        # Claude: Opus/Haiku=200k, Sonnet=200k or 1M, Fable promo ships as [1m]
        *"opus"*"1m"*)            echo "1000000" ;;
        *"opus"*)                  echo "200000" ;;
        *"sonnet"*"1m"*)          echo "1000000" ;;
        *"sonnet"*)               echo "200000" ;;
        *"haiku"*)                 echo "200000" ;;
        *"fable"*)                 echo "1000000" ;;
        # xAI: Grok 4.5 has a 500K context window (hyphen and space spellings).
        *"grok-4.5"*|*"grok 4.5"*) echo "500000" ;;
        *)                         echo "200000" ;;
    esac
}

known_max=$(get_max_context "$model_name")
if [[ -n "$cw_size" && "$cw_size" =~ ^[0-9]+$ && "$cw_size" -gt 0 ]]; then
    # Use the larger of reported vs known (Claude Code may underreport for non-Anthropic models)
    if (( known_max > cw_size )); then
        MAX_CONTEXT="$known_max"
    else
        MAX_CONTEXT="$cw_size"
    fi
else
    MAX_CONTEXT="$known_max"
fi

# ---- Cache system setup ----
readonly USER_ID="${UID:-$(id -u 2>/dev/null || echo $$)}"
BASE_CACHE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-statusline-${USER_ID}"

if [[ -n "${session_id:-}" && "${session_id:-}" != "null" ]]; then
    CACHE_DIR="$BASE_CACHE_DIR/session_${session_id}"
else
    if command_exists sha256sum; then
        PPID_HASH="$(printf '%s' "${PPID:-$$}" | sha256sum 2>/dev/null | cut -d' ' -f1 | head -c 8)"
    else
        PPID_HASH="${PPID:-$$}"   # per-process fallback avoids cross-process cache collisions
    fi
    [[ -z "$PPID_HASH" ]] && PPID_HASH="default"
    CACHE_DIR="$BASE_CACHE_DIR/proc_${PPID_HASH}"
fi

# chmod the shared root too: under the ${TMPDIR:-/tmp} fallback (no
# XDG_RUNTIME_DIR) it would otherwise be world-listable via umask.
mkdir -p "$BASE_CACHE_DIR" 2>/dev/null
chmod 700 "$BASE_CACHE_DIR" 2>/dev/null
mkdir -p "$CACHE_DIR" 2>/dev/null
chmod 700 "$CACHE_DIR" 2>/dev/null

# Share the session's effort with subagent-statusline.sh: its payload carries
# no effort, and agents without a pinned one run at the session's level.
if [[ -n "${session_id:-}" && "$session_id" != "null" ]]; then
    if [[ -n "$effort_level" ]]; then
        if [[ ! -f "$CACHE_DIR/effort" || "$(<"$CACHE_DIR/effort")" != "$effort_level" ]]; then
            write_cache_atomic "$CACHE_DIR/effort" "$effort_level"
        fi
    else
        # Effort left the payload: clear, or agent rows inherit a stale level.
        rm -f -- "$CACHE_DIR/effort" 2>/dev/null
    fi
fi

# ---- Progress bar with color support ----
progress_bar() {
    local pct="${1:-0}" width="${2:-$PROGRESS_BAR_WIDTH}" color="${3:-}" dim="${C_DIM}"
    [[ ! "$pct" =~ ^[0-9]+$ ]] && pct=0
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_fill="" bar_empty=""
    printf -v bar_fill '%*s' "$filled" ''
    printf -v bar_empty '%*s' "$empty" ''
    bar_fill="${bar_fill// /=}"
    bar_empty="${bar_empty// /-}"
    printf '%s%s%s%s%s' "${color}" "${bar_fill}" "${dim}" "${bar_empty}" "${RST}"
}

# Color for percentage value
pct_color() {
    local pct="${1:-0}"
    if (( pct >= 80 )); then printf '%s' "$C_RED"
    elif (( pct >= 50 )); then printf '%s' "$C_YELLOW"
    elif (( pct < 10 )); then printf '%s' "$C_DIM"
    else printf '%s' "$C_GREEN"
    fi
}

# Format countdown: seconds -> "XhYm" or "XdYh"
fmt_countdown() {
    local secs="${1:-0}"
    (( secs <= 0 )) && { printf 'now'; return; }
    local days=$(( secs / 86400 )) hours=$(( (secs % 86400) / 3600 )) mins=$(( (secs % 3600) / 60 ))
    if (( days > 0 )); then
        printf '%dd %dh' "$days" "$hours"
    elif (( hours > 0 )); then
        printf '%dh %dm' "$hours" "$mins"
    else
        printf '%dm' "$mins"
    fi
}

# ---- ISO timestamp to epoch ----
to_epoch() {
    local ts="${1:-}"
    [[ ! "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]] && return 1

    # Try GNU date first (most Linux)
    date -d "$ts" +%s 2>/dev/null && return 0
    # Try gdate (macOS with coreutils)
    command_exists gdate && { gdate -d "$ts" +%s 2>/dev/null && return 0; }
    # Try BSD date
    local clean="${ts/.000Z/Z}"
    clean="${clean/.000+/+}"
    date -u -j -f "%Y-%m-%dT%H:%M:%S%z" "${clean/Z/+0000}" +%s 2>/dev/null && return 0
    # Python fallback
    if command_exists python3; then
        python3 -c "
import sys, datetime
s=sys.argv[1].replace('Z','+00:00')
if '.' in s and '+' in s:
    dp, tp = s.rsplit('+', 1)
    if '.' in dp: dp = dp.split('.')[0]
    s = dp + '+' + tp
print(int(datetime.datetime.fromisoformat(s).timestamp()))
" "$ts" 2>/dev/null
    fi
}

# ---- OAuth Usage Fetch ----
# Fallback chain (in order):
#   1) Fresh shared cache hit (STATUSLINE_USAGE_TTL).
#   2) Recent failure marker: skip API (backoff window).
#   3) Acquire flock, double-check cache, then call OAuth API.
#      On success: write api_cache + persistent_cache, clear fail marker.
#      On failure: write fail_marker so step 2 short-circuits next run.
#   4) Stale shared cache (expired TTL but file exists).
#   5) Persistent last-good cache at ~/.claude/usage_api_last_good.json.
#   6) Manual cache at ~/.claude/usage_cache.json (read-only; never
#      propagated to api_cache to prevent poisoning).
#
# Response fields consumed: five_hour / seven_day (+ legacy seven_day_sonnet /
# seven_day_opus, which the API now sends as null), extra_usage
# {is_enabled, utilization}, and limits[] entries with kind "weekly_scoped"
# (model promos like Fable). ~/.claude/usage_cache.json remains a manual
# fallback and may use the same shape.
#
# Why not Claude Code's native stdin rate_limits fields? They only carry the
# session/weekly percentages. This OAuth response is richer: extra-usage
# credits, weekly model-scoped promo limits, and per-model legacy splits.

# Is stdin a usage payload? five_hour is null whenever the API reports no
# 5-hour window, so its truthiness cannot be the test: key presence is.
# Error bodies ({"type":"error",...}) carry none of these keys.
is_usage_response() {
    jq -e 'type == "object" and (has("five_hour") or has("seven_day")
           or ((.limits? // null) | type == "array"))' >/dev/null 2>&1
}

fetch_usage_data() {
    local api_cache="$BASE_CACHE_DIR/usage_api_shared"
    local persistent_cache="${HOME}/.claude/usage_api_last_good.json"
    local manual_cache="${HOME}/.claude/usage_cache.json"
    local lock_file="$BASE_CACHE_DIR/usage_api.lock"
    local fail_marker="$BASE_CACHE_DIR/usage_api.fail"

    # 1) Shared cache still valid? Return immediately.
    if is_cache_valid "$api_cache" "$STATUSLINE_USAGE_TTL"; then
        cat "$api_cache" 2>/dev/null
        return 0
    fi

    # 2) Recent failure? Skip API, fall through to fallbacks.
    if is_cache_valid "$fail_marker" "$STATUSLINE_USAGE_FAIL_BACKOFF"; then
        debug_log "Skipping API fetch: recent failure (backoff)"
    else
        # 3) Acquire lock (wait up to 4s). Prevents cache stampede.
        local lock_fd=""
        # Brace group scopes the 2>/dev/null: bare on exec it would silence this subshell for good
        if { exec {lock_fd}>"$lock_file"; } 2>/dev/null && [[ -n "$lock_fd" ]]; then
            # flock(1) may be absent (stock macOS): proceed unlocked rather
            # than never fetching; worst case is a duplicate curl.
            if ! command_exists flock || flock -w 4 "$lock_fd" 2>/dev/null; then
                # Won the lock. Double-checked locking: re-verify cache (another process may have just refreshed).
                if is_cache_valid "$api_cache" "$STATUSLINE_USAGE_TTL"; then
                    exec {lock_fd}>&-
                    cat "$api_cache" 2>/dev/null
                    return 0
                fi

                # Claim the backoff before the fetch: a render killed mid-fetch
                # would otherwise leave no marker and every render would stall.
                # Success removes it; a completed failure refreshes it below.
                write_cache_atomic "$fail_marker" "${EPOCHSECONDS:-$(date +%s)}"

                # Actually fetch from OAuth API
                local fetched=false
                local token=""
                if [[ -f "$CREDENTIALS_FILE" ]]; then
                    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
                fi
                # macOS: Claude Code stores OAuth creds in the Keychain, not .credentials.json
                if [[ -z "$token" ]] && command_exists security; then
                    token=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null | \
                        jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
                    [[ -z "$token" ]] && debug_log "Keychain lookup returned no token"
                fi
                if [[ -n "$token" ]]; then
                    local resp
                    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | \
                        curl -s -m 5 -K - \
                            -H "anthropic-beta: oauth-2025-04-20" \
                            -H "User-Agent: claude-code/${cc_version:-2.1.17}" \
                            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
                    if printf '%s\n' "$resp" | is_usage_response; then
                        write_cache_atomic "$api_cache" "$resp"
                        # Persist last good response (survives reboots)
                        write_cache_atomic "$persistent_cache" "$resp"
                        rm -f -- "$fail_marker" 2>/dev/null
                        fetched=true
                        exec {lock_fd}>&-
                        printf '%s\n' "$resp"
                        return 0
                    fi
                    debug_log "OAuth API returned unexpected response"
                fi

                # API failed: record failure for backoff
                if [[ "$fetched" == false ]]; then
                    write_cache_atomic "$fail_marker" "$(date +%s)"
                fi
            fi
            exec {lock_fd}>&-
        else
            debug_log "Failed to open lock file"
        fi
    fi

    # 4) Fallback: stale shared cache
    if [[ -f "$api_cache" ]]; then
        cat "$api_cache" 2>/dev/null
        return 0
    fi

    # 5) Fallback: persistent last-good cache (survives reboots)
    if [[ -f "$persistent_cache" ]]; then
        cat "$persistent_cache" 2>/dev/null
        return 0
    fi

    # 6) Fallback: manual cache file. Read-only; never written to api_cache, which would refresh its mtime and short-circuit the API fetch on every subsequent run.
    if [[ -r "$manual_cache" ]]; then
        local manual_data
        manual_data=$(<"$manual_cache")
        if printf '%s\n' "$manual_data" | is_usage_response; then
            printf '%s\n' "$manual_data"
            return 0
        fi
    fi

    return 1
}

# ---- ChatGPT/Codex Rate Limits ----
# Query Codex's supported local app-server interface so this status line uses
# the same authenticated quota snapshot as the Codex TUI. Only the sanitized
# rate-limit windows are cached; account identity and OAuth credentials never
# leave Codex's own process.

# Close the pipe and reap the whole coproc tree, bounded. $1 is the coproc
# SUBSHELL pid: codex runs beneath it (via timeout), so signal its children
# too; the server exits on stdin EOF, but its shutdown flushes telemetry over
# the network and must never hold the render hostage.
codex_reap() {
    local pid="$1" wfd="${2:-}"
    [[ -n "$wfd" ]] && { { exec {wfd}>&-; } 2>/dev/null || true; }
    [[ -n "$pid" ]] || return 0
    for _ in 1 2 3 4; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
        command_exists pkill && pkill -TERM -P "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
        sleep 0.1
        # TERM ignored (wedged server): escalate so nothing outlives the render
        if kill -0 "$pid" 2>/dev/null; then
            command_exists pkill && pkill -KILL -P "$pid" 2>/dev/null
            kill -KILL "$pid" 2>/dev/null
        fi
    fi
    wait "$pid" 2>/dev/null || true
}

fetch_codex_rate_limits_live() {
    command_exists codex || return 1

    local read_fd write_fd init_response="" line="" rate_response=""
    local codex_pid=""

    coproc CODEX_STATUS { run_with_timeout 6 codex app-server 2>/dev/null; }
    read_fd="${CODEX_STATUS[0]:-}"
    write_fd="${CODEX_STATUS[1]:-}"
    codex_pid="${CODEX_STATUS_PID:-}"
    if [[ -z "$read_fd" || -z "$write_fd" ]]; then
        codex_reap "$codex_pid" ""
        return 1
    fi

    # stderr is silenced FIRST: redirection processing stops at the first
    # failure, so a dead write fd would otherwise print a bash diagnostic.
    if ! printf '%s\n' \
        '{"method":"initialize","id":1,"params":{"clientInfo":{"name":"claude-statusline","title":"Claude Statusline","version":"1.0.0"}}}' \
        2>/dev/null 1>&"$write_fd"; then
        codex_reap "$codex_pid" "$write_fd"
        return 1
    fi

    # Ignore unrelated startup notifications and wait for initialize.
    for _ in {1..5}; do
        line=""
        IFS= read -r -t 1 -u "$read_fd" line 2>/dev/null || true
        if [[ -n "$line" ]] && [[ "$(printf '%s\n' "$line" | jq -r '.id // empty' 2>/dev/null)" == "1" ]]; then
            init_response="$line"
            break
        fi
    done

    if ! printf '%s\n' "$init_response" | jq -e '.id == 1 and .result' >/dev/null 2>&1; then
        codex_reap "$codex_pid" "$write_fd"
        debug_log "Codex app-server did not answer initialize"
        return 1
    fi

    printf '%s\n' '{"method":"initialized","params":{}}' 2>/dev/null 1>&"$write_fd" || true
    printf '%s\n' '{"method":"account/rateLimits/read","id":2,"params":{}}' 2>/dev/null 1>&"$write_fd" || true

    for _ in {1..8}; do
        line=""
        IFS= read -r -t 1 -u "$read_fd" line 2>/dev/null || true
        if [[ -n "$line" ]] && [[ "$(printf '%s\n' "$line" | jq -r '.id // empty' 2>/dev/null)" == "2" ]]; then
            rate_response="$line"
            break
        fi
    done

    codex_reap "$codex_pid" "$write_fd"

    printf '%s\n' "$rate_response" | jq -ce '
        .result.rateLimits
        | {
            primary: (if .primary then {
                usedPercent: .primary.usedPercent,
                windowDurationMins: .primary.windowDurationMins,
                resetsAt: .primary.resetsAt
            } else null end),
            secondary: (if .secondary then {
                usedPercent: .secondary.usedPercent,
                windowDurationMins: .secondary.windowDurationMins,
                resetsAt: .secondary.resetsAt
            } else null end)
        }
        | select((.primary.usedPercent? != null) or (.secondary.usedPercent? != null))
    ' 2>/dev/null
}

fetch_codex_rate_limits() {
    local cache_file="$BASE_CACHE_DIR/codex_rate_limits_shared"
    local lock_file="$BASE_CACHE_DIR/codex_rate_limits.lock"
    local fail_marker="$BASE_CACHE_DIR/codex_rate_limits.fail"
    local lock_fd="" response=""

    if is_cache_valid "$cache_file" "$STATUSLINE_CODEX_TTL"; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    if ! is_cache_valid "$fail_marker" "$STATUSLINE_CODEX_FAIL_BACKOFF"; then
        if { exec {lock_fd}>"$lock_file"; } 2>/dev/null && [[ -n "$lock_fd" ]]; then
            if ! command_exists flock || flock -w 4 "$lock_fd" 2>/dev/null; then
                if is_cache_valid "$cache_file" "$STATUSLINE_CODEX_TTL"; then
                    exec {lock_fd}>&-
                    cat "$cache_file" 2>/dev/null
                    return 0
                fi

                # Claim the backoff before the fetch: a render killed mid-fetch
                # would otherwise leave no marker and every render would stall.
                # Success removes it; a completed failure refreshes it below.
                write_cache_atomic "$fail_marker" "${EPOCHSECONDS:-$(date +%s)}"

                if response=$(fetch_codex_rate_limits_live) && [[ -n "$response" ]]; then
                    write_cache_atomic "$cache_file" "$response"
                    rm -f -- "$fail_marker" 2>/dev/null
                    exec {lock_fd}>&-
                    printf '%s\n' "$response"
                    return 0
                fi
                debug_log "Codex rate-limit fetch produced no data"

                write_cache_atomic "$fail_marker" "${EPOCHSECONDS:-$(date +%s)}"
            fi
            exec {lock_fd}>&-
        fi
    fi

    # A stale quota snapshot is preferable to hiding the meter during a brief
    # network or Codex startup failure.
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    return 1
}

# ---- Kimi (Moonshot AI) Balance Fetch ----
fetch_kimi_balance() {
    local cache_file="$CACHE_DIR/kimi_balance"

    # Check cache
    if is_cache_valid "$cache_file" "$STATUSLINE_KIMI_TTL"; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    # Require MOONSHOT_API_KEY
    local api_key="${MOONSHOT_API_KEY:-}"
    [[ -z "$api_key" ]] && return 1

    local resp
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$api_key" | \
        curl -s -m 3 -K - \
            "https://api.moonshot.cn/v1/users/me/balance" 2>/dev/null)

    if printf '%s\n' "$resp" | jq -e '.data.available_balance' >/dev/null 2>&1; then
        write_cache_atomic "$cache_file" "$resp"
        printf '%s\n' "$resp"
        return 0
    fi
    debug_log "Kimi balance API returned unexpected response"

    # Stale cache fallback
    [[ -f "$cache_file" ]] && cat "$cache_file" 2>/dev/null && return 0
    return 1
}

# ---- GLM Coding Plan Quota Fetch ----
fetch_glm_quota() {
    local cache_file="$CACHE_DIR/glm_quota"

    if is_cache_valid "$cache_file" "$STATUSLINE_GLM_TTL"; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    local auth_token="${ANTHROPIC_AUTH_TOKEN:-}"
    [[ -z "$auth_token" ]] && return 1

    # Derive monitor base URL from ANTHROPIC_BASE_URL (set by GLM Coding Plan)
    local base_url="${ANTHROPIC_BASE_URL:-https://api.z.ai/api/anthropic}"
    local monitor_url
    if [[ "$base_url" == *"open.bigmodel.cn"* ]]; then
        monitor_url="https://open.bigmodel.cn/api/monitor/usage/quota/limit"
    else
        monitor_url="https://api.z.ai/api/monitor/usage/quota/limit"
    fi

    local resp
    resp=$(printf 'header = "Authorization: %s"\n' "$auth_token" | \
        curl -s -m 3 -K - \
            "$monitor_url" 2>/dev/null)

    if printf '%s\n' "$resp" | jq -e '.data.limits' >/dev/null 2>&1; then
        write_cache_atomic "$cache_file" "$resp"
        printf '%s\n' "$resp"
        return 0
    fi
    debug_log "GLM quota API returned unexpected response"

    [[ -f "$cache_file" ]] && cat "$cache_file" 2>/dev/null && return 0
    return 1
}

# ---- Grok (xAI) SuperGrok weekly credit usage ----
# Auth: ~/.grok/auth.json OIDC entry (key = access token).
# Weekly window: GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
# Renders config.creditUsagePercent + config.currentPeriod.end only.

grok_auth_path() {
    printf '%s' "${HOME}/.grok/auth.json"
}

# Print: access_token \x1f auth_entry_key \x1f refresh_token \x1f client_id \x1f expires_at
# Prefers https://auth.x.ai:: entries; falls back to the first object entry.
grok_read_auth_fields() {
    local auth_file
    auth_file=$(grok_auth_path)
    [[ -f "$auth_file" ]] || return 1
    command_exists jq || return 1

    jq -r '
        def pick:
            to_entries
            | (map(select(.key | startswith("https://auth.x.ai::"))) | .[0])
              // .[0]
            | select(. != null);
        pick
        | [
            (.value.key // .value.access_token // ""),
            .key,
            (.value.refresh_token // ""),
            (.value.oidc_client_id // .value.client_id // ""),
            (.value.expires_at // "")
          ]
        | map(tostring)
        | join("\u001f")
    ' "$auth_file" 2>/dev/null
}

# True (exit 0) when token is missing or expires within 120s.
# Uses the later of file expires_at and JWT exp so a stale expires_at
# cannot force a refresh while the access token is still valid.
grok_token_needs_refresh() {
    local token="${1:-}" expires_at="${2:-}"
    [[ -z "$token" ]] && return 0

    local now_epoch file_exp="" jwt_exp="" exp_epoch=""
    now_epoch=${EPOCHSECONDS:-$(date +%s)}

    if [[ -n "$expires_at" ]]; then
        file_exp=$(to_epoch "$expires_at" 2>/dev/null || true)
    fi

    if command_exists python3; then
        jwt_exp=$(TOKEN="$token" python3 - <<'PY' 2>/dev/null
import base64, json, os, sys
tok = os.environ.get("TOKEN", "")
parts = tok.split(".")
if len(parts) < 2:
    sys.exit(1)
pad = "=" * ((4 - len(parts[1]) % 4) % 4)
try:
    payload = json.loads(base64.urlsafe_b64decode(parts[1] + pad))
except Exception:
    sys.exit(1)
exp = payload.get("exp")
if exp is None:
    sys.exit(1)
print(int(exp))
PY
) || jwt_exp=""
    fi

    if [[ "$file_exp" =~ ^[0-9]+$ && "$jwt_exp" =~ ^[0-9]+$ ]]; then
        if (( jwt_exp > file_exp )); then exp_epoch=$jwt_exp; else exp_epoch=$file_exp; fi
    elif [[ "$jwt_exp" =~ ^[0-9]+$ ]]; then
        exp_epoch=$jwt_exp
    elif [[ "$file_exp" =~ ^[0-9]+$ ]]; then
        exp_epoch=$file_exp
    else
        return 0
    fi

    (( exp_epoch - now_epoch <= 120 ))
}

# Refresh OIDC access token; write back to ~/.grok/auth.json under flock.
# Prints the fresh access token on success.
grok_refresh_access_token() {
    local auth_file lock_file lock_fd=""
    auth_file=$(grok_auth_path)
    [[ -f "$auth_file" ]] || return 1
    command_exists jq || return 1

    # Refresh only under a real lock: concurrent renders re-sending the same
    # refresh token trip the IdP's reuse detection and can revoke the whole
    # token family, signing the Grok CLI out. No flock -> no refresh.
    if ! command_exists flock; then
        debug_log "Grok auth: flock unavailable; skipping refresh"
        return 1
    fi

    lock_file="${BASE_CACHE_DIR}/grok_auth.lock"
    mkdir -p "$BASE_CACHE_DIR" 2>/dev/null

    if ! { exec {lock_fd}>"$lock_file"; } 2>/dev/null || [[ -z "$lock_fd" ]]; then
        debug_log "Grok auth: failed to open lock"
        return 1
    fi

    if ! flock -w 6 "$lock_fd" 2>/dev/null; then
        exec {lock_fd}>&-
        debug_log "Grok auth: flock timeout"
        return 1
    fi

    # Re-read under lock; another process (or grok CLI) may have refreshed.
    local fields token entry_key refresh_token client_id expires_at
    fields=$(grok_read_auth_fields 2>/dev/null) || fields=""
    if [[ -z "$fields" ]]; then
        exec {lock_fd}>&-
        return 1
    fi
    IFS=$'\x1f' read -r token entry_key refresh_token client_id expires_at <<< "$fields"

    if [[ -n "$token" ]] && ! grok_token_needs_refresh "$token" "$expires_at"; then
        exec {lock_fd}>&-
        printf '%s\n' "$token"
        return 0
    fi

    if [[ -z "$refresh_token" || -z "$client_id" || -z "$entry_key" ]]; then
        exec {lock_fd}>&-
        debug_log "Grok auth: missing refresh_token/client_id (API-key auth?)"
        return 1
    fi

    # Tokens feed a quoted curl-config string: refuse anything outside the
    # OAuth token alphabet rather than risk config injection.
    if [[ ! "$refresh_token" =~ ^[A-Za-z0-9._~+/=-]+$ || ! "$client_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
        exec {lock_fd}>&-
        debug_log "Grok auth: refresh_token/client_id failed charset check"
        return 1
    fi

    # POST body goes through the stdin config (-K -), never argv: argv is
    # world-readable in ps and would expose the refresh token.
    local resp http_code
    resp=$(
        printf 'data-urlencode = "grant_type=refresh_token"\ndata-urlencode = "refresh_token=%s"\ndata-urlencode = "client_id=%s"\n' \
            "$refresh_token" "$client_id" | \
        curl -s -m 8 -w '\n%{http_code}' -K - \
            -X POST "https://auth.x.ai/oauth2/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -H "Accept: application/json" \
            2>/dev/null
    ) || resp=""

    http_code="${resp##*$'\n'}"
    resp="${resp%$'\n'*}"

    # invalid_grant: CLI may have rotated RT; re-read once and use that token if fresh.
    if [[ "$http_code" != "200" ]] || ! printf '%s\n' "$resp" | jq -e '.access_token' >/dev/null 2>&1; then
        debug_log "Grok auth: refresh HTTP ${http_code:-?} failed; re-reading auth"
        fields=$(grok_read_auth_fields 2>/dev/null) || fields=""
        if [[ -n "$fields" ]]; then
            IFS=$'\x1f' read -r token entry_key refresh_token client_id expires_at <<< "$fields"
            if [[ -n "$token" ]] && ! grok_token_needs_refresh "$token" "$expires_at"; then
                exec {lock_fd}>&-
                printf '%s\n' "$token"
                return 0
            fi
        fi
        exec {lock_fd}>&-
        return 1
    fi

    local new_access new_refresh expires_in new_expires_at updated
    new_access=$(printf '%s\n' "$resp" | jq -r '.access_token // empty' 2>/dev/null)
    new_refresh=$(printf '%s\n' "$resp" | jq -r '.refresh_token // empty' 2>/dev/null)
    expires_in=$(printf '%s\n' "$resp" | jq -r '.expires_in // empty' 2>/dev/null)
    [[ -n "$new_access" ]] || { exec {lock_fd}>&-; return 1; }
    [[ -z "$new_refresh" ]] && new_refresh="$refresh_token"

    if [[ "$expires_in" =~ ^[0-9]+$ ]]; then
        new_expires_at=$(date -u -d "+${expires_in} seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
            || date -u -v+"${expires_in}"S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
            || python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=int('${expires_in}'))).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null \
            || true)
    else
        new_expires_at=""
    fi

    # Preserve all entries/fields; update only the matched OIDC entry.
    updated=$(
        jq --arg k "$entry_key" --arg at "$new_access" --arg rt "$new_refresh" --arg exp "$new_expires_at" '
            if has($k) then
                .[$k].key = $at
                | (if $rt != "" then .[$k].refresh_token = $rt else . end)
                | (if $exp != "" then .[$k].expires_at = $exp else . end)
            else
                .
            end
        ' "$auth_file" 2>/dev/null
    ) || updated=""

    if [[ -z "$updated" ]] || ! printf '%s\n' "$updated" | jq -e --arg k "$entry_key" '.[$k].key' >/dev/null 2>&1; then
        exec {lock_fd}>&-
        debug_log "Grok auth: jq update failed"
        return 1
    fi

    local temp_file
    temp_file=$(mktemp "${auth_file}.XXXXXX" 2>/dev/null) || { exec {lock_fd}>&-; return 1; }
    if printf '%s\n' "$updated" > "$temp_file" 2>/dev/null; then
        chmod 600 "$temp_file" 2>/dev/null
        if mv -f "$temp_file" "$auth_file" 2>/dev/null; then
            chmod 600 "$auth_file" 2>/dev/null
            exec {lock_fd}>&-
            debug_log "Grok auth: refreshed access token (len=${#new_access})"
            printf '%s\n' "$new_access"
            return 0
        fi
    fi
    rm -f "$temp_file" 2>/dev/null
    exec {lock_fd}>&-
    debug_log "Grok auth: atomic write failed"
    return 1
}

# Live billing call. Prints sanitized JSON:
# {creditUsagePercent, periodEnd, periodType}
# Exit 2 = auth failure (caller may refresh+retry). Exit 1 = other failure.
grok_fetch_billing_live() {
    local token="${1:-}"
    [[ -n "$token" ]] || return 1

    local resp http_code
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | \
        curl -s -m 5 -K - -w '\n%{http_code}' \
            -H "Accept: application/json" \
            -H "User-Agent: claude-statusline/grok" \
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits" 2>/dev/null) || return 1

    http_code="${resp##*$'\n'}"
    resp="${resp%$'\n'*}"

    if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        return 2
    fi

    # Accept when period end is present; percent may be absent early in a fresh window.
    if ! printf '%s\n' "$resp" | jq -e '
        .config
        | (.creditUsagePercent != null) or (.currentPeriod.end != null)
    ' >/dev/null 2>&1; then
        if printf '%s\n' "$resp" | jq -e '
            (.error? != null) or (.message? | type == "string" and test("unauthor|auth|token"; "i"))
        ' >/dev/null 2>&1; then
            return 2
        fi
        if ! printf '%s\n' "$resp" | jq -e '.config' >/dev/null 2>&1; then
            # Non-JSON / empty body with non-2xx: treat as auth-ish for one retry
            if [[ ! "$http_code" =~ ^2 ]]; then
                return 2
            fi
            return 1
        fi
        return 1
    fi

    printf '%s\n' "$resp" | jq -c '
        .config
        | {
            creditUsagePercent: (.creditUsagePercent // 0),
            periodEnd: (.currentPeriod.end // .billingPeriodEnd // null),
            periodType: (.currentPeriod.type // null)
          }
    ' 2>/dev/null
}

fetch_grok_weekly_usage() {
    local cache_file="$BASE_CACHE_DIR/grok_billing_shared"
    local lock_file="$BASE_CACHE_DIR/grok_billing.lock"
    local fail_marker="$BASE_CACHE_DIR/grok_billing.fail"
    local lock_fd="" response="" token="" fields expires_at

    if is_cache_valid "$cache_file" "$STATUSLINE_GROK_TTL"; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    if ! is_cache_valid "$fail_marker" "$STATUSLINE_GROK_FAIL_BACKOFF"; then
        if { exec {lock_fd}>"$lock_file"; } 2>/dev/null && [[ -n "$lock_fd" ]]; then
            if ! command_exists flock || flock -w 4 "$lock_fd" 2>/dev/null; then
                if is_cache_valid "$cache_file" "$STATUSLINE_GROK_TTL"; then
                    exec {lock_fd}>&-
                    cat "$cache_file" 2>/dev/null
                    return 0
                fi

                # Claim the backoff before the fetch: a render killed mid-fetch
                # (refresh + billing can take seconds on a dead network) would
                # otherwise leave no marker and every render would stall again.
                # Success removes it; a completed failure refreshes it below.
                write_cache_atomic "$fail_marker" "${EPOCHSECONDS:-$(date +%s)}"

                fields=$(grok_read_auth_fields 2>/dev/null) || fields=""
                if [[ -n "$fields" ]]; then
                    IFS=$'\x1f' read -r token _ _ _ expires_at <<< "$fields"
                else
                    token=""
                fi

                # Prefer a refreshed token, but never discard a still-present
                # access token when refresh fails (revoked RT, offline, etc.).
                if [[ -z "$token" ]] || grok_token_needs_refresh "$token" "${expires_at:-}"; then
                    local refreshed=""
                    refreshed=$(grok_refresh_access_token) || refreshed=""
                    if [[ -n "$refreshed" ]]; then
                        token="$refreshed"
                    elif [[ -z "$token" ]]; then
                        debug_log "Grok billing: refresh failed and no access token"
                    else
                        debug_log "Grok billing: refresh failed; trying existing access token"
                    fi
                fi

                if [[ -n "$token" ]]; then
                    local rc=0
                    response=$(grok_fetch_billing_live "$token") || rc=$?
                    # One refresh+retry on auth failure; keep old token if refresh fails
                    if [[ "$rc" -eq 2 ]]; then
                        debug_log "Grok billing: auth failure, refreshing once"
                        local refreshed=""
                        refreshed=$(grok_refresh_access_token) || refreshed=""
                        if [[ -n "$refreshed" ]]; then
                            token="$refreshed"
                            rc=0
                            response=$(grok_fetch_billing_live "$token") || rc=$?
                        fi
                    fi

                    if [[ "$rc" -eq 0 && -n "$response" ]]; then
                        write_cache_atomic "$cache_file" "$response"
                        rm -f -- "$fail_marker" 2>/dev/null
                        exec {lock_fd}>&-
                        printf '%s\n' "$response"
                        return 0
                    fi
                else
                    debug_log "Grok billing: no access token available"
                fi

                write_cache_atomic "$fail_marker" "${EPOCHSECONDS:-$(date +%s)}"
            fi
            exec {lock_fd}>&-
        fi
    else
        debug_log "Grok billing: skipping fetch (fail backoff)"
    fi

    # Stale snapshot preferred over hiding the meter.
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    return 1
}

# Build a single usage metric segment: emoji + pct + bar + countdown
# Args: emoji utilization_pct resets_at_epoch [countdown_mode: time_only|no_reset_time]
build_usage_segment() {
    local emoji="$1" pct_val="$2" reset_epoch="$3"
    local now_epoch
    now_epoch=${EPOCHSECONDS:-$(date +%s)}

    # Round float to int
    local pct_int="${pct_val%.*}"
    [[ -z "$pct_int" || ! "$pct_int" =~ ^[0-9]+$ ]] && pct_int=0

    local color
    color=$(pct_color "$pct_int")
    local bar
    bar=$(progress_bar "$pct_int" 10 "$color")

    local countdown="" skip_countdown="${4:-}"
    if [[ -n "$reset_epoch" && "$reset_epoch" =~ ^[0-9]+$ ]]; then
        local remaining=$(( reset_epoch - now_epoch ))
        local reset_time
        reset_time=$(date -d "@$reset_epoch" +%H:%M 2>/dev/null || date -r "$reset_epoch" +%H:%M 2>/dev/null || echo "??:??")
        if [[ "$skip_countdown" == "time_only" ]]; then
            countdown="${C_MUTED} → ${reset_time}${RST}"
        elif [[ "$skip_countdown" == "no_reset_time" ]]; then
            countdown="${C_MUTED}$(fmt_countdown "$remaining")${RST}"
        else
            countdown="${C_MUTED}$(fmt_countdown "$remaining") → ${reset_time}${RST}"
        fi
    fi

    printf '%s %s%d%%%s[%s]%s' "$emoji" "$color" "$pct_int" "$RST" "$bar" "$countdown"
}

# Anthropic limits only. A resets_at in the past means that window already
# rolled over: the percentage that came with it belongs to the old window, so
# draw 0% and no countdown instead of a frozen number next to "now". Other
# providers go straight to build_usage_segment and keep their own semantics.
build_anthropic_segment() {
    local emoji="$1" pct_val="$2" reset_epoch="${3:-}"
    if [[ "$reset_epoch" =~ ^[0-9]+$ ]] && (( reset_epoch <= ${EPOCHSECONDS:-$(date +%s)} )); then
        pct_val=0
        reset_epoch=""
    fi
    build_usage_segment "$emoji" "$pct_val" "$reset_epoch" "${4:-}"
}

# Codex's app-server returns percentage used. Render that utilization through
# the shared bar builder so OpenAI limits have the same semantics and visual
# treatment as Claude/GLM limits (higher usage means a fuller, warmer bar).
build_codex_limit_segment() {
    local used_val="$1" duration_mins="$2" reset_epoch="$3"
    local used_int="${used_val%.*}"
    [[ -z "$used_int" || ! "$used_int" =~ ^[0-9]+$ ]] && return 1

    # resetsAt is a UNIX epoch today; tolerate null and a future ISO shape
    if [[ ! "$reset_epoch" =~ ^[0-9]+$ ]]; then
        if [[ -n "$reset_epoch" && "$reset_epoch" != "null" ]]; then
            reset_epoch=$(to_epoch "$reset_epoch" 2>/dev/null) || reset_epoch=""
        else
            reset_epoch=""
        fi
    fi
    (( used_int > 100 )) && used_int=100

    local emoji skip_countdown
    duration_mins="${duration_mins%.*}"   # tolerate a float-shaped duration
    case "$duration_mins" in
        # Match the icons and reset formatting of Claude's equivalent windows.
        300)
            emoji="⚡"
            skip_countdown=""
            ;;
        10080)
            emoji="📅"
            skip_countdown="no_reset_time"
            ;;
        *)
            emoji="⏳"
            skip_countdown="no_reset_time"
            ;;
    esac

    build_usage_segment "$emoji" "$used_int" "$reset_epoch" "$skip_countdown"
}

# ---- Detect model provider ----
is_anthropic_model=false
is_glm_model=false
model_lc="${model_name,,}"
case "$model_lc" in
    *"opus"*|*"sonnet"*|*"haiku"*|*"fable"*|*"claude"*) is_anthropic_model=true ;;
    *"glm-"*) is_glm_model=true ;;
esac

is_kimi_model=false
case "$model_lc" in
    *"kimi"*) is_kimi_model=true ;;
esac

is_openai_model=false
case "$model_lc" in
    # gpt-oss is self-hosted: no ChatGPT/Codex quota applies
    *"gpt-oss"*) ;;
    *"gpt-"*|*"gpt "*|*"chatgpt"*|*"codex"*|*"openai"*) is_openai_model=true ;;
esac

is_grok_model=false
case "$model_lc" in
    *"grok"*) is_grok_model=true ;;
esac

# ---- Parse usage data and build line 1 ----
declare -a line1_parts=()
usage_data=""
if [[ "$is_anthropic_model" == true ]] && usage_data=$(fetch_usage_data) && [[ -n "$usage_data" ]]; then
    debug_log "Got usage data"

    # Parse all metrics in a single jq call
    # The flat five_hour / seven_day keys and the structured limits[] entries
    # (kind "session" / "weekly_all") carry the same numbers. Either can be
    # null or missing depending on what the API reports for the account, so
    # each window is read from the flat key first, then from limits[].
    usage_parsed=$(printf '%s\n' "$usage_data" | jq -r '
        ([.limits[]? | select(.kind == "session")][0]) as $s
        | ([.limits[]? | select(.kind == "weekly_all")][0]) as $w
        | (.five_hour.utilization // $s.percent // "null"),
        (.five_hour.resets_at // $s.resets_at // "null"),
        (.seven_day.utilization // $w.percent // "null"),
        (.seven_day.resets_at // $w.resets_at // "null"),
        (.seven_day_sonnet.utilization // "null"),
        (.seven_day_sonnet.resets_at // "null"),
        (.seven_day_opus.utilization // "null"),
        (.seven_day_opus.resets_at // "null"),
        (.extra_usage.is_enabled // "null"),
        (.extra_usage.utilization // "null")
    ' 2>/dev/null | tr '\n' '\t')

    ex_enabled="null" ex_pct="null"
    if [[ -n "$usage_parsed" ]]; then
        IFS=$'\t' read -r u5h_pct u5h_reset u7d_pct u7d_reset u7ds_pct u7ds_reset u7do_pct u7do_reset ex_enabled ex_pct <<< "$usage_parsed"

        # 5-hour utilization
        if [[ "$u5h_pct" != "null" && -n "$u5h_pct" ]]; then
            reset_epoch=""
            if [[ "$u5h_reset" != "null" ]]; then
                reset_epoch=$(to_epoch "$u5h_reset" 2>/dev/null)
            fi
            line1_parts+=("$(build_anthropic_segment "⚡" "$u5h_pct" "$reset_epoch")")
        fi
        # No 5-hour window in the response (neither five_hour nor a session
        # entry in limits[]): the segment is hidden rather than drawn as 0%,
        # and comes back by itself when the API reports the window again.

        # 7-day all models
        if [[ "$u7d_pct" != "null" && -n "$u7d_pct" ]]; then
            u7d_epoch=""
            [[ "$u7d_reset" != "null" ]] && u7d_epoch=$(to_epoch "$u7d_reset" 2>/dev/null)
            line1_parts+=("$(build_anthropic_segment "📅" "$u7d_pct" "$u7d_epoch" "no_reset_time")")
        fi

        # 7-day Sonnet (only if non-null)
        if [[ "$u7ds_pct" != "null" && -n "$u7ds_pct" ]]; then
            u7ds_epoch=""
            [[ "$u7ds_reset" != "null" ]] && u7ds_epoch=$(to_epoch "$u7ds_reset" 2>/dev/null)
            line1_parts+=("$(build_anthropic_segment "🎵" "$u7ds_pct" "$u7ds_epoch" "no_reset_time")")
        fi

        # 7-day Opus (only if non-null)
        if [[ "$u7do_pct" != "null" && -n "$u7do_pct" ]]; then
            reset_epoch=""
            if [[ "$u7do_reset" != "null" ]]; then
                reset_epoch=$(to_epoch "$u7do_reset" 2>/dev/null)
            fi
            line1_parts+=("$(build_anthropic_segment "🎭" "$u7do_pct" "$reset_epoch")")
        fi
    fi

    # Weekly model-scoped limits (structured .limits[] array; e.g. the Fable
    # promo). These replaced the flat seven_day_sonnet-style keys, which the
    # API now sends as null. Emoji only, no model name (kept short by choice).
    while IFS=$'\x1f' read -r scoped_pct scoped_reset; do
        [[ -z "$scoped_pct" || "$scoped_pct" == "null" ]] && continue
        scoped_epoch=""
        [[ "$scoped_reset" != "null" ]] && scoped_epoch=$(to_epoch "$scoped_reset" 2>/dev/null)
        line1_parts+=("$(build_anthropic_segment "📖" "$scoped_pct" "$scoped_epoch" "no_reset_time")")
    done < <(printf '%s\n' "$usage_data" | jq -r '
        .limits[]? | select(.kind == "weekly_scoped")
        | [(.percent // "null"), (.resets_at // "null")]
        | map(tostring) | join("\u001f")
    ' 2>/dev/null)

    # Extra usage (pay-per-use credits past plan limits): self-hiding - only
    # rendered when enabled AND utilization reached 1%, to keep the line short.
    if [[ "$ex_enabled" == "true" && "$ex_pct" != "null" && -n "$ex_pct" ]]; then
        ex_int="${ex_pct%%.*}"
        [[ "$ex_int" =~ ^[0-9]+$ ]] || ex_int=0
        if (( ex_int > 0 )); then
            line1_parts+=("$(build_usage_segment "💳" "$ex_pct" "")")
        fi
    fi

    # Stale marker: same source order as the fetch_usage_data fallbacks. A
    # healthy run serves a cache younger than the TTL; anything much older
    # means the API fetch keeps failing and these numbers are a snapshot.
    usage_src=""
    for f in "$BASE_CACHE_DIR/usage_api_shared" \
             "${HOME}/.claude/usage_api_last_good.json" \
             "${HOME}/.claude/usage_cache.json"; do
        [[ -f "$f" ]] && { usage_src="$f"; break; }
    done
    if [[ -n "$usage_src" ]]; then
        usage_age=$(( ${EPOCHSECONDS:-$(date +%s)} - $(file_mtime "$usage_src") ))
        if (( usage_age > STATUSLINE_USAGE_TTL + STATUSLINE_USAGE_FAIL_BACKOFF + 300 )); then
            line1_parts+=("${C_YELLOW}⚠ $(fmt_countdown "$usage_age") old${RST}")
        fi
    fi
fi

# ChatGPT/Codex quota windows for OpenAI models. Codex may expose the weekly
# window as either primary or secondary depending on the account plan, so
# label each entry from its actual duration rather than assuming an order.
if [[ "$is_openai_model" == true ]]; then
    codex_limits=""
    if codex_limits=$(fetch_codex_rate_limits) && [[ -n "$codex_limits" ]]; then
        while IFS=$'\x1f' read -r used_pct duration_mins reset_epoch; do
            [[ -z "$used_pct" || "$used_pct" == "null" ]] && continue
            segment=$(build_codex_limit_segment "$used_pct" "$duration_mins" "$reset_epoch" 2>/dev/null) || segment=""
            [[ -n "$segment" ]] && line1_parts+=("$segment")
        done < <(printf '%s\n' "$codex_limits" | jq -r '
            [.primary, .secondary][]
            | select(.usedPercent != null)
            | [(.usedPercent // "null"), (.windowDurationMins // "null"), (.resetsAt // "null")]
            | map(tostring) | join("\u001f")
        ' 2>/dev/null)
    fi
fi

# Grok SuperGrok weekly credit usage (only when the active model is Grok).
# Self-hide when the Grok CLI has never logged in here (no auth file), matching
# the Codex gate; keep the N/A marker when auth exists but the fetch fails.
if [[ "$is_grok_model" == true && -r "$(grok_auth_path)" ]]; then
    grok_data=""
    if grok_data=$(fetch_grok_weekly_usage) && [[ -n "$grok_data" ]]; then
        grok_parsed=$(printf '%s\n' "$grok_data" | jq -r '
            [(.creditUsagePercent // "null"), (.periodEnd // "null")]
            | map(tostring) | join("\u001f")
        ' 2>/dev/null)
        if [[ -n "$grok_parsed" ]]; then
            IFS=$'\x1f' read -r grok_pct grok_period_end <<< "$grok_parsed"
            if [[ "$grok_pct" != "null" && -n "$grok_pct" ]]; then
                grok_epoch=""
                if [[ "$grok_period_end" != "null" && -n "$grok_period_end" ]]; then
                    grok_epoch=$(to_epoch "$grok_period_end" 2>/dev/null)
                fi
                line1_parts+=("$(build_usage_segment "📅" "$grok_pct" "$grok_epoch" "no_reset_time")")
            else
                line1_parts+=("${C_DIM}📅 Grok N/A${RST}")
            fi
        else
            line1_parts+=("${C_DIM}📅 Grok N/A${RST}")
        fi
    else
        line1_parts+=("${C_DIM}📅 Grok N/A${RST}")
    fi
fi

# Kimi balance (only when using Kimi model)
if [[ "$is_kimi_model" == true && -n "${MOONSHOT_API_KEY:-}" ]]; then
    kimi_data=""
    if kimi_data=$(fetch_kimi_balance) && [[ -n "$kimi_data" ]]; then
        kimi_balance=$(printf '%s\n' "$kimi_data" | jq -r '.data.available_balance // empty' 2>/dev/null)
        if [[ -n "$kimi_balance" ]]; then
            line1_parts+=("${C_MUTED}💰 ¥${kimi_balance}${RST}")
        fi
    fi
fi

# GLM Coding Plan quota (if GLM model active)
if [[ "$is_glm_model" == true && -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    glm_data=""
    if glm_data=$(fetch_glm_quota) && [[ -n "$glm_data" ]]; then
        glm_parsed=$(printf '%s\n' "$glm_data" | jq -r '
            (.data.limits[] | select(.type == "TOKENS_LIMIT") | .percentage // "null"),
            (.data.limits[] | select(.type == "TOKENS_LIMIT") | .nextResetTime // "null"),
            (.data.limits[] | select(.type == "TOKENS_LIMIT") | .unit // "null"),
            (.data.limits[] | select(.type == "TOKENS_LIMIT") | .number // "null")
        ' 2>/dev/null | tr '\n' '\t')
        if [[ -n "$glm_parsed" ]]; then
            IFS=$'\t' read -r glm_tokens_pct glm_reset_ms glm_unit glm_number <<< "$glm_parsed"
            # percentage is already 0-100 scale
            if [[ "$glm_tokens_pct" != "null" && -n "$glm_tokens_pct" ]]; then
                glm_tokens_int="${glm_tokens_pct%.*}"
                [[ ! "$glm_tokens_int" =~ ^[0-9]+$ ]] && glm_tokens_int=0
                glm_color=$(pct_color "$glm_tokens_int")
                glm_bar=$(progress_bar "$glm_tokens_int" 10 "$glm_color")
                # Convert nextResetTime (epoch millis) to countdown
                glm_countdown=""
                if [[ "$glm_reset_ms" != "null" && "$glm_reset_ms" =~ ^[0-9]+$ ]]; then
                    glm_reset_epoch=$(( glm_reset_ms / 1000 ))
                    glm_remaining=$(( glm_reset_epoch - ${EPOCHSECONDS:-$(date +%s)} ))
                    (( glm_remaining > 0 )) && glm_countdown="${C_MUTED}$(fmt_countdown "$glm_remaining")${RST}"
                elif [[ "$glm_unit" =~ ^[0-9]+$ && "$glm_number" =~ ^[0-9]+$ ]]; then
                    # No active reset: show window duration (unit: 3=hours, number: 5 gives "5h").
                    # unit: 1=minutes, 2=days, 3=hours, 4=weeks, 5=months
                    case "$glm_unit" in
                        1) glm_countdown="${C_MUTED}${glm_number}m window${RST}" ;;
                        3) glm_countdown="${C_MUTED}${glm_number}h window${RST}" ;;
                        2) glm_countdown="${C_MUTED}${glm_number}d window${RST}" ;;
                        *) glm_countdown="" ;;
                    esac
                fi
                line1_parts+=("$(printf '⚡ %s%d%%%s[%s]%s' "$glm_color" "$glm_tokens_int" "$RST" "$glm_bar" "$glm_countdown")")
            fi
        fi
    fi
fi

# If no usage data available, show actionable hint (only for Anthropic models)
if [[ "$is_anthropic_model" == true && ${#line1_parts[@]} -eq 0 ]]; then
    if ! credentials_present; then
        line1_parts+=("${C_DIM}⚡ run 'claude login' for usage stats${RST}")
    else
        line1_parts+=("${C_DIM}⚡ N/A  📅 N/A${RST}")
    fi
fi

# ---- Context calculation ----
context_found=false
context_pct="" context_tokens="" context_delta=""

# Load previous state
previous_tokens=""
cached_delta=""
[[ -f "$CACHE_DIR/previous_tokens" ]] && previous_tokens=$(<"$CACHE_DIR/previous_tokens")
[[ -f "$CACHE_DIR/context_delta" ]] && cached_delta=$(<"$CACHE_DIR/context_delta")

# Calculate context delta
calculate_context_delta() {
    local current="${1:-0}" previous="${2:-}"
    [[ -z "$previous" || ! "$previous" =~ ^[0-9]+$ ]] && return
    local delta=$((current - previous))
    if [[ $delta -lt 0 ]] && [[ $((-delta)) -gt $((previous / 2)) ]]; then
        printf ' (cleared)'
    elif [[ $delta -gt 0 ]]; then
        local dk=$((delta / 1000))
        if [[ $dk -gt 0 ]]; then printf ' (+%dk)' "$dk"
        else printf ' (+%d)' "$delta"
        fi
    elif [[ $delta -lt 0 ]]; then
        local dk=$(((-delta) / 1000))
        if [[ $dk -gt 0 ]]; then printf ' (-%dk)' "$dk"
        else printf ' (%d)' "$delta"
        fi
    fi
}

# Primary: context_window.used_percentage from Claude Code (works for all models)
cw_used_pct="${cw_used_pct%%.*}"   # tolerate float percentages (17.4 -> 17)
if [[ -n "$cw_used_pct" && "$cw_used_pct" =~ ^[0-9]+$ ]]; then
    # Guard: if used_percentage drops to 0 but we had non-zero tokens before,
    # this is likely a transient reset between API calls; keep cached values
    if (( cw_used_pct == 0 )) && [[ -n "$previous_tokens" && "$previous_tokens" =~ ^[0-9]+$ && "$previous_tokens" -gt 0 ]]; then
        debug_log "Ignoring transient used_percentage=0 (previous=$previous_tokens)"
    else

    context_pct="$cw_used_pct"

    # Calculate total tokens from current_usage fields
    ci=${cw_input:-0}; cc=${cw_cache_create:-0}; cr=${cw_cache_read:-0}
    [[ ! "$ci" =~ ^[0-9]+$ ]] && ci=0
    [[ ! "$cc" =~ ^[0-9]+$ ]] && cc=0
    [[ ! "$cr" =~ ^[0-9]+$ ]] && cr=0
    total=$(( ci + cc + cr ))

    # If current_usage tokens are 0 but we have a percentage, derive tokens from pct
    if (( total == 0 && context_pct > 0 )); then
        total=$(( MAX_CONTEXT * context_pct / 100 ))
    fi

    context_tokens="$total"
    context_found=true

    if [[ "$total" != "$previous_tokens" ]]; then
        context_delta=$(calculate_context_delta "$total" "$previous_tokens")
        write_cache_atomic "$CACHE_DIR/previous_tokens" "$total"
        write_cache_atomic "$CACHE_DIR/context_delta" "$context_delta"
    else
        context_delta="$cached_delta"
    fi

    write_cache_atomic "$CACHE_DIR/context_pct" "$context_pct"
    write_cache_atomic "$CACHE_DIR/context_tokens" "$context_tokens"
    write_cache_atomic "$CACHE_DIR/context_found" "true"

    fi # end transient-zero guard
fi

# Fallback: Transcript parsing (for older Claude Code versions without used_percentage)
if [[ "$context_found" == false ]] && command_exists jq && [[ -n "${transcript_path:-}" && -f "${transcript_path:-}" ]]; then
    latest_usage=$(tail -"$TRANSCRIPT_TAIL_LINES" "$transcript_path" | jq -c 'select(.message.usage) | .message.usage' 2>/dev/null | tail -1)

    if [[ -n "$latest_usage" && "$latest_usage" != "null" ]]; then
        token_values=$(printf '%s\n' "$latest_usage" | jq -r '
            .input_tokens // 0,
            .cache_creation_input_tokens // 0,
            .cache_read_input_tokens // 0
        ' 2>/dev/null | tr '\n' '\t')

        if [[ -n "$token_values" ]]; then
            IFS=$'\t' read -r input_tokens cache_creation cache_read <<< "$token_values"
        else
            input_tokens=0 cache_creation=0 cache_read=0
        fi

        if [[ "$input_tokens" =~ ^[0-9]+$ && "$cache_creation" =~ ^[0-9]+$ && "$cache_read" =~ ^[0-9]+$ ]]; then
            total=$(( input_tokens + cache_creation + cache_read ))

            if (( total > 0 && total <= MAX_CONTEXT )); then
                context_pct=$(( total * 100 / MAX_CONTEXT ))
                context_tokens="$total"
                context_found=true

                if [[ "$total" != "$previous_tokens" ]]; then
                    context_delta=$(calculate_context_delta "$total" "$previous_tokens")
                    write_cache_atomic "$CACHE_DIR/previous_tokens" "$total"
                    write_cache_atomic "$CACHE_DIR/context_delta" "$context_delta"
                else
                    context_delta="$cached_delta"
                fi

                write_cache_atomic "$CACHE_DIR/context_pct" "$context_pct"
                write_cache_atomic "$CACHE_DIR/context_tokens" "$context_tokens"
                write_cache_atomic "$CACHE_DIR/context_found" "true"
            fi
        fi
    fi
fi

# Fallback: Cached values
if [[ "$context_found" == false ]]; then
    if [[ -f "$CACHE_DIR/context_pct" && -f "$CACHE_DIR/context_tokens" ]]; then
        cached_pct=$(<"$CACHE_DIR/context_pct")
        cached_tokens=$(<"$CACHE_DIR/context_tokens")
        if [[ "$cached_pct" =~ ^[0-9]+$ && "$cached_tokens" =~ ^[0-9]+$ ]]; then
            if (( cached_pct >= 0 && cached_pct <= 100 && cached_tokens <= MAX_CONTEXT )); then
                context_pct="$cached_pct"
                context_tokens="$cached_tokens"
                context_found=true
                context_delta="$cached_delta"
            fi
        fi
    fi
fi

# ---- Build Line 2: Context + metadata ----
declare -a line2_parts=()

# Context with progress bar
if [[ "$context_found" == true && -n "$context_pct" && -n "$context_tokens" ]]; then
    tokens_k=$(( context_tokens / 1000 ))
    max_k=$(( MAX_CONTEXT / 1000 ))
    ctx_color=$(pct_color "$context_pct")
    ctx_bar=$(progress_bar "$context_pct" 10 "$ctx_color")
    line2_parts+=("$(printf '🧠 %s%d%%%s[%s]%s%sk/%sk%s%s%s' "$ctx_color" "$context_pct" "$RST" "$ctx_bar" "$ctx_color" "$tokens_k" "$max_k" "$RST" "$C_MUTED" "${context_delta}${RST}")")
else
    max_k=$(( MAX_CONTEXT / 1000 ))
    empty_bar=$(progress_bar 0 10 "$C_DIM")
    line2_parts+=("🧠 ${C_DIM}--${RST} [${empty_bar}] ${C_DIM}0k/${max_k}k${RST}")
fi

# Model (+ effort level when the model supports reasoning effort)
model_segment="🤖 ${C_MODEL}${model_name}${RST}"
[[ -n "$effort_level" ]] && model_segment+=" ${C_MUTED}(${effort_level})${RST}"
line2_parts+=("$model_segment")

# Session cost (self-hiding; pre-formatted "X.XX" by the merged jq call)
[[ -n "$cost_usd" ]] && line2_parts+=("${C_MUTED}💰 \$${cost_usd}${RST}")


# ---- Build Line 3: Git + location ----
declare -a line3_parts=()

if [[ -n "$git_branch" ]]; then
    line3_parts+=("🌿 ${C_GIT}(${git_branch}${git_dirty}${git_ahead_behind:-})${RST}")
fi

line3_parts+=("${C_USER}${username}@${hostname_short}${RST}:${C_PATH}${current_dir}${RST}")

# ---- Output ----
# Line 1: context → model → rate limits (single line)
declare -a combined_parts=()
# Context first
for part in "${line2_parts[@]}"; do combined_parts+=("$part"); done
# Then rate limits (empty-array guard: plain "${arr[@]}" on an empty array
# is an unbound-variable error under set -u before bash 4.4)
for part in ${line1_parts[@]+"${line1_parts[@]}"}; do combined_parts+=("$part"); done

# Render timestamp (when this statusline snapshot was generated)
printf -v render_time '%(%H:%M)T' -1
combined_parts+=("${C_MUTED}🕐 ${render_time}${RST}")

if [[ ${#combined_parts[@]} -gt 0 ]]; then
    printf '%s' "${combined_parts[0]}"
    for ((i=1; i<${#combined_parts[@]}; i++)); do
        printf ' %s' "${combined_parts[i]}"
    done
    printf '\n'
fi

# Line 3: Git + location
if [[ ${#line3_parts[@]} -gt 0 ]]; then
    printf '%s' "${line3_parts[0]}"
    for ((i=1; i<${#line3_parts[@]}; i++)); do
        printf ' %s' "${line3_parts[i]}"
    done
fi

# Background cleanup of stale session caches
maybe_cleanup_sessions &>/dev/null &
