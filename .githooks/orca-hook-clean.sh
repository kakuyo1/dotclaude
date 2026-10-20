#!/bin/sh
# git clean filter for settings.json (see .gitattributes: filter=orca-hook).
#
# Orca rewrites the hook command in settings.json to a machine-absolute path on
# every machine. Two shapes have been seen: anything under an .orca/agent-hooks
# folder (claude-hook.cmd, orca-agent-hook.exe claude, ...), and claude-hook.cmd
# in the home folder, either may carry a -N suffix. Both fold back to the
# portable ~/.orca form on commit, so the tracked blob is byte-identical across
# machines. Mirror: orca-hook-smudge.sh.
#
# Pebrel installs under the user's program folder and writes that absolute path
# too; it folds to ~/AppData/Local/Programs/Pebrel, matched on the runtime/
# folder so a new binary name under it still normalizes.
#
# Only a quoted value that starts with "/" or a drive letter is rewritten, so the
# ~/.orca form and the other hook commands pass through unchanged.
#
# The .orca/agent-hooks rule replaces the whole path prefix, not a fixed file
# name: Orca ships a new binary name every so often (claude-hook.cmd ->
# orca-agent-hook.exe), and a name-based match silently let the next one through.
#
# Installed per machine by `bash setup.sh`: a filter driver lives in .git/config,
# which git never clones. git pipes the file on stdin and takes the normalized
# text on stdout. pre-commit (step 3) checks the staged result for any absolute
# hook path that survives this filter.

exec sed -E \
    -e 's#"(/|[A-Za-z]:)[^"]*/(\.orca/agent-hooks/)#"~/\2#g' \
    -e 's#"(/|[A-Za-z]:)[^"]*claude-hook\.cmd(-[0-9]+)?"#"~/.orca/agent-hooks/claude-hook.cmd"#g' \
    -e 's#"(/|[A-Za-z]:)[^"]*/(Pebrel/runtime/)#"~/AppData/Local/Programs/\2#g'
