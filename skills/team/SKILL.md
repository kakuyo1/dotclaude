---
name: team
description: >-
  Contract for a two-agent feature workflow inside Orca, where one agent plans
  and reviews and another implements, exchanging work through handover documents
  and a watcher script until the reviewer approves. Use when the user types /team,
  asks to 开 team / 组队 / 两个 agent 配合 / 让 deepseek 出方案让 space bunny 实现,
  asks for a plan to be handed to another agent for implementation, asks for a
  review loop between two agents, or describes a plan-implement-review cycle
  across two Orca panes. Also use when a prompt points at PLAN.md and directs
  following this skill, or points at IMPLEMENTATION.md and asks for a review —
  either way this file defines which role the current agent is playing.
---

# Two-agent feature workflow

Two agents work one feature in separate Orca worktrees, passing work through
handover documents. A watcher script detects when each agent's turn ends and
types the next instruction into the other terminal.

Neither agent can observe the other directly. The handover documents are the
entire channel, which is why their formats are fixed and parsed.

## Determine the role first

Identify which agent is reading this file before acting. The prompt that led
here determines the role:

| Signal in the incoming prompt | Role | Read |
| --- | --- | --- |
| A path to `PLAN.md`, and an instruction to follow this skill | **Implementer** | [Implementer](#implementer) |
| A path to `IMPLEMENTATION.md`, and a request to review | **Planner / reviewer** | [Planner and reviewer](#planner-and-reviewer) |
| A bare feature request from the user, no other agent involved yet | **Planner / reviewer** | [Planner and reviewer](#planner-and-reviewer) |

The watcher never sends a message naming the role, because it does not track
roles. Classify from the file path in the prompt.

Both roles share the layout, the handover directory, the language rule, and the
boundaries below.

## Layout

| Role | Agent | Works in |
| --- | --- | --- |
| Planner / reviewer | Claude Code | the repo's main worktree |
| Implementer | OpenCode | a separate worktree |

Two agents editing one checkout interleave writes: a review then describes a file
state that no longer exists, and change requests land against a moving target.
Separate worktrees make review a diff, and keep exactly one agent responsible for
writing code.

## Handover directory

All handover documents live outside any worktree:

```
<main-repo>/.orca/team/<feature-slug>/
```

Process artifacts placed inside the feature worktree would otherwise land in the
commit under review.

| File | Written by | Read by |
| --- | --- | --- |
| `PLAN.md` | planner | implementer |
| `IMPLEMENTATION.md` | implementer | planner |
| `REVIEW.md` | planner | implementer |
| `state.json` | watcher | watcher only — never edit by hand |
| `watcher.log` | watcher | humans, for troubleshooting |

## Language

Every handover document and every message either agent sends the other is in English,
and plain ASCII. The watcher types the review body into the implementer's terminal
input, and that path carries ASCII intact while mangling anything else.

`PLAN.md` and `IMPLEMENTATION.md` reach the other agent by path; `REVIEW.md` travels
inline.

## Planner and reviewer

### Starting a run

1. Choose a short kebab-case slug (`update-check`, not `AddVersionUpdate`).

2. Create the implementer's worktree as a child of the current one, so Orca shows
   the lineage:

   ```powershell
   orca worktree create --name <slug> --parent-worktree active --json
   ```

3. Launch the implementer yourself, on the free model, in the new worktree. Read
   `result.worktree.id` and `result.worktree.path` out of the create JSON first —
   the whole id, not the bare repo id.

   ```powershell
   orca terminal create `
     --worktree id:<result.worktree.id> --title <slug> `
     --shell powershell.exe `
     --command "opencode --model opencode/space-bunny-free" --json
   ```

   This must be `orca terminal create`, not a hand-opened PowerShell window: Orca
   only detects the OpenCode process as agent identity `opencode` inside a terminal
   it manages, and the watcher resolves the implementer by that identity scoped to
   `-ImplementerWorktreePath`. An OpenCode pane on the main repo is a different
   worktree and does not count; the watcher exits 2 before it reads the plan.

   `--model` is why this is a two-step create rather than `worktree create
   --agent opencode`: the built-in launcher takes no per-call model argument.

   Wait for the TUI to come up, then confirm both ends are wired, before starting
   the watcher. Take the handle from `result.terminal.handle` in the create JSON,
   or from `orca terminal list --worktree id:<result.worktree.id> --json` when the
   create output omits it.

   ```powershell
   orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 90000 --json

   & "$env:USERPROFILE\.claude\skills\team\scripts\watcher.ps1" `
     -Feature <slug> -HandoverDir <handover> `
     -ImplementerWorktreePath <implementer-worktree-path> `
     -ReviewerWorktreePath <main-repo> -Once
   ```

   Two `Resolved ... terminal:` lines mean both ends are wired. Exit code 2 means
   the implementer agent is not visible in that worktree yet. Orca registers the
   agent identity a few seconds after the TUI is up, so wait 15 seconds and rerun
   once before treating it as broken; if it still fails, read the pane with
   `orca terminal read --terminal <handle> --json`.

   A bare `worktree create` may also leave a fallback shell tab beside the agent.
   It reports no agent identity, so the watcher ignores it.

4. Create the handover directory and start the watcher in the background, before
   writing the plan. The watcher waits for `PLAN.md` regardless, but starting it
   first means the implementer is never left idle.

   ```powershell
   $handover = "<main-repo>\.orca\team\<slug>"
   Start-Process powershell -WindowStyle Hidden -ArgumentList @(
     '-NoProfile', '-File',
     "$env:USERPROFILE\.claude\skills\team\scripts\watcher.ps1",
     '-Feature', '<slug>',
     '-HandoverDir', $handover,
     '-ImplementerWorktreePath', '<implementer-worktree-path>',
     '-ReviewerWorktreePath', '<main-repo>'
   )
   ```

   Pass `-ReviewerWorktreePath` explicitly. The watcher defaults it to its own
   working directory, which is the repo under review only when it was started from
   there by hand.

5. Write `PLAN.md`, then stop. The watcher delivers it and the implementer runs.

### Writing `PLAN.md`

The first line is load-bearing, and the watcher refuses to deliver a plan
without it:

```
Read and follow the "team" skill before touching any file.
```

OpenCode loads `~/.claude/skills/` automatically, so this line is what puts the
implementer under the same contract as the planner. The watcher reads only the
first line, so keep the directive on its own line.

The plan covers:

- **Scope** — what "done" means, in the user's terms.
- **Files to touch** — the specific paths expected to change. Naming them turns a
  vague task into something checkable, and gives the reviewer a diff to compare
  against. Grep the whole repository for each path or symbol the change touches —
  `installer/`, `scripts/`, `.githooks/` and the docs as well as the source tree. A
  live file naming a path that no longer exists is a defect, and the include graph
  does not show it.
- **Interfaces and constraints** — signatures, data shapes, invariants. State
  these as rules, so the implementer can tell a violation from a preference.
- **Forbidden** — what must not change: public API breaks, unrelated refactors,
  anything outside the file list, anything the user ruled out.
- **Test commands** — the exact commands that prove the work, so the implementer
  runs the same checks the reviewer will look for. Confirm the machine can run
  them before making them a gate: a stale machine path in `config/paths.json`, a
  drive that no longer exists, turns the build into an acceptance criterion the
  implementer can only report and not meet.
- **Acceptance criteria** — a checklist the implementer can verify before
  reporting done.

Where the codebase already has a pattern, point at the file that demonstrates it
rather than describing the pattern. The implementer can read code, and matching
surroundings beats a paraphrase of them.

### Reviewing a report

When the watcher supplies an `IMPLEMENTATION.md` path, review against the plan
rather than against an independent first instinct of how the feature should look.

Run `/code-review` for the automated pass (it reads the reviewer's own checkout, so it
sees nothing while the implementer's work is uncommitted), then read the diff directly:

```powershell
git -C "<main-repo>" diff main...<slug>
```

That three-dot diff compares commits, so it is empty when the branch carries none. Fall
back to the worktree:

```powershell
git -C "<implementer-worktree>" status --short
git -C "<implementer-worktree>" diff -M
```

Verify in the worktree rather than trusting the report's word: its build tree is
disposable, so run the plan's own commands there, plus any gate the implementer's shell
could not run.

Automated findings are input, not the verdict. They miss design problems, unmet
requirements, and code that is correct but wrong for this codebase. They also
carry false positives, which cost the implementer a round if passed through
unexamined.

Judge two categories separately, because they need different fixes:

- **Defects** — wrong behaviour. Name file and line, say what breaks, state the fix.
- **Requirement gaps** — acceptance criteria from the plan that were not met.
  Part of any gap traces back to plan ambiguity; when so, say so and clarify the
  plan instead of writing a finding the implementer cannot act on.

An honest partial implementation reported as partial is worth more than a
complete-looking one hiding a gap. Name gaps plainly as findings — a softened
finding costs another round.

### Writing `REVIEW.md`

The first line is the verdict, and the watcher parses only that line (`#` prefixes
and surrounding whitespace are tolerated):

```
APPROVED
```

```
CHANGES REQUESTED
```

Any other first line leaves the watcher waiting, so a typo stalls the loop.

After the verdict, list findings. Each needs file, line, what is wrong, and the
change required — specific enough to act on without interpretation.

After `APPROVED`, note anything a human should still check before shipping. The
watcher exits at that point and nothing is merged.

### Do not write code during review

Even a one-line certain fix belongs to the implementer. Keeping the write path
with a single agent is what keeps the diff readable and the review meaningful.

## Implementer

### Receiving the plan

The plan is authoritative. Follow its constraints and forbidden items exactly.
Where the plan and independent judgement disagree, implement what the plan says
and record the disagreement in the report. A silent deviation destroys the
reviewer's ability to trust the report; a recorded one is a conversation.

Work only inside the implementer worktree. Never touch the planner's checkout.
Something needed from outside the current scope is a reason to report back, not
to reach over.

### Reporting completion

When the implementation is done, write to the `IMPLEMENTATION.md` path given in
the prompt. It states:

- which files changed
- which acceptance criteria were verified, and how
- the exact commands run, with their real output
- anything left unfinished, and why

Honesty about gaps is what makes the report useful. A confident report that hides
an unfinished item costs a full round-trip to discover; an honest one costs
nothing.

Run the project's own review tooling before reporting — in Claude Code that is
`/code-review`, in OpenCode the review view (`/review`, or `diff.open` where that
build has no `/review`). This is a self-check, not the reviewer's pass.

Do not merge, push, or open a pull request. The planner decides the next step,
and a human decides what merges.

### Receiving changes

When the watcher supplies a `REVIEW.md` path, address every finding. Where a
finding is wrong, implement the rest and state the objection in the updated
report rather than skipping it silently.

Then stop and wait. The watcher routes the updated report back automatically;
polling or asking for confirmation only stalls the loop.

## Boundaries

- **Neither agent merges or pushes.** The watcher never touches git either.
- **One writer per worktree.** The planner writes only plans and reviews; the
  implementer writes only code.
- **A stalled phase is usually a permission prompt.** The watcher warns rather
  than exits, because stopping there strands the work. Answer the prompt in that
  pane and the loop resumes.
- **Rounds are capped** at 5 by default. Hitting the cap means a human should
  read the pattern: repeated findings usually indicate a flawed plan rather than
  an implementer needing more attempts.

## Troubleshooting

**Nothing happens after the plan is written.** Read `watcher.log`. The usual causes
are an unresolved terminal handle, or the implementer not running in the worktree
the watcher was told about.

**The watcher cannot find the reviewer.** Several Claude Code terminals may be
open. It selects the one in the watcher's own working directory and warns when
that choice was ambiguous; `-ReviewerTerminal <handle>` pins it.

**`watcher.log` repeats `No opencode agent is visible to Orca yet` before the plan
goes out.** Expected, not a fault: Orca lists an agent in `worktree ps` only after
it has run a turn, and the first turn is the plan. The warning stops on its own.

**The watcher exits 2 with `No connected 'opencode' terminal in '<path>'`.** The
implementer agent is not running in that worktree. A plain shell terminal sitting
there does not satisfy the lookup, because a shell reports no agent identity at
all. Rerun the `orca terminal create` from step 3 against that worktree.

**`orca` is not recognized.** Orca puts its CLI on `PATH` for the terminals it
manages, so this means the watcher was started outside one. Launch it from the
Orca-managed Claude Code pane.

**`Unknown flag --model for command: terminal create`.** The `--command` value was
split into separate arguments, so Orca parsed `--model` as one of its own flags.
`Start-Process` joins `ArgumentList` with spaces and quotes nothing; quote any
argument containing a space, as `Invoke-OrcaJson` in `watcher.ps1` does.

**The plan arrives twice, or `watcher.log` reports `went idle without an
implementation report` while the pane is still busy.** The implementer's turn was
read as finished while it was still running. OpenCode reports `waiting` mid-turn
and `done` at rest, so only `done` counts as the turn ending. Confirm what Orca
currently sees with:

```powershell
orca worktree ps --json | Select-String -Pattern 'state|agentType'
```

If a runtime introduces another resting state, the guard in the `implementing`
phase of `watcher.ps1` is the one place to widen.

**`.orca/` shows up as untracked in the main repo.** By design the handover
directory lives inside the checkout. Add `.orca/` to the project's `.gitignore`,
or a `git add -A` there stages handover documents.

**The review lands in the implementer's input box as gibberish, or sits there unsent.**
`REVIEW.md` is typed into that terminal inline, and non-ASCII does not survive the trip;
the mangled text can also fail to submit, which leaves the phase at `implementing` while
the implementer sits idle. The Language rule above is what prevents it. To recover:
clear that input box by hand, then send a short path-only message.

```powershell
orca terminal send --terminal <handle> `
  --text "The reviewer requested changes. Read <REVIEW.md path> and address every finding. Then write your report to <IMPLEMENTATION.md path> and stop." `
  --enter --wait-submit 20 --json
```

Delivery comes back as `input_accepted` even when the provider cannot confirm it, so
read the pane to check the message went.

**A review request arrives for a report you have already read.** When the phase flips
back to `implementing`, the watcher can re-read the `IMPLEMENTATION.md` still on disk
and hand it over as if it were new. Compare the report's modification time with your
`REVIEW.md`; when the report is older, the implementer is still working on the changes
you asked for — write nothing and wait.

**The implementer's worktree starts from `origin/main`.** A local commit that has not
been pushed is absent from its tree, so a plan that leans on one asks for work the
implementer cannot see.

**State was lost mid-run.** Rerun the watcher with the same `-Feature` and
`-HandoverDir`. It resumes from `state.json` instead of restarting the loop.

**Verify the wiring without sending anything:**

```powershell
& "$env:USERPROFILE\.claude\skills\team\scripts\watcher.ps1" `
  -Feature <slug> -HandoverDir <dir> -ImplementerWorktreePath <path> `
  -ReviewerWorktreePath <main-repo> -Once
```

`-Once` prints the agents Orca can see, with their types and states, plus the
current phase. It resolves both terminals first, so exit code 2 is the same
precondition failure described above.