#!/bin/sh
# git clean filter for settings.json (see .gitattributes: filter=orca-hook).
#
# Orca rewrites the hook command in settings.json to a machine-absolute path on
# every machine. Two shapes have been seen: a file under an .orca/agent-hooks
# folder, and claude-hook.cmd in the home folder, either may carry a -N suffix.
# Both fold back to the portable ~/.orca form on commit, so the tracked blob is
# byte-identical across machines. Mirror: orca-hook-smudge.sh.
#
# Only a quoted value that starts with "/" or a drive letter is rewritten, so the
# ~/.orca form and the other hook commands pass through unchanged.
#
# Installed per machine by `bash setup.sh`: a filter driver lives in .git/config,
# which git never clones. git pipes the file on stdin and takes the normalized
# text on stdout. pre-commit (step 3) checks the staged result for any absolute
# hook path that survives this filter.

exec sed -E 's#"(/|[A-Za-z]:)[^"]*claude-hook\.cmd(-[0-9]+)?"#"~/.orca/agent-hooks/claude-hook.cmd"#g'
