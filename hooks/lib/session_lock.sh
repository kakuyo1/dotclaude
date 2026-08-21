#!/usr/bin/bash
# Shared helpers for hooks that fire once per session AND should re-arm
# after auto-compact. The intra-session one-shot lock prevents nag spam;
# but after auto-compact, the prior hint text is summarized out of context
# (the "you've already been told" state becomes invisible to the agent),
# so the lock should reset alongside compaction.
#
# How the signal works:
#   compact-bump.sh (PostCompact) increments a shared per-session generation
#   counter at /tmp/claude-${UID}-state/compact-events/<session_id>.gen. Each consuming
#   hook stores its own last-seen generation at <cache_dir>/<sid>.gen-seen
#   and compares: if the shared gen has grown, compaction happened since the
#   last reset and the cache files for this hook should be cleared.
#
# Usage in a one-shot hint hook:
#
#   source "$(dirname "$0")/lib/session_lock.sh"
#   ...
#   SID=$(jq -r '.session_id // "unknown"' <<< "$input")
#   CACHE_DIR=/tmp/claude-some-hint
#   CACHE="$CACHE_DIR/$SID"
#   reset_on_compact "$SID" "$CACHE_DIR" "$CACHE"
#   [ -f "$CACHE" ] && exit 0
#   touch "$CACHE"
#   emit_pre_tool_warn "..."

# reset_on_compact <sid> <cache_dir> <file1> [<file2> ...]
#   If compaction has bumped the shared generation since this hook last
#   reset, removes <file1> <file2> ... — restoring the one-shot lock so the
#   hook can fire again post-compact. Idempotent and cheap: reads two small
#   integer files; only removes the listed targets when the generation has
#   actually advanced.
reset_on_compact() {
    local sid="$1"
    local cache_dir="$2"
    shift 2
    local gen_seen="$cache_dir/$sid.gen-seen"
    local compact_gen_file="/tmp/claude-${UID}-state/compact-events/$sid.gen"
    local current_gen=0 prev_gen=0
    if [ -f "$compact_gen_file" ]; then
        current_gen=$(cat "$compact_gen_file")
        case "$current_gen" in *[!0-9]*|"") current_gen=0 ;; esac
    fi
    if [ -f "$gen_seen" ]; then
        prev_gen=$(cat "$gen_seen")
        case "$prev_gen" in *[!0-9]*|"") prev_gen=0 ;; esac
    fi
    if [ "$current_gen" -gt "$prev_gen" ]; then
        rm -f "$@"
        mkdir -p "$cache_dir"
        echo "$current_gen" > "$gen_seen"
    fi
}
