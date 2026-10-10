---
name: bundle
description: Switch which provider Claude Code talks to by rewriting HKCU\Environment, sync a provider into opencode's config, or add a new provider with --new. Reports the active bundle, the base URL and whether a token is present. Each CLI reads only its own section below.
argument-hint: "[<name>|status|--new|--help]"
disable-model-invocation: true
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/skills/bundle/scripts/claudecode/bundle-switch.ps1:*), Bash(bash ~/.claude/skills/bundle/scripts/claudecode/bundle-switch.sh:*), Bash(bash ~/.claude/skills/bundle/scripts/bundle-recon.sh:*)
---

## Which CLI you are running in

Decide from your own identity, not from this file. If you are Claude Code, follow
**Claude Code** and skip **opencode**. If you are opencode, follow **opencode** and
skip **Claude Code**. A section you skip does not apply to you at all.

If you are another agent and cannot tell from your own identity: when this skill
was loaded through the Skill tool, Claude Code has already run the `!` line in
**Claude Code** below, so its output appears in your context. If that output is
missing and the line shows as a raw backtick-wrapped command, you are not in
Claude Code: follow **opencode**. If you read this file directly with Read, the
`!` line proves nothing, because the raw text looks the same in every CLI. Then
ask the user which CLI they are using rather than guessing.

## Claude Code

!`powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\skills\bundle\scripts\claudecode\bundle-switch.ps1" $ARGUMENTS`

The text above is the script's stdout; you were invoked with `$ARGUMENTS`. The
script consumes the arguments itself, so this line is the only place you see
them.

Platform: two ports of the same script exist, and the machine decides which one
runs. The embedded command above is the Windows port,
`~/.claude/skills/bundle/scripts/claudecode/bundle-switch.ps1`, which needs only PowerShell and curl.exe — what
every Windows machine has. The shell port, `bash ~/.claude/skills/bundle/scripts/claudecode/bundle-switch.sh
$ARGUMENTS`, needs bash, jq and curl: the norm on WSL and Linux, and present on
some Windows machines but absent on others, which is why the Windows port stays
the one to reach for when a shell is missing. Both read the same
`~/.claude/bundles/` and print the same output, so the rest of this section holds
either way.

If that stdout starts with `NEW BUNDLE`, the user is adding a provider: read
`references/claudecode.md` and follow it, instead of relaying the stdout.

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

## opencode

opencode does not run this file's `!` line. The `bundle` command does it: its
template (`assets/bundle.command.md`) runs `scripts/opencode/bundle-switch.ps1`. Work
from the command's output, not from this section's `!`-free text.

That script syncs rather than switches. `<name>` probes the bundle's models over
the OpenAI route and merges that bundle's provider entry into
`~/.config/opencode/opencode.jsonc`. Other providers and the default model stay as
they are, and the Claude Code registry is not touched. The key comes from
`~/.local/share/opencode/auth.json` under the bundle name.

When the user runs `/bundle <name>`:

1. Relay the script's stdout verbatim.
2. If it starts with `NEW BUNDLE`, read `references/opencode.md` and follow its
   "Adding a provider" section.
3. If it starts with `NOT SWITCHED`, say the sync did not happen and quote the
   reason. The config was not changed.
4. On success, name the models it reports and tell the user to restart opencode.
   Its config is read only at startup.

Never open `auth.json` to print a key, and never ask for a key in the chat. The
probe spends real quota, so a sync is a deliberate action, not a check.
