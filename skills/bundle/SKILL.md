---
name: bundle
description: Switch which provider Claude Code talks to by rewriting HKCU\Environment, or add a new provider with --new. Also reports the active bundle, the base URL and whether a token is present.
argument-hint: "[<name>|status|--new|--help]"
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/bundle-switch.ps1:*), Bash(bash ~/.claude/bundle-switch.sh:*)
---

!`powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\bundle-switch.ps1" $ARGUMENTS`

The text above is the script's stdout; you were invoked with `$ARGUMENTS`. The
script consumes the arguments itself, so this line is the only place you see
them.

Platform: there are two ports of the same script. The embedded command above is
the Windows one, `~/.claude/bundle-switch.ps1` (PowerShell + curl.exe; there is
no usable bash). On WSL or Linux use the shell port instead — invoke
`bash ~/.claude/bundle-switch.sh $ARGUMENTS` — which needs bash, jq and curl.
Both read the same `~/.claude/bundles/` and differ only in toolchain, so the
output and the rest of this file are identical.

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
