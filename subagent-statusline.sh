#!/usr/bin/env bash
# Subagent statusline for Claude Code - one JSON {id,content} line per task row.
# Layout: [✓/✗/⊘ ]name 🤖 model (effort) 🧠 pct%[bar]usedk/totalk ⏱️ elapsed · description
# (context bar mirrors the main statusline; plain tokens shown when the model's
#  context window size is not resolved yet)
# Icons act as the visual separators (same icon language as statusline.sh).
# All rows render in one pass, so name/model/token/elapsed columns are padded to
# align across rows (table-like). Live agents get NO status glyph: the agent
# panel already draws its own activity dot; only terminal states (✓ ✗ ⊘) add one.
# Width math: each icon displays as 2 cells but counts 1-2 codepoints, so the
# plain twin uses a fixed 2-char placeholder ("xx") per icon to keep truncation
# at the real display width.
# stdin:  {columns, tasks:[{id,name,type,status,description,label,startTime(ms),
#          model,effort,contextWindowSize,tokenCount,tokenSamples[],...}]}
#          (CC 2.1.215+; verified on 2.1.220)
# name = agent-name registry entry (the Agent call's `name` param, when one was
# passed). type = task KIND ("local_agent"/"local_bash"/...), so rows without a
# name render a short kind label, never the raw kind string.
# tokenCount comes from progress.tokenCount = latestInputTokens + cumulativeOutputTokens.
# Provider quirks (verified CC 2.1.220):
# - Grok: trailing assistant events with usage input_tokens=0 overwrite latestInputTokens.
# - GLM: transcripts have real usage, but progress.tokenCount often stays 0 in the panel
#   payload (tokenSamples empty too). Fallback: recompute from
#   ~/.claude/projects/**/subagents/agent-<taskId>.jsonl (same g0o formula, but never
#   let a zero-input event wipe a prior non-zero latestInputTokens).
# tokenSamples (ring of 16) is still used as a high watermark when present.
# effort: task.effort is set only when the agent definition pins one. Unset means
# the agent runs at the session's effort level; statusline.sh publishes that level
# to the shared cache and this script renders it for effort-capable families.
# Nested (+N): parentAgentId is not in this stdin payload, but Claude Code writes
# agent-<id>.meta.json sidecars that carry it; children with a recently-written
# transcript count into a dim (+N) after the parent's name.
# Any failure -> exit 0 with no stdout (panel keeps default rows).
# Budget: CC kills this command at 5s (UMS); keep enrichment well under 1s.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'subagent-statusline.sh: bash >= 4.4 required, found %s\n' "$BASH_VERSION" >&2
    exit 0
fi
set -uo pipefail
IFS=$'\n\t'

# ---- Pre-computed, NO_COLOR-aware ANSI (mirrors statusline.sh) ----
use_color=1
[[ -n "${NO_COLOR:-}" ]] && use_color=0
if [[ "$use_color" -eq 1 ]]; then
    RST=$'\033[0m'
    C_GREEN=$'\033[38;5;114m'
    C_YELLOW=$'\033[38;5;220m'
    C_RED=$'\033[38;5;203m'
    C_MODEL=$'\033[38;5;147m'
    C_DIM=$'\033[38;5;240m'
    C_MUTED=$'\033[38;5;245m'
else
    RST='' C_GREEN='' C_YELLOW='' C_RED='' C_MODEL='' C_DIM='' C_MUTED=''
fi

command -v jq >/dev/null 2>&1 || { echo "subagent-statusline: jq not found" >&2; exit 0; }

# ---- Detect stat variant once (mirrors statusline.sh) ----
if stat -f %m /dev/null >/dev/null 2>&1; then
    file_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
    file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

# GNU timeout, gtimeout (macOS + coreutils), or bare on stock macOS
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        "$@"
    fi
}

# Bounded read: 2s here + 2s python enrichment stays inside the panel's 5s
# kill. Claude Code closes stdin after writing, so the normal case is instant.
input=$(run_with_timeout 2 cat)

# Validate JSON + extract columns (type-guarded, default 80), task count, and
# session metadata (present since the payload spreads the session context).
meta=$(printf '%s' "$input" \
  | jq -r '[(if (.columns|type)=="number" then .columns else 80 end),
            ((.tasks // [])|length),
            (.session_id // "" | tostring),
            (.transcript_path // "" | tostring)] | join("\u001f")' 2>/dev/null) || true
[[ -z "$meta" ]] && { echo "subagent-statusline: invalid/empty JSON stdin" >&2; exit 0; }
IFS=$'\x1f' read -r cols ntasks session_id transcript_path <<< "$meta"
[[ "$cols"   =~ ^[0-9]+$ ]] || cols=80
[[ "$ntasks" =~ ^[0-9]+$ ]] || ntasks=0
(( ntasks > 0 )) || { echo "subagent-statusline: no tasks" >&2; exit 0; }

# Inherited effort: agents with no pinned effort run at the session's level.
# statusline.sh publishes that level to the shared cache; read it back.
session_effort=""
if [[ "$session_id" =~ ^[0-9a-fA-F-]+$ ]]; then
    eff_file="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-statusline-${UID:-$(id -u)}/session_${session_id}/effort"
    [[ -f "$eff_file" ]] && session_effort=$(<"$eff_file")
    [[ "$session_effort" =~ ^[a-z]{1,12}$ ]] || session_effort=""
fi

# Nested agents: the payload has no parent linkage, but Claude Code writes an
# agent-<id>.meta.json sidecar with parentAgentId next to each transcript.
# Count children whose transcript is still being written (mtime <= 90s).
children_json="{}"
sub_dir="${transcript_path%.jsonl}/subagents"
if [[ -n "$transcript_path" && "$transcript_path" == *.jsonl && -d "$sub_dir" ]]; then
    now_s=${EPOCHSECONDS:-$(date +%s)}
    declare -A child_counts=()
    # One jq per sidecar: a single multi-file jq aborts at the first corrupt
    # file (one caught mid-write, for example) and would drop every count.
    for meta_file in "$sub_dir"/agent-*.meta.json; do
        [[ -f "$meta_file" ]] || continue
        parent_id=$(jq -r 'select(type == "object" and .parentAgentId != null)
                           | .parentAgentId | tostring' "$meta_file" 2>/dev/null) || parent_id=""
        [[ "$parent_id" =~ ^a[0-9a-f]{8,24}$ ]] || continue
        child_jsonl="${meta_file%.meta.json}.jsonl"
        [[ -f "$child_jsonl" ]] || continue
        (( now_s - $(file_mtime "$child_jsonl") <= 90 )) || continue
        child_counts[$parent_id]=$(( ${child_counts[$parent_id]:-0} + 1 ))
    done
    if (( ${#child_counts[@]} > 0 )); then
        children_json=$(
            for k in "${!child_counts[@]}"; do printf '%s %s\n' "$k" "${child_counts[$k]}"; done \
            | jq -Rn '[inputs | split(" ") | {(.[0]): (.[1]|tonumber)}] | add // {}' 2>/dev/null
        ) || children_json="{}"
        [[ "$children_json" == \{* ]] || children_json="{}"
    fi
fi

now_ms=$(( ${EPOCHSECONDS:-$(date +%s)} * 1000 ))

# Enrich tasks with transcript-derived token counts when the panel payload is empty
# or wiped. python3 is optional and hard-bounded: if missing or slow, keep original input.
tok_cache_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-subagent-statusline-${UID:-$(id -u)}"
# Roughly one render in fifty: detached sweep of token caches idle for 3+ days
# (under the /tmp fallback the dir would otherwise grow one file per agent, forever)
if (( RANDOM % 50 == 0 )) && [[ -d "$tok_cache_dir" ]]; then
    find "$tok_cache_dir" -maxdepth 1 -name '*.tok*' -type f -mmin +4320 -delete 2>/dev/null &
fi
if command -v python3 >/dev/null 2>&1; then
    enriched=$(
        STATUSLINE_PROJECTS_ROOT="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/projects" \
        STATUSLINE_CACHE_DIR="$tok_cache_dir" \
        run_with_timeout 2 python3 - "$input" <<'PY' 2>/dev/null
import json, os, re, stat, sys, time
from pathlib import Path

# Task ids feed file names: accept only the real id shape (a + hex).
TID_RE = re.compile(r"a[0-9a-f]{8,24}\Z")
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)

raw = sys.argv[1] if len(sys.argv) > 1 else ""  # stdin carries this program, not the payload
try:
    data = json.loads(raw)
except Exception:
    sys.stdout.write(raw)
    raise SystemExit(0)

tasks = data.get("tasks") or []
if not isinstance(tasks, list) or not tasks:
    sys.stdout.write(raw)
    raise SystemExit(0)

# Only enrich agents whose panel token signal is empty/low.
need = []
for t in tasks:
    if not isinstance(t, dict):
        continue
    tid = str(t.get("id") or "")
    if not TID_RE.fullmatch(tid):
        continue
    tc = t.get("tokenCount") or 0
    try:
        tc = int(tc)
    except Exception:
        tc = 0
    samples = t.get("tokenSamples") or []
    sm = 0
    if isinstance(samples, list):
        for s in samples:
            try:
                sm = max(sm, int(s))
            except Exception:
                pass
    if max(tc, sm) < 500:  # treat near-zero as missing for enrichment
        need.append(tid)

if not need:
    sys.stdout.write(raw)
    raise SystemExit(0)

projects = Path(os.environ.get("STATUSLINE_PROJECTS_ROOT", Path.home() / ".claude" / "projects"))

# Cache dir (uid-suffixed; the bash caller passes it in). Under a world-writable
# /tmp fallback another user can pre-create the path and plant symlinks, so
# refuse any dir we do not own instead of chmod-and-hope; lstat before chmod so
# a symlinked path is never followed. cache_dir=None -> run uncached (correct,
# just recounts from byte 0 each render).
_rt = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
cache_dir = Path(os.environ.get("STATUSLINE_CACHE_DIR")
                 or os.path.join(_rt, "claude-subagent-statusline-%d" % os.getuid()))
try:
    cache_dir.mkdir(parents=True, exist_ok=True)
    cst = os.lstat(cache_dir)
    if stat.S_ISDIR(cst.st_mode) and cst.st_uid == os.getuid():
        os.chmod(cache_dir, 0o700)
    else:
        cache_dir = None
except Exception:
    cache_dir = None

# Map task id -> newest matching agent-*.jsonl under projects (recent sessions only).
# File names: agent-<taskId>.jsonl where taskId already starts with 'a'.
want = set(need)
found = {}
now = time.time()
max_age = 3 * 86400  # 3 days
# Prefer shallow walk: projects/<encoded>/ <session>/subagents/
try:
    if projects.is_dir():
        for proj in projects.iterdir():
            if not proj.is_dir():
                continue
            try:
                if now - proj.stat().st_mtime > max_age:
                    continue
            except Exception:
                continue
            for sess in proj.iterdir():
                if not sess.is_dir():
                    continue
                sub = sess / "subagents"
                if not sub.is_dir():
                    continue
                try:
                    if now - sub.stat().st_mtime > max_age:
                        continue
                except Exception:
                    continue
                for tid in list(want):
                    # task id is the agent file stem without "agent-" or full stem
                    candidates = (
                        sub / f"agent-{tid}.jsonl",
                        sub / f"{tid}.jsonl",
                    )
                    for fp in candidates:
                        if fp.is_file():
                            prev = found.get(tid)
                            try:
                                m = fp.stat().st_mtime
                            except Exception:
                                continue
                            if prev is None or m > prev[1]:
                                found[tid] = (fp, m)
                if len(found) == len(want):
                    break
            if len(found) == len(want):
                break
except Exception:
    pass

def tokens_from_transcript(path: Path) -> int:
    """g0o formula (latest input + cumulative output) with zero-wipe protection.

    Incremental: a cache line "offset latest cum_out" lets each render parse only
    the bytes appended since the previous one; the first sight of a transcript
    parses it all (a tail read cannot reconstruct the cumulative output sum).
    Transcripts are append-only; a shrunk file or garbled cache resets to a full
    parse. Cache I/O is O_NOFOLLOW so a planted symlink is never followed.
    """
    try:
        st = path.stat()
    except Exception:
        return 0

    cache = (cache_dir / (path.name + ".tok")) if cache_dir is not None else None
    offset = latest = cum_out = 0
    if cache is not None:
        try:
            fd = os.open(cache, os.O_RDONLY | O_NOFOLLOW)
            with os.fdopen(fd, "r") as fh:
                parts = fh.read().split()
            if len(parts) == 3:
                offset, latest, cum_out = int(parts[0]), int(parts[1]), int(parts[2])
            # offset 0 always means "recount from scratch with zeroed counters":
            # carrying counters across a zero offset would double-add them.
            if not (0 < offset <= st.st_size and latest >= 0 and cum_out >= 0):
                offset = latest = cum_out = 0
        except Exception:
            offset = latest = cum_out = 0

    if offset == st.st_size:
        return latest + cum_out

    try:
        with path.open("rb") as f:
            if offset:
                f.seek(offset)
            data = f.read()
    except Exception:
        return 0

    lines = data.split(b"\n")
    tail = lines.pop()  # partial trailing line (empty when data ends in newline)
    new_offset = offset + len(data) - len(tail)
    for line_b in lines:
        if not line_b:
            continue
        try:
            o = json.loads(line_b.decode("utf-8", "ignore"))
        except Exception:
            continue
        if not isinstance(o, dict) or o.get("type") != "assistant":
            continue
        msg = o.get("message") or {}
        if not isinstance(msg, dict):
            continue
        u = msg.get("usage") or {}
        if not isinstance(u, dict):
            continue
        try:
            it = int(u.get("input_tokens") or 0)
            cc = int(u.get("cache_creation_input_tokens") or 0)
            cr = int(u.get("cache_read_input_tokens") or 0)
            ot = int(u.get("output_tokens") or 0)
        except Exception:
            continue
        inp = it + cc + cr
        # Protect against zero-usage overwrites (Grok / partial stream events).
        if inp > 0:
            latest = inp
        cum_out += ot

    if cache is not None:
        try:
            # Atomic replace: a torn in-place write could leave a structurally
            # valid triple whose counters silently poison later increments.
            tmp = cache.with_name(cache.name + ".%d" % os.getpid())
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as fh:
                fh.write("%d %d %d" % (new_offset, latest, cum_out))
            os.replace(tmp, cache)
        except Exception:
            pass
    return latest + cum_out

# Patch tasks
changed = False
for t in tasks:
    if not isinstance(t, dict):
        continue
    tid = str(t.get("id") or "")
    if tid not in found:
        continue
    path, _ = found[tid]
    tx = tokens_from_transcript(path)
    if tx <= 0:
        continue
    tc = t.get("tokenCount") or 0
    try:
        tc = int(tc)
    except Exception:
        tc = 0
    samples = t.get("tokenSamples") if isinstance(t.get("tokenSamples"), list) else []
    sm = 0
    for s in samples:
        try:
            sm = max(sm, int(s))
        except Exception:
            pass
    if tx > max(tc, sm):
        # Raise tokenCount; keep samples so jq max() still works.
        t["tokenCount"] = tx
        if not samples:
            t["tokenSamples"] = [tx]
        changed = True

if changed:
    sys.stdout.write(json.dumps(data, separators=(",", ":")))
else:
    sys.stdout.write(raw)
PY
    ) || enriched=""
    if [[ -n "$enriched" ]]; then
        input="$enriched"
    fi
fi

# Single jq -c builds every row in two stages: precompute plain fields for all
# tasks (type-coerced so hostile scalar shapes cannot throw), derive per-column
# max widths, then render each row padded. Width stays exact: the plain twin
# ($pp) of the colored string ($cc) is measured, never regex-stripped.
# Per-row try/catch: one bad task degrades to its default row only.
read -r -d '' PROG <<'JQ' || true
def str: if . == null then "" else tostring end;
# Sanitize every task-derived string before it reaches the terminal: collapse all
# whitespace (incl. newlines/tabs) to single spaces, then strip C0 controls + DEL.
# Order matters: the \s+ pass turns whitespace-controls into spaces first, so the
# control strip only removes injection bytes (ESC, NUL, etc.), never eats word gaps.
# Without this a hostile description/name could smuggle raw ANSI/OSC escapes that
# the panel executes after it JSON-decodes our content.
def clean: str | gsub("\\s+"; " ")
  | [explode[] | select((. >= 32 and . < 127) or . > 159)] | implode;
def kfmt: (tonumber? // 0) as $t | ($t/100|round) as $x | "\($x/10|floor).\($x%10)k";
def modelshort:
  clean as $m | ($m|ascii_downcase) as $l |
  if   ($l|test("opus"))   then "Opus"
  elif ($l|test("sonnet")) then "Sonnet"
  elif ($l|test("haiku"))  then "Haiku"
  elif ($l|test("fable"))  then "Fable"
  elif ($l|test("grok"))   then
    (if ($l|test("4\\.5|4-5")) then "Grok 4.5" else "Grok" end)
  elif ($l|test("glm"))    then
    # glm-5.2 / glm-5.2[1m] / GLM-4.6 -> keep family + version tag when present
    (if ($m|test("\\[")) then ($m|split("[")[0]) else $m end) as $base
    | ($base|gsub("^glm-?";"GLM ")|gsub("^GLM  *";"GLM ")) as $g
    | if ($g|test("GLM [0-9]")) then $g else "GLM" end
  elif ($l|test("kimi"))   then "Kimi"
  elif ($l|test("codex|gpt-")) then "GPT"
  elif $m=="" then ""
  else ($m|split("-")[0]) as $s | (($s[0:1]|ascii_upcase)+$s[1:]) end;
def pctcolor($p): if $p>=80 then $red elif $p>=50 then $yel elif $p<10 then $dim else $grn end;
def rep($n): if $n <= 0 then "" else (" " * $n) end;
def chars($ch; $n): if $n <= 0 then "" else ($ch * $n) end;
def elapsed($now): (tonumber? // $now) as $s0
  | (($now - $s0)/1000 | floor) as $s1 | (if $s1 < 0 then 0 else $s1 end) as $s
  | if $s < 60 then "\($s)s"
    elif $s < 3600 then "\($s/60|floor)m \($s%60)s"
    elif $s < 86400 then "\($s/3600|floor)h \(($s%3600)/60|floor)m"
    else "\($s/86400|floor)d \(($s%86400)/3600|floor)h" end;
# Effective token count: prefer live tokenCount, but never drop below the high
# watermark seen in tokenSamples (Grok zero-usage overwrite defense).
def efftokens:
  ((.tokenCount // 0) | tonumber? // 0) as $tc
  | ([((.tokenSamples // [])[]? | tonumber? // empty)] | max? // 0) as $sm
  | if $sm > $tc then $sm else $tc end;
# Payload `type` is the task KIND (2.1.215 task registry), not the agent type; a proper
# agent name arrives only via `name`. Kinds only surface on unnamed launches.
def kindlabel: if . == "local_agent" then "agent"
  elif . == "local_bash" then "shell"
  elif . == "remote_agent" then "remote"
  elif . == "local_workflow" then "workflow"
  elif . == "in_process_teammate" then "teammate"
  else . end;
[ .tasks[]? | . as $t
  | (($t.status // "") | clean) as $st
  | (($st=="running" or $st=="pending" or $st=="queued" or $st=="completed"
      or $st=="failed" or $st=="cancelled" or $st=="")) as $known
  | ($t | efftokens) as $tc
  | (($t.contextWindowSize // null) as $cw
     | if ($cw|type)=="number" and $cw > 0
       then (($tc * 100 / $cw) | floor) else null end) as $pc
  | { id: ($t.id | str),
      gp: (if $st=="completed" then "✓" elif $st=="failed" then "✗"
           elif $st=="cancelled" then "⊘" else "" end),
      gc: (if $st=="completed" then $grn elif $st=="failed" then $red
           elif $st=="cancelled" then $yel else $dim end),
      nm: (((($t.name // "") | clean) as $n
           | if $n != "" then $n
             else (($t.type // "") | clean | kindlabel | if . == "" then "agent" else . end) end) as $n2
           | ($kids[($t.id | str)] // 0) as $kn
           | { p: ($n2 + (if $kn > 0 then " (+\($kn))" else "" end)),
               c: ($mdl + $n2 + $rst + (if $kn > 0 then " " + $dim + "(+\($kn))" + $rst else "" end)) }),
      md: ((if ($t.model|type)=="string" then $t.model else null end) as $mo
           | if $mo == null then ""
             else ($mo | modelshort) as $ms
             | ($mo | clean | ascii_downcase) as $ml
             | (($t.effort // "") | clean) as $ef0
             # Pinned effort wins; otherwise inherit the session level, but only
             # for families where effort exists (Anthropic models).
             | (if $ef0 != "" then $ef0
                elif ($ml|test("opus|sonnet|haiku|fable|claude")) then $seff
                else "" end) as $ef
             | (if $ef == "" then $ms else $ms + " (" + $ef + ")" end) end),
      tk: (($tc) as $tc
           | ($t.contextWindowSize // null) as $cw
           | if $pc != null and ($cw|type)=="number"
             then (if $pc > 100 then 10 else ($pc * 10 / 100 | floor) end) as $f
                # Over-window counts are real (cumulative output adds up), but cap
                # the display so a runaway value cannot stretch the column.
                | (if $pc > 999 then "999+" else "\($pc)" end) as $pt
                | pctcolor($pc) as $col
                | { p: ("\($pt)%[" + chars("="; $f) + chars("-"; 10 - $f) + "]\($tc / 1000 | floor)k/\($cw / 1000 | floor)k"),
                    c: ($col + "\($pt)%" + $rst + "[" + $col + chars("="; $f) + $rst + $dim + chars("-"; 10 - $f) + $rst + "]"
                        + $col + "\($tc / 1000 | floor)k/\($cw / 1000 | floor)k" + $rst) }
             else (($tc | kfmt) as $k | { p: $k, c: ($mut + $k + $rst) }) end),
      pc: $pc,
      el: (($t.startTime // $now) | elapsed($now)),
      ds: ((($t.label // $t.description // "") | clean) as $d0
           | if $known then $d0
             else "[" + $st + "]" + (if $d0 == "" then "" else " " + $d0 end) end)
    }
] as $rows
| ([$rows[].gp | length] | max // 0) as $gw
| ([$rows[].nm.p | length] | max // 0) as $nw
| ([$rows[].md | length] | max // 0) as $mw
| ([$rows[].tk.p | length] | max // 0) as $tw
| ([$rows[].el | length] | max // 0) as $ew
| $rows[]
| . as $r
| (try (
    (if $gw > 0 then ($r.gp + rep($gw - ($r.gp|length)) + " ") else "" end) as $gpp
  | (if $gw > 0 then ($r.gc + $r.gp + $rst + rep($gw - ($r.gp|length)) + " ") else "" end) as $gpc
  | ([ {p: ($r.nm.p + rep($nw - ($r.nm.p|length))), c: ($r.nm.c + rep($nw - ($r.nm.p|length)))} ]
     + (if $mw > 0
        then [ (if $r.md == ""
                then {p: rep(3 + $mw), c: rep(3 + $mw)}
                else {p: ("xx " + $r.md + rep($mw - ($r.md|length))),
                      c: ("🤖 " + $mut + $r.md + $rst + rep($mw - ($r.md|length)))} end) ]
        else [] end)
     + [ {p: ("xx " + $r.tk.p + rep($tw - ($r.tk.p|length))),
          c: ("🧠 " + $r.tk.c + rep($tw - ($r.tk.p|length)))} ]
     + [ {p: ("xx " + $r.el + rep($ew - ($r.el|length))),
          c: ("⏱️ " + $mut + $r.el + $rst + rep($ew - ($r.el|length)))} ]) as $fields
  | ($gpp + ($fields | map(.p) | join(" "))) as $pp
  | ($gpc + ($fields | map(.c) | join(" "))) as $cc
  | ($cols - ($pp|length) - 3) as $avail
  | (if $r.ds == "" then $cc
     elif ($r.ds|length) <= $avail then ($cc + $dim + " · " + $r.ds + $rst)
     elif $avail >= 2 then ($cc + $dim + " · " + ($r.ds[0:($avail-1)]) + "…" + $rst)
     else $cc end) as $content
  | {id: $r.id, content: $content}
  ) catch empty)
JQ

rows=$(printf '%s' "$input" | jq -c \
  --argjson now  "$now_ms" \
  --argjson cols "$cols" \
  --argjson kids "$children_json" \
  --arg seff "$session_effort" \
  --arg grn "$C_GREEN" --arg yel "$C_YELLOW" --arg red "$C_RED" \
  --arg dim "$C_DIM"   --arg mut "$C_MUTED"   --arg mdl "$C_MODEL" \
  --arg rst "$RST" \
  "$PROG" 2>/dev/null) || true

[[ -z "$rows" ]] && { echo "subagent-statusline: no rows produced" >&2; exit 0; }
printf '%s\n' "$rows"
exit 0
