#!/usr/bin/bash
# Redirection to /dev/null: rewritten, not refused.
#
# This used to deny the call and name BYPASS_DEVNULL_CHECK for a real reason -- an agent that
# hides a command's output cannot see what went wrong -- but a deny spends a whole turn on it:
# the agent rewrites the command and runs it again, so the output arrives one round trip later.
# Taking the redirect out makes the same point without the round trip: the command runs, its
# output reaches the agent, and nothing is refused.
#
# The rewrite goes through `updatedInput`, with no permissionDecision, so the call is still
# subject to whatever permission handling it would have had. Exit is 0 on every path: exit 2
# blocks even when the JSON says otherwise.
#
# `# BYPASS_DEVNULL_CHECK` still means what it meant. It is checked first, and it leaves the
# command exactly as written, for the case where silence is the point.
export LC_ALL=C.UTF-8
set -euo pipefail

source "$(dirname "$0")/lib/bypass.sh"
source "$(dirname "$0")/lib/read_input.sh"

read_bash_command
bypass_check BYPASS_DEVNULL_CHECK

# Any fd, and any of >, >>, &>, &>>: `[0-9]*` is the fd digit, `&?` the `&` of `&>`, `>>?` one or
# two chevrons. The `/dev/null` is what makes it a redirect rather than an argument, so a command
# that merely names the path, such as `rm /dev/null`, is left alone.
#
# A `>/dev/null` inside a quoted string is rewritten too. Such a string is rare enough that not
# touching it would cost more than it saves.
#
# A failed rewrite allows the command unchanged rather than propagating the status: a hook that
# exits non-zero could block the call, and losing the rewrite is the smaller loss.
stripped=$(printf '%s\n' "$command" | sed -E 's/[0-9]*&?>>?[[:space:]]*\/dev\/null//g') || exit 0

if [ "$stripped" != "$command" ]; then
    jq -n --arg command "$stripped" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: { command: $command }
      }
    }'
fi

exit 0
