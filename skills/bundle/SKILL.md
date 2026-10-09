---
name: bundle
description: Switch which provider Claude Code talks to by rewriting HKCU\Environment, or add a new provider with --new. Also reports the active bundle, the base URL and whether a token is present.
argument-hint: "[<name>|status|--new|--help]"
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/bundle-switch.ps1:*), Bash(bash ~/.claude/bundle-switch.sh:*), Bash(bash ~/.claude/skills/bundle/scripts/bundle-recon.sh:*)
---

!`powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\bundle-switch.ps1" $ARGUMENTS`

The text above is the script's stdout; you were invoked with `$ARGUMENTS`. The
script consumes the arguments itself, so this line is the only place you see
them.

Platform: two ports of the same script exist, and the machine decides which one
runs. The embedded command above is the Windows port,
`~/.claude/bundle-switch.ps1`, which needs only PowerShell and curl.exe — what
every Windows machine has. The shell port, `bash ~/.claude/bundle-switch.sh
$ARGUMENTS`, needs bash, jq and curl: the norm on WSL and Linux, and present on
some Windows machines but absent on others, which is why the Windows port stays
the one to reach for when a shell is missing. Both read the same
`~/.claude/bundles/` and print the same output, so the rest of this file holds
either way.

If that stdout starts with `NEW BUNDLE`, the user is adding a provider: read
`references/new.md` and follow it, instead of relaying the stdout.

Otherwise relay the stdout verbatim, then add at most one sentence of
explanation.

If it does not start with `/bundle <name>` (or say `bundles:`), the switch did
NOT happen. Say so plainly. Never claim a provider switch that the output does
not show.

If the output says a new terminal is needed, say so explicitly: the registry
only affects newly created processes, so restarting `claude` in the same
terminal is not enough — a new terminal is required.

Do not read, print, echo, or run `jq` over a token. Never open
`~/.claude/bundles/*.local.json`, and never run a command that would print the
value of `ANTHROPIC_AUTH_TOKEN`.
