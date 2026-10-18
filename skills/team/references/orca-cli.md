# Orca CLI for the team skill

The commands the team skill uses, with flags and output fields checked against
`orca <command> --help` on the Windows 11 machine this skill runs on. When a flag is
not listed here, run `orca <command> --help` before relying on it.

## Basics

- Every command takes `--json`. Use it for anything read by a script or an agent.
- The envelope is `{ "id", "ok", "result", "_meta" }`. Read `result`. A non-zero exit
  code means failure, and `ok: false` means the same.
- Read `orca` output through a file, not the PowerShell pipeline. The pipeline corrupts
  the UTF-8 box-drawing and CJK characters in agent previews. `watcher.ps1` shows the
  pattern (`Start-Process` with `-RedirectStandardOutput`).
- Selectors: `id:<id>`, `path:<path>`, `name:<displayName>`, `branch:<branch>`,
  `active`, `current`, `worktree:<worktree-id>`.
- `orca` is on `PATH` inside Orca-managed terminals. Outside one, it lives at
  `%LOCALAPPDATA%\Programs\orca\resources\bin\orca`.

## Repos

| Command | Use | Fields to read |
| --- | --- | --- |
| `orca status --json` | Check that the app and runtime are ready. | `ok` |
| `orca repo add --path <path> --json` | Register a repo. Required before worktrees can be created in it. | `result.repo.id` |
| `orca repo list` | List registered repos. | |

## Worktrees

| Command | Use | Fields to read |
| --- | --- | --- |
| `orca worktree create --repo <selector> --name <slug> --no-parent --json` | New worktree for an unrelated repo. | `result.worktree.id`, `.path`, `.branch`, `.baseRef` |
| `orca worktree create --repo <selector> --name <slug> --parent-worktree active --json` | New worktree linked to the caller's worktree (same repo). | same |
| `orca worktree list --json` | All Orca worktrees. | |
| `orca worktree show --worktree <selector> --json` | One worktree. | |
| `orca worktree ps --limit 20 --json` | Agents per worktree. | `result.worktrees[].agents[]`: `agentType`, `state`, `mainAgent.state` |
| `orca worktree rm --worktree <selector> --json` | Remove a worktree and its local branch. Destructive: ask the user first. | |

Facts from the runs:

- Orca chooses the worktree path, under its workspace folder. Read `result.worktree.path`
  and never predict it. The first run predicted a path and got a different one.
- `result.worktree.branch` is the branch to use. The skill once assumed
  `<git-user>/<slug>`. A repo with no Orca git username got `<slug>`.
- `--no-parent` keeps lineage clean for an unrelated repo. Use `--parent-worktree active`
  only for work in the caller's own repo.
- `--force` does not delete a branch. Orca keeps branches it cannot prove merged.

## Terminals

| Command | Use | Fields to read |
| --- | --- | --- |
| `orca terminal create --worktree <selector> --title <t> --shell powershell.exe --command "<cmd>" --json` | Start an agent in a worktree. `--shell` names the shell the pane runs as. `--command` is typed into it. | `result.terminal.handle` |
| `orca terminal list [--worktree <selector>] --json` | Find handles. | per row: `handle`, `worktreePath`, `agentIdentity`, `connected`, `orphaned`, `title` |
| `orca terminal wait --terminal <h> --for tui-idle --timeout-ms 90000 --json` | Wait until a TUI is ready. `--for exit` also exists. | `result.wait.satisfied` |
| `orca terminal read --terminal <h> --screen --json` | Read the rendered screen. | `result.terminal.tail` (lines), `source` |
| `orca terminal send --terminal <h> --text "<t>" --enter --wait-submit 20 --json` | Send a prompt. | `result.send.accepted`, `prompt.stages`, `warnings` |
| `orca terminal send --terminal <h> --enter --json` | Press Enter: confirms the default choice of a dialog. | `accepted` |
| `orca terminal send --terminal <h> --text $'\x03' --json` | Ctrl+C. Twice exits OpenCode. | |
| `orca terminal send --terminal <h> --text $'\x1b[C' --json` | Right arrow: moves a dialog's selection. | |
| `orca terminal close --terminal <h> --json` | Close one pane. `--tab` closes the tab. `--worktree <selector> --all` closes all terminals in a workspace. | `result.close.ptyKilled` |

Facts from the runs:

- `terminal read` without `--screen` returns the accumulated output with escape codes
  removed. Repainted lines come back as stacked fragments. Use `--screen` to see a dialog
  or a prompt as a person would. Without the flag, the `source` field has varied between
  `screen` and `stream`.
- A send that reports `input was accepted, but this provider cannot report delivery`
  is acceptance only. For OpenCode, confirm delivery by reading the pane, or by the watcher
  seeing the implementer's turn start.
- `QUEUED` in a pane means the prompt waits behind the running turn. Do not resend it.
  A resend duplicates the prompt.
- Agent identities seen: `claude`, `opencode`. A plain shell pane has no `agentIdentity`,
  and the watcher ignores it. The shell pane that `worktree create` opens beside the agent
  is one of these.
- Agent states seen: `working`, `waiting`, `done`. `waiting` was the state while a
  permission dialog was open. `done` means the turn ended.
- A new agent gets its identity a few seconds after its TUI starts. If the watcher cannot
  resolve it, wait 15 seconds and retry before treating it as broken.

## Paths

Orca reports the home folder as `/Users/<name>/...`. PowerShell in this shell reports
`TEMP` and `USERPROFILE` in that form too, and Git Bash prints the same paths. Some Windows
system paths that PowerShell prints appear under `C:/`. Compare
paths after normalizing: `permission.ps1`'s `ConvertTo-PermissionPath` does this, and
`test-permission.ps1` checks a drive-letter root against a `/Users/` path.

## Recipes

**Find an agent's handle:**

```bash
orca terminal list --worktree "id:<worktree-id>" --json
```

Filter the rows for `agentIdentity` equal to `opencode` or `claude`.

**Restart OpenCode and keep its session:**

1. Send Ctrl+C twice to the pane.
2. Read the pane. The exit output prints a line like `opencode -s ses_...`.
3. Relaunch: `orca terminal send --terminal <h> --text "opencode -s <id>" --enter --json`.
   The model comes from `model` in `~/.config/opencode/opencode.jsonc`.

The session comes back with its context. A change to `~/.config/opencode/opencode.jsonc`
takes effect only at this launch.

**Check that a worktree is clean before reusing it:**

```bash
git -C "<worktree-path>" status --short
git -C "<worktree-path>" log --oneline -3
```
