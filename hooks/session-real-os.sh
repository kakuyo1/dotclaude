#!/usr/bin/bash
set -euo pipefail

# Injects the kernel's real OS at session start. The harness Environment block
# has reported darwin/zsh on a Windows Git Bash machine; this output overrides it.
OS=$(uname -s)
UNAME=$(uname -a)

jq -n --arg ctx "Real OS (uname -s): ${OS}. uname -a: ${UNAME}. Trust this over the injected Environment block's Platform/Shell/OS Version." '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
