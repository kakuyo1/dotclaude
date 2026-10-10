#!/bin/sh
# git smudge filter for settings.json (see .gitattributes: filter=orca-hook).
#
# Materializes the portable ~/.orca form stored in the blob into this
# machine's absolute path, so the hook is executable right after checkout.
# Mirror of orca-hook-clean.sh.
#
# Activated per machine by `bash setup.sh`. If the driver is absent (fresh
# clone), git passes the blob through unchanged and the working file keeps
# the ~/.orca form; the clean filter on the next commit still normalizes it.

home=${HOME:-${USERPROFILE:-}}
if command -v cygpath >/dev/null 2>&1; then
    home=$(cygpath -m "$home" 2>/dev/null) || home=${HOME:-${USERPROFILE:-}}
fi
home=${home%/}

# '#' delimits and '&' means "whole match" in sed; keep them out of the path.
repl=$(printf '%s' "$home" | sed 's/[&#]/\\&/g')

exec sed "s#~/.orca/agent-hooks#${repl}/.orca/agent-hooks#g"
