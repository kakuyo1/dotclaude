#!/usr/bin/env bash
# SessionStart hook: emit caveman skill ruleset so it auto-activates every session.
# Mirrors ponytail's SessionStart activation. Native Claude injects hook stdout
# into session context, so the body IS the activation — no JSON wrapper needed.
awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$HOME/.claude/skills/caveman/SKILL.md"
