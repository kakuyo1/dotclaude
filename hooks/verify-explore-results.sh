#!/usr/bin/bash
# PostToolUse hook: remind to verify research-subagent results before acting on
# them. Covers Explore (codebase claims) and claude-code-guide (docs/schema
# claims) — both produce factual verdicts the parent treats as ground truth
# unless reminded otherwise.
set -euo pipefail

input=$(cat)
subagent_type=$(echo "$input" | jq -r '.tool_input.subagent_type // ""')

case "$subagent_type" in
    Explore|claude-code-guide) ;;
    *) exit 0 ;;
esac

source "$(dirname "$0")/lib/emit.sh"
emit_post_tool_context 'Verify subagent results before acting: spot-check key claims (file paths, line numbers, doc URLs, schema fields) via Read/Grep/curl. Negative claims ("not documented", "doesn'"'"'t exist", "not supported") are highest risk — the miss is invisible. On conflict with a primary source, primary source wins.'
