---
description: Sync a provider into opencode's config, or add one with --new
---

Run this and relay its stdout verbatim, then stop:

    powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\skills\bundle\scripts\opencode\bundle-switch.ps1" $ARGUMENTS

If stdout starts with `NEW BUNDLE`, read `~/.claude/skills/bundle/references/opencode.md`
and follow its "Adding a provider" section instead of relaying.

Restart opencode after a sync: it reads its config once at startup.
