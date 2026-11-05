#!/usr/bin/bash
# PreToolUse hook on Agent: subagents may run only on haiku. fork inherits the
# parent's model and ignores the model override, so it can never be pinned.
set -euo pipefail

source "$(dirname "$0")/lib/emit.sh"

input=$(cat)
model=$(jq -r '.tool_input.model // ""' <<< "$input")
subagent_type=$(jq -r '.tool_input.subagent_type // ""' <<< "$input")

if [ "$subagent_type" = "fork" ]; then
    emit_pre_tool_deny "Forked subagents inherit the parent's model and ignore the model override, so they cannot be limited to haiku. Spawn a named subagent_type with model: \"haiku\" instead."
elif [ "$model" != "haiku" ]; then
    emit_pre_tool_deny "Subagents may only run on haiku. Set model: \"haiku\" in the Agent call (got: ${model:-<omitted>})."
fi
