#!/usr/bin/bash
# PostCompact hook: bump a per-session generation counter that other hooks
# read to detect "did compaction happen since I last fired?" Avoids each
# downstream hook having to scan the transcript on every fire.
#
# Generation file: /tmp/claude-${UID}-state/compact-events/<session_id>.gen — single
# monotonic integer, incremented on every compaction (auto or manual).
# Consumer hooks store the gen value at their last fire and compare:
# if it grew, compaction happened in the interval and the consumer
# should reset its own state.
set -euo pipefail

DIR=/tmp/claude-${UID}-state/compact-events
mkdir -p "$DIR"

input=$(cat)
SID=$(jq -r '.session_id // empty' <<< "$input")
[ -n "$SID" ] || exit 0

FILE="$DIR/$SID.gen"
gen=0
if [ -f "$FILE" ]; then
    gen=$(cat "$FILE")
    case "$gen" in *[!0-9]*|"") gen=0 ;; esac
fi

echo $((gen + 1)) > "$FILE"
