#!/usr/bin/bash
# One-time per-machine bootstrap. Run once after cloning:
#     bash setup.sh
#
# Touches only THIS repo's local git config — nothing global.
#
# Why this exists: core.hooksPath lives in .git/config, which git never
# clones. A fresh clone therefore has no pre-commit gate until this runs.
# The GitHub Actions workflow is the backstop for that window.

set -euo pipefail
cd "$(dirname "$0")"

git config --local core.hooksPath .githooks
chmod +x .githooks/pre-commit 2>/dev/null || true

printf 'core.hooksPath = %s\n' "$(git config --local core.hooksPath)"

# The opencode /bundle command is generated, not hand-edited: edit
# skills/bundle/assets/bundle.command.md and re-run this (or any --opencode switch).
mkdir -p "$HOME/.config/opencode/command"
cp skills/bundle/assets/bundle.command.md "$HOME/.config/opencode/command/bundle.md"
printf 'opencode /bundle command -> %s\n' "$HOME/.config/opencode/command/bundle.md"

if command -v gitleaks >/dev/null 2>&1; then
    printf 'gitleaks       = %s\n' "$(gitleaks version)"
else
    printf 'gitleaks       = NOT INSTALLED — the pre-commit hook will fail closed.\n'
    printf '                 winget install --id Gitleaks.Gitleaks --exact --accept-package-agreements --accept-source-agreements\n'
fi
