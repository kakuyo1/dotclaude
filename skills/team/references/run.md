# Running jobs

One run holds one to five jobs. A job is any change with a plan, an implementer, and a
review: a bug fix, a documentation change, or a feature. One job is the same flow with
one entry in the jobs file.

## Agents

| Agent | Count | Works in | Does |
| --- | --- | --- | --- |
| Orchestrator (the session the user talks to) | 1 | main repo | Splits the request, writes each job's plan, creates worktrees and implementers, reviews reports, answers help requests, starts the watcher. |
| Implementer | 1 per job | the job's own worktree | Implements that job only. |
| Reviewer pane | 0 by default | main repo | Optional. Only with `-ReviewerTerminal`. |

The orchestrator is the reviewer. Do not open a separate Claude pane for review: the
orchestrator reads each report and writes the verdict itself. A pane is needed only when
someone other than the orchestrator must review.

The watcher is one process for the whole run. It routes prompts to implementers, logs
the requests that need the orchestrator, and approves routine permission dialogs.

## Limits

- Five jobs per run. A sixth is refused: stop before creating anything, tell the user
  the limit, and ask them to split the list into separate runs.
- Two jobs that change the same files conflict at merge. The watcher does not check this.
  Name the overlap in both jobs' `REQUEST.md`, and flag it to the user.

## Preflight

Run these before creating anything. Each one fails loudly if the setup is wrong.

- Shell. `uname -s` shows `MINGW64` on the Windows machine (Git Bash). Scratch files go
  under `$TEMP`. `/tmp` is not shared with the Windows tools.
- Orca. `orca status --json` returns `ok`.
- Proxy. Foreign hosts need the proxy at `127.0.0.1:7890`:
  `curl -sS -x http://127.0.0.1:7890 --max-time 15 -o "$TEMP/probe.html" -w '%{http_code}\n' https://github.com`
  prints `200`.
- Project. A git repo with at least one commit. Run `git config user.name` to check the
  identity the branches use.
- OpenCode permissions. The TEMP allow rule is in place (see `permissions.md`, Setup).
  Check it before the first implementer launches.
- OpenCode model. `~/.config/opencode/opencode.jsonc` names `deepseek/deepseek-flash`
  as `model`, the default the TUI starts with (step 6 explains why it cannot be a flag).
  The free models are refused from this network as abusive traffic.

## Steps

1. **Split the request.** One job per item the user listed. Pick a distinct kebab-case
   slug for each (`fix-login-redirect`, `update-install-docs`). For an ambiguous item,
   take the most likely reading, and state it in that job's plan under Scope.

2. **Write `REQUEST.md` per job** in `<team-root>\<slug>\`, in English and plain ASCII.
   Read the file back after writing it (see the path lessons below).

3. **Write `PLAN.md` per job**, following "Writing PLAN.md" in SKILL.md. Before naming any
   path in the plan, confirm it exists, or state that the job creates it. Do not guess.
   A URL cited in the plan must already have been fetched and read.

4. **Register the repo** if Orca does not know it yet:

   ```powershell
   orca repo add --path <main-repo-windows-path> --json
   ```

   Use `id:<result.repo.id>` as the selector from here on.

5. **Create each job's worktree.** Use `--no-parent` for a repo unrelated to the
   orchestrator's worktree, and `--parent-worktree active` for the same repo:

   ```powershell
   orca worktree create --repo id:<repo-id> --name <slug> --no-parent --json
   ```

   Record `result.worktree.id`, `.path`, and `.branch`. Orca picks the path.

6. **Start each implementer** in its worktree:

   ```powershell
   orca terminal create --worktree id:<result.worktree.id> --title <slug> `
     --shell powershell.exe --command "opencode" --json
   orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 90000 --json
   ```

   Use `terminal create`, not a hand-opened window: Orca reports the OpenCode identity
   only for terminals it manages. Every implementer uses `deepseek/deepseek-flash`,
   set as the default model in `~/.config/opencode/opencode.jsonc`:
   `"model": "deepseek/deepseek-flash"`. OpenCode v2's TUI takes no model flag;
   `--model` belongs to `opencode run`, which the watcher never uses.

7. **Write `jobs.json`** at `<team-root>\jobs.json`, with the paths from step 5:

   ```json
   [
     { "slug": "fix-login-redirect", "implementerWorktree": "<path from step 5>" },
     { "slug": "update-install-docs", "implementerWorktree": "<path from step 5>" }
   ]
   ```

8. **Dry run, then start the watcher.** `-Once` prints the agents Orca sees and each job's
   phase. It exits 2 if an implementer terminal is missing, and names the job:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
     "$env:USERPROFILE\.claude\skills\team\scripts\watcher.ps1" `
     -JobsFile <team-root>\jobs.json -ReviewerWorktreePath <main-repo> -Once
   ```

   Then start it for real, as a background task of the shell. Add `-ReviewerTerminal`
   only when a reviewer pane exists:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
     "$env:USERPROFILE\.claude\skills\team\scripts\watcher.ps1" `
     -JobsFile <team-root>\jobs.json -ReviewerWorktreePath <main-repo>
   ```

   Confirm the process is alive. A `watcher start` line in `watcher.log` within a few
   seconds is the proof:

   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
     Where-Object { $_.CommandLine -match '-File.*watcher\.ps1' } |
     Select-Object ProcessId, CommandLine
   ```

   Start it with `powershell.exe` in the background, not through `Start-Process`: a
   `Start-Process` launch from Git Bash exited without creating a process and without
   writing to `watcher.log`.

9. **Review as reports arrive.** When the log shows `ACTION: Review requested`, verify the
   report (see below), then write `REVIEW.md`. For `ACTION: Help requested`, append a
   `solution` entry to `HELP.md`.

## Verifying a report

Before writing a verdict, check the report's claims yourself:

- The commit exists: `git -C <worktree> log --oneline -3`. Read the branch from
  `result.worktree.branch`.
- The planner checkout is untouched: `git -C <main-repo> status --short` is empty.
- Each number and file the report states is re-measured. Re-run the plan's own commands.
- Open each screenshot with the Read tool. A narrow-width capture can be cropped by the
  tool that made it.

A claim that does not hold is a finding. Write it as one.

## Lessons from the first real run

- **Do not guess paths.** Two raw URLs the plan guessed returned 404. A GitHub API call
  returned a rate-limit message, and it was saved as if it were a directory listing.
  Check the response body, not only the HTTP status, before using a file.
- **Do not clone a large repo through the proxy.** A `git clone --depth 1` stalled at
  about 115 MB and never finished. Fetch the files a page needs with raw URLs, one request
  per file. The anonymous GitHub API allows 60 requests an hour and is not a reliable source.
- **Chrome on Windows clamps `--window-size` below about 500 px.** A 390 px screenshot
  taken that way is cropped. Set the narrow width through the DevTools protocol
  (`Emulation.setDeviceMetricsOverride`) or Playwright's viewport. Write that into the
  plan's test commands, and check the screenshot is not cropped.
- **Handover file paths.** The orchestrator wrote files to the wrong folders twice. After
  any handover write, list the real folder and read the file. Use the paths from
  `jobs.json` and `$TEMP`, not paths retyped from memory.
- **Stopping a background launch leaves its children running.** Stopping the shell's
  background task did not stop the `git` process it started. Find the process with
  `Get-CimInstance Win32_Process`, stop it by ID, and check that it is gone.
- **A foreground command times out at four minutes** (exit 143). Poll with sleeps under
  three minutes, or run the wait in the background.
- **A pane showing `QUEUED`** holds a prompt behind the running turn. Resending duplicates it.
- **Restart OpenCode, do not rebuild the job.** Ctrl+C twice, then relaunch with the
  session id it printed. The new session keeps its context. A corrupt clone was replaced
  this way: a fresh session in the same clean worktree.
- **The reviewer pane was not needed.** The orchestrator reviewed directly, so the pane
  only cost a session and a pinning step. The watcher now runs without one.
- **Two watcher bugs found by the first dry run.** Windows PowerShell 5.1 emits a JSON
  array as one `object[]`, so piping it through `@()` produced one entry. A `.Count` on a
  single-value pipeline failed under strict mode. Both are fixed in `watcher.ps1`. Assign
  parsed JSON directly, and wrap every pipeline you count in `@()`.

## Monitoring

The watcher cannot wake the orchestrator. A log line waits until the orchestrator next
reads the log, so check it at each turn, or schedule a check while jobs run.

```powershell
Get-Content "<team-root>\watcher.log" -Tail 20
```

Read the lines by their tag:

- `ACTION:` the orchestrator must act: review or help.
- `NEEDS YOU:` a person must decide a permission dialog (see `permissions.md`).
- `WARN` and `ERROR` lines name the job they concern.

A job's `state.json` holds its phase. The phases are `implementing`, `help-queued`,
`helping`, `review-queued`, `reviewing`, then `approved`, `exhausted`, or `stopped`.

The watcher exits when every job is terminal: 0 when all were approved, 3 when a job was
exhausted, 4 when a job hit an unknown phase. A finished job does not stop the others.
