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

Both roles share the layout, the handover directory, and the boundaries below.

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

## Planner and reviewer

### Starting a run

1. Choose a short kebab-case slug (`update-check`, not `AddVersionUpdate`).

2. Create the implementer's worktree as a child of the current one, so Orca shows
   the lineage:

   ```powershell
   orca worktree create --name <slug> --parent-worktree active --json
   ```

3. Have the user open OpenCode in the new worktree and pick a model. This is a
   blocking precondition, not a nicety: the watcher resolves the implementer by
   agent identity scoped to `-ImplementerWorktreePath`, so a worktree holding only
   a plain shell terminal is no different from an empty one, and the watcher exits
   2 before it ever reads the plan. Ask in one message and name the worktree path;
   an OpenCode pane already open on the main repo is a different worktree and does
   not count.

   Verify once it reports back, before starting the watcher:

   ```powershell
   & 'C:\Users\admin\.claude\skills\team\scripts\watcher.ps1' `
     -Feature <slug> -HandoverDir <handover> `
     -ImplementerWorktreePath <implementer-worktree-path> `
     -ReviewerWorktreePath <main-repo> -Once
   ```

   Two `Resolved ... terminal:` lines mean both ends are wired. Exit code 2 means
   the implementer agent is not visible in that worktree yet.

4. Create the handover directory and start the watcher in the background, before
   writing the plan. The watcher waits for `PLAN.md` regardless, but starting it
   first means the implementer is never left idle.

   ```powershell
   $handover = "<main-repo>\.orca\team\<slug>"
   Start-Process powershell -WindowStyle Hidden -ArgumentList @(
     '-NoProfile', '-File',
     'C:\Users\admin\.claude\skills\team\scripts\watcher.ps1',
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
  against.
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

Run `/code-review` for the automated pass, then read the diff directly:

```powershell
git -C "<main-repo>" diff main...<slug>
```

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

**The watcher exits 2 with `No connected 'opencode' terminal in '<path>'`.** The
implementer agent is not running in that worktree. A plain shell terminal sitting
there does not satisfy the lookup, because a shell reports no agent identity at
all. Open OpenCode in that worktree, pick a model, then rerun.

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

**State was lost mid-run.** Rerun the watcher with the same `-Feature` and
`-HandoverDir`. It resumes from `state.json` instead of restarting the loop.

**Verify the wiring without sending anything:**

```powershell
& 'C:\Users\admin\.claude\skills\team\scripts\watcher.ps1' `
  -Feature <slug> -HandoverDir <dir> -ImplementerWorktreePath <path> `
  -ReviewerWorktreePath <main-repo> -Once
```

`-Once` prints the agents Orca can see, with their types and states, plus the
current phase. It resolves both terminals first, so exit code 2 is the same
precondition failure described above.