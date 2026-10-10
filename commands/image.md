---
description: Generate an image with the traxnode-image key and save it locally
argument-hint: [-d <dir>] [-m <model>] <prompt>
allowed-tools: Bash(powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/skills/bundle/scripts/image.ps1:*)
---

Run this one command with the arguments unchanged, then reply with its stdout verbatim:

    powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\skills\bundle\scripts\image.ps1" "$ARGUMENTS"

If stdout contains `IMAGE FAILED`, say the image was not generated and quote the reason. Do not retry.
