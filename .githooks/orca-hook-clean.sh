#!/bin/sh
# git clean filter for settings.json (see .gitattributes: filter=orca-hook).
#
# Orca rewrites the hook command in settings.json to a machine-absolute path
# on every machine, e.g. C:/Users/<you>/.orca/agent-hooks/claude-hook.cmd.
# Folding that back to the portable ~/.orca form on commit keeps the tracked
# blob byte-identical across machines. Mirror: orca-hook-smudge.sh.
#
# Activated per machine by `bash setup.sh` (a filter driver lives in
# .git/config, which git never clones). git pipes the file on stdin and takes
# the normalized text on stdout.

exec sed -E 's#([A-Za-z]:/[^"]*/\.orca/agent-hooks)#~/.orca/agent-hooks#g'
