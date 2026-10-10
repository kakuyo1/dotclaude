#!/usr/bin/env bash
# Custom Claude Code statusLine renderer.
#
# Reads stdin JSON (session_id, cwd, model.id, context_window, workspace,
# cost.total_lines_added/removed, effort, thinking),
# renders a single line with model + ctx% + balance + cwd + git + proxy + audit +
# idle + drift + file + effort + clock segments scoped to the current session.
#
# Audit segment priority:
#   1. <sid>.json.auditing-<pid>-<ts>  → "auditing… Ns" (cyan) while alive
#   2. <sid>.json.audit-result         → "audit ✓/⚠/✗" (within TTL)
#   3. nothing
#
# Wired in settings.json.statusLine with refreshInterval: 5.

set -o pipefail

input=$(cat)

# All stdin fields in one jq spawn: doing this as nine separate single-field
# calls costs ~240ms per render, this costs ~27ms. Fields are joined with U+001F
# rather than @tsv because TAB is IFS-whitespace and `read` collapses runs of
# it, silently shifting every value left whenever a field is empty. The output
# is routed through $( ) rather than a process substitution because jq here
# terminates stdout with CRLF; fed straight into `read`, that puts a stray CR on
# the last field (`true\r` != `true`). Command substitution strips it.
stdin_fields=$(jq -r '[
  .session_id // "",
  .cwd // "",
  .workspace.project_dir // "",
  .model.id // .model.display_name // "",
  .context_window.used_percentage // "",
  .cost.total_lines_added // "",
  .cost.total_lines_removed // "",
  .effort.level // "",
  .thinking.enabled // ""
] | map(tostring) | join("\u001f")' <<<"$input")
IFS=$'\x1f' read -r session_id cwd project_dir model_id ctx_pct \
  lines_added lines_removed effort_level thinking_enabled <<<"$stdin_fields"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
GRAY=$'\033[90m'
BOLD=$'\033[1m'
RESET=$'\033[0m'
sep='\'

file_mtime_epoch() {
  stat -c '%Y' "$1" 2>/dev/null ||
    stat -f '%m' "$1" 2>/dev/null ||
    true
}

# --- model_short -------------------------------------------------------------
# claude-<family>-<major>-<minor>[1m] -> <family>-<major>.<minor>-1m
# Illustrative only; an id that is not claude-* passes through unchanged, and so
# does display_name. Naming a real model here would rot the moment it retires.
model_segment=""
if [[ -n "$model_id" ]]; then
  if [[ "$model_id" == claude-* ]]; then
    m="${model_id#claude-}"
    m=$(sed -E 's/([0-9])-([0-9])/\1.\2/g; s/\[([^]]+)\]/-\1/g' <<<"$m")
  else
    m="$model_id"
  fi
  model_segment="${BOLD}${MAGENTA}${m}${RESET}"
fi

# --- ctx% --------------------------------------------------------------------
ctx_segment=""
if [[ "$ctx_pct" =~ ^[0-9]+$ ]] && (( ctx_pct > 0 )); then
  if   (( ctx_pct < 70 )); then color=$GREEN
  elif (( ctx_pct < 85 )); then color=$YELLOW
  else                          color=$RED
  fi
  ctx_segment=" ${color}[${ctx_pct}%]${RESET}"
fi

# --- provider-aware balance ---------------------------------------------------
# The provider is read from ANTHROPIC_BASE_URL in this process's own
# environment, so there is no state file to drift out of sync with reality.
# Each provider keeps its own cache file, so a balance fetched for one can never
# render while the other is active.
#
# Claude Code's own cost.total_cost_usd is deliberately NOT used: it prices this
# model at a default Claude rate card and overstated the real bill by ~50x.
# BALANCE_TTL: ~200ms per call is cheap but pointless on a 5s refresh. The token
# is only ever passed as a curl header; it is never written to disk. On fetch
# failure the last cached value still shows; with no usable number the segment
# degrades to a bare provider badge.
cost_segment=""
cost_part=""
cost_color=$GRAY
state_dir="/tmp/claude-${UID}-state"
BALANCE_TTL=60

provider=""
symbol=""
case "${ANTHROPIC_BASE_URL:-}" in
  *deepseek*)    provider=deepseek;    symbol='¥' ;;
  *agentrouter*) provider=agentrouter; symbol='$' ;;
  *traxnode*)    provider=traxnode;    symbol='$' ;;
  *)             provider="" ;;
esac

# Prints one number, or nothing. An unexpected response shape must yield nothing
# rather than a wrong number.
fetch_balance() {
  case "$provider" in
    deepseek)
      curl -sS --max-time 5 \
        -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
        https://api.deepseek.com/user/balance 2>/dev/null |
        jq -r '.balance_infos[0].total_balance // empty' 2>/dev/null || true
      ;;
    agentrouter)
      # No balance is obtainable with an API key here. Measured against the
      # live relay:
      #   /v1/dashboard/billing/subscription returns
      #     {"soft_limit_usd":100000000,"hard_limit_usd":100000000,
      #      "system_hard_limit_usd":100000000}
      #   — 100000000 is New API's "no limit" sentinel, not a balance. Rendering
      #   it produced a literal $100000000 on the status line.
      #   /v1/dashboard/billing/usage returns only total_usage (spend so far),
      #   and the real per-account quota sits behind /api/user/self, which
      #   rejects an sk- key and wants a browser session token.
      # So there is nothing honest to render: return nothing and let the badge
      # fallback name the provider.
      ;;
    traxnode)
      # /api/user/self takes the long-lived system access token, not the sk- key
      # (that gets 401). The token lives in the bundle's secret file under
      # access_token, so the bundle switch never sees it. quota / 500000 is USD.
      access_token=$(jq -r '.access_token // empty' "$HOME/.claude/bundles/traxnode.local.json" 2>/dev/null || true)
      [[ -n "$access_token" ]] || return 0
      curl -sS --max-time 5 -H "Authorization: $access_token" \
        https://www.traxnode.com/api/user/self 2>/dev/null |
        jq -r '.data.quota // empty | . / 500000 | . * 100 | round / 100' 2>/dev/null || true
      ;;
  esac
}

if [[ -n "$provider" ]]; then
  balance_cache="$state_dir/${provider}-balance"
  if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    bal_age=$(( BALANCE_TTL + 1 ))
    if [[ -f "$balance_cache" ]]; then
      bal_mtime=$(file_mtime_epoch "$balance_cache")
      [[ -n "$bal_mtime" ]] && bal_age=$(( $(date +%s) - bal_mtime ))
    fi
    if (( bal_age >= BALANCE_TTL )); then
      fresh_bal=$(fetch_balance)
      if [[ "$fresh_bal" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        mkdir -p "$state_dir"
        printf '%s' "$fresh_bal" > "$balance_cache.tmp.$$" &&
          mv "$balance_cache.tmp.$$" "$balance_cache"
      fi
    fi
    cached_bal=$(cat "$balance_cache" 2>/dev/null || true)
    if [[ "$cached_bal" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      cost_part="${symbol}${cached_bal}"
      if awk -v b="$cached_bal" 'BEGIN { exit !(b + 0 < 1) }'; then
        cost_color=$RED
      fi
    fi
  fi
  # Badge fallback: provider is known but there is no usable number (no token,
  # endpoint gone, shape unrecognised). Still says which account is active.
  # Never red — red is reserved for a real balance that is nearly exhausted.
  [[ -n "$cost_part" ]] || cost_part="$provider"
fi
lines_part=""
if [[ "$lines_added" =~ ^[0-9]+$ && "$lines_removed" =~ ^[0-9]+$ ]] &&
  (( lines_added > 0 || lines_removed > 0 )); then
  lines_part="${GREEN}+${lines_added}${RESET}/${RED}-${lines_removed}${RESET}"
fi
if   [[ -n "$cost_part" && -n "$lines_part" ]]; then
  cost_segment="${cost_color}${cost_part}${RESET}  ${lines_part}"
elif [[ -n "$cost_part" ]]; then
  cost_segment="${cost_color}${cost_part}${RESET}"
elif [[ -n "$lines_part" ]]; then
  cost_segment="${lines_part}"
fi

# --- cwd_short ---------------------------------------------------------------
cwd_segment=""
if [[ -n "$cwd" ]]; then
  if [[ -n "$project_dir" && "$cwd" == "$project_dir"* ]]; then
    # Quoting is load-bearing: unquoted, a backslash in the pattern (Windows
    # paths) is an escape character, the match degenerates, and nothing is stripped.
    rel="${cwd#"$project_dir"}"
    rel="${rel#/}"
    rel="${rel#"$sep"}"
    cwd_short="${rel:-$(basename "$project_dir")}"
  elif [[ "$cwd" == "$HOME" ]]; then
    cwd_short="~"
  elif [[ "$cwd" == "$HOME/"* ]]; then
    cwd_short="~/${cwd#$HOME/}"
  else
    cwd_short=$(basename "$cwd")
  fi
  cwd_segment="${BLUE}${cwd_short}${RESET}"
fi

# --- git ---------------------------------------------------------------------
git_segment=""
if [[ -n "$cwd" ]] && git -C "$cwd" rev-parse --git-dir &>/dev/null; then
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -n "$branch" && "$branch" != "HEAD" ]]; then
    if [[ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]]; then
      git_segment="  ${YELLOW}${branch}*${RESET}"
    else
      git_segment="  ${GREEN}${branch}${RESET}"
    fi
    # Upstream tracking counts: "left\tright" = "<behind>\t<ahead>". No upstream
    # (or detached) → command fails → keep branch-only rendering.
    counts=$(git -C "$cwd" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || true)
    ab=""
    if [[ "$counts" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
      behind="${BASH_REMATCH[1]}"
      ahead="${BASH_REMATCH[2]}"
      (( ahead  > 0 )) && ab+="${GREEN}↑${ahead}${RESET}"
      (( behind > 0 )) && ab+="${YELLOW}↓${behind}${RESET}"
      [[ -n "$ab" ]] && ab=" ${ab}"
    fi
    git_segment+="$ab"
  fi
fi

# --- proxy -------------------------------------------------------------------
# Clash is toggled by hand and foreign sites fail silently when it is off, so
# this is the one segment that always renders: green "px" = port listening,
# red "px✗" = down.
proxy_segment=""
port="${HTTP_PROXY##*:}"
[[ "$port" =~ ^[0-9]+$ ]] || port=7890
# The reader must consume all of netstat's output: `grep -q` exits at the first
# match and SIGPIPEs netstat, which `set -o pipefail` would report as a failed
# probe (false red px✗).
hits=$(netstat -ano 2>/dev/null | grep -E "TCP[[:space:]]+127\.0\.0\.1:${port}[[:space:]]+0\.0\.0\.0:0[[:space:]]+LISTENING" || true)
if [[ -n "$hits" ]]; then
  proxy_segment="  ${GREEN}px${RESET}"
else
  proxy_segment="  ${RED}px✗${RESET}"
fi

# --- audit segment -----------------------------------------------------------
# Logic and color/TTL contract live in audit-edits.py statusline subcommand.
# Output already includes leading whitespace; empty string when nothing applies.
audit_segment=""
if [[ -n "$session_id" ]]; then
  audit_segment=$(~/.claude/hooks/audit-edits.py statusline "$session_id" 2>/dev/null || true)
fi

# --- idle segment -------------------------------------------------------------
# Time since last transcript activity. Hidden <2min, blue 2–5min, gray ≥5min (cache TTL).
idle_segment=""
if [[ -n "$session_id" ]]; then
  shopt -s nullglob
  transcripts=("$HOME"/.claude/projects/*/"${session_id}".jsonl)
  shopt -u nullglob
  transcript="${transcripts[0]:-}"
  if [[ -f "$transcript" ]]; then
    last_epoch=$(file_mtime_epoch "$transcript")
    if [[ -n "$last_epoch" ]]; then
      now_epoch=$(date +%s)
      elapsed=$(( now_epoch - last_epoch ))
      h=$((elapsed / 3600)); m=$(((elapsed % 3600) / 60)); s=$((elapsed % 60))
      if   (( h > 0 ));         then fmt="${h}h ${m}m ${s}s"
      elif (( elapsed >= 60 )); then fmt="${m}m ${s}s"
      else                           fmt="${s}s"
      fi
      if   (( elapsed >= 300 )); then color=$GRAY; idle_segment="  ${color}[${fmt}]${RESET}"
      elif (( elapsed >= 120 )); then color=$BLUE; idle_segment="  ${color}[${fmt}]${RESET}"
      fi
    fi
  fi
fi

# --- drift segment -----------------------------------------------------------
# Windowed B-ratio (tokens per grounding event). Empty until 5+ turns.
drift_segment=""
if [[ -n "$session_id" ]]; then
  drift_segment=$(~/.claude/hooks/drift-detect.py statusline "$session_id" 2>/dev/null || true)
fi

# --- last-file segment -------------------------------------------------------
# URL of the most recent SendUserFile delivery in this session. Written by
# hooks/track-sent-file.sh; kitty's ctrl+shift+e hints can select it.
file_segment=""
if [[ -n "$session_id" ]]; then
  file_state="/tmp/claude-${UID}-state/last-file-url/${session_id}"
  if [[ -f "$file_state" ]]; then
    url=$(head -n1 "$file_state" 2>/dev/null)
    [[ -n "$url" ]] && file_segment="  ${CYAN}${url}${RESET}"
  fi
fi

# --- effort ------------------------------------------------------------------
# Reasoning effort level in gray; "·think" suffix when extended thinking is on.
effort_segment=""
if [[ -n "$effort_level" ]]; then
  effort_segment="  ${GRAY}${effort_level}${RESET}"
  [[ "$thinking_enabled" == "true" ]] &&
    effort_segment+="${GRAY}·think${RESET}"
fi

# --- clock -------------------------------------------------------------------
# Always renders; replaces the per-turn prompt-injection clock hook.
clock_segment="  ${GRAY}$(date '+%H:%M')${RESET}"

# --- compose -----------------------------------------------------------------
left="${model_segment}${ctx_segment}"
[[ -n "$left" && -n "$cost_segment" ]] && left+="  "
left+="$cost_segment"
[[ -n "$left" && -n "$cwd_segment" ]] && left+="  "
printf '%s%s%s%s%s%s%s%s%s%s\n' "$left" "$cwd_segment" "$git_segment" "$proxy_segment" "$audit_segment" "$idle_segment" "$drift_segment" "$file_segment" "$effort_segment" "$clock_segment"
