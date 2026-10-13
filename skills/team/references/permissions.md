# Permission prompts

OpenCode holds an implementer's turn on a "Permission required" dialog. A dialog left
open stalls its job until someone answers it, and the watcher cannot see past it. Two
layers keep routine work moving and still put destructive requests in front of a person.

## Setup, once per machine

Before the first implementer launches, add an allow rule for the TEMP directory to
`~/.config/opencode/opencode.jsonc`:

```jsonc
"permission": {
  "external_directory": {
    "/Users/<name>/AppData/Local/Temp/**": "allow"
  }
}
```

Use the TEMP path as Git Bash shows it (`echo $TEMP`). Keep the scope to TEMP: a rule
for the home folder would let every project read outside its worktree.

Add the run's handover root too, narrowly, when the project keeps its handover folder
(`<main-repo>/.orca/**`). Without it, every handover write from an implementer raises an
"Access external directory" dialog, and a dialog the watcher cannot clear stalls the job. The
handover folder is already an allowed root for the watcher's policy, so this rule adds no reach
the watcher does not already grant. The news skill uses this form.

```jsonc
"/Users/<name>/news/.orca/**": "allow"
```

A running session keeps the config it loaded. Restart an implementer to apply a change
(see `orca-cli.md`, "Restart OpenCode and keep its session").

## What the watcher does

Each tick, for each implementer whose state is `waiting`:

1. Read the pane with `orca terminal read --screen`.
2. Parse the newest dialog that contains both "Permission required" and the option bar.
   No dialog, or a dialog without the option bar, means nothing to do.
3. Decide with `Get-PermissionDecision` in `scripts/permission.ps1`.
4. Approve: send Enter. The default choice is "Allow once". The watcher never chooses
   "Allow always".
5. Report: send nothing. Log `NEEDS YOU` once per dialog, and again after ten minutes if
   the dialog is still open.

An approval is retried at most three times for the same dialog, 15 seconds apart. If the
dialog stays after three tries, the watcher reports it: the approval did not take.

## Policy: approve or report

A dialog is **reported** when either holds:

- Its text matches a destructive command: `rm`, `rmdir`, `del`, `unlink`, `delete`,
  `Remove-Item`, `kill`, `taskkill`, `Stop-Process`, `shutdown`, `format`,
  `git push`, `git reset`, `git clean`, `git rebase`, `git checkout --`,
  `git branch -D`, `git tag -d`, `git worktree remove`, `git stash drop` or `clear`,
  or a `curl` with `-X POST|PUT|PATCH|DELETE`.
- Any path it names lies outside the job's allowed roots, or contains a `..` segment.

Otherwise the dialog is **approved**.

Allowed roots for a job:

- the job's worktree
- the job's handover folder
- `$env:TEMP`
- `~/.config/opencode`
- `~/.claude/skills`

The main repo is not an allowed root. An implementer that reaches for it is reported.

## Log lines

| Level | Line | Meaning |
| --- | --- | --- |
| INFO | `Approved once: <action>` | The watcher pressed Enter on a routine dialog. |
| WARN | `NEEDS YOU: permission not auto-approved: <action>` | A person decides in the implementer's pane. |
| ERROR | `NEEDS YOU: approval did not clear the prompt` | Three Enter presses changed nothing. Read the pane. |

## Limits

- Detection runs only while the state is `waiting`. The state seen during a dialog was
  `waiting`. Other states were not observed during a dialog, so a dialog in another state
  would go unseen. The stall warning in the watcher still fires after `-StallMinutes`.
- Only the dialog shape seen in the runs is parsed: the `Access external directory`
  kind, and the generic option bar. A new dialog shape produces no decision, so it is left
  alone rather than approved.
- A command that names no path and matches no destructive pattern is approved. The
  destructive list is a heuristic. It is the place to widen when a new command shows up
  unsafe.
- The policy was checked with the self-test below against sample dialogs only. It has not
  yet run against a live destructive prompt.

## Self-test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\team\scripts\test-permission.ps1"
```

Run it after any change to `permission.ps1`. It exits 1 when a check fails.
