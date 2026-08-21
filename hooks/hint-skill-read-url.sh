#!/usr/bin/bash
# PreToolUse hook: when Claude is about to call WebFetch, nudge it to load
# the `read-url` skill instead — it returns clean complete markdown and
# bypasses WebFetch's truncation/summarization/refusal cases. Fires at most
# once per session_id to avoid re-prompting on iterative fetches.
#
# Non-blocking by design: WebFetch is fine for trivial fetches when the
# defuddle / jina-reader fallback chain is unnecessary.
#
# Sibling hook `hint-skill-jina-ai.sh` covers WebSearch → /jina-ai.
set -euo pipefail

source "$(dirname "$0")/lib/emit.sh"
source "$(dirname "$0")/lib/session_lock.sh"

input=$(cat)

SID=$(jq -r '.session_id // "unknown"' <<< "$input")

# Skip subagents — agent-* prefix on session_id. Main agent benefits from
# being nudged toward the skill; short-lived subagents typically just use
# WebFetch directly and don't have budget for loading a skill.
case "$SID" in agent-*) exit 0 ;; esac

CACHE_DIR=/tmp/claude-${UID}-state/skill-hint-read-url
CACHE="$CACHE_DIR/$SID"
mkdir -p "$CACHE_DIR"
reset_on_compact "$SID" "$CACHE_DIR" "$CACHE"
[ -f "$CACHE" ] && exit 0
touch "$CACHE"

emit_pre_tool_warn 'About to call WebFetch. Consider the /read-url skill — it returns clean, complete markdown for the whole page (articles, docs, READMEs, papers) and avoids WebFetch'\''s truncation, summarization, or refusal behaviors. Built-in WebFetch is fine for trivial fetches where a short summary is enough.'
