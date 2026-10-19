#!/usr/bin/bash
set -euo pipefail

source "$(dirname "$0")/lib/emit.sh"

input=$(cat)
sid=$(jq -r '.session_id // empty' <<< "$input")
dir="$HOME/.claude/progress/$sid"

emit_pre_tool_deny "Task tools are disabled here: TaskCreate and TaskUpdate open the task panel in the chat. Track progress instead by writing one JSON file per task to ${dir}/<id>.json, using the Write tool (create the folder with mkdir -p first if it is missing). Format: {\"id\": \"1\", \"subject\": \"short title\", \"activeForm\": \"present-tense label\", \"status\": \"pending\" | \"in_progress\" | \"completed\"}. Use a numeric string id. Rewrite the file to change its status. Do not list the tasks in your reply."
