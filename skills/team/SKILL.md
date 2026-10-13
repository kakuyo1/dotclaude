---
name: team
disable-model-invocation: true
description: >-
  Multi-job workflow inside Orca: one OpenCode implementer per job, with the
  orchestrator reviewing, for up to five jobs at once (bug fixes, docs, features).
  Work passes through handover documents and one watcher script that routes prompts,
  approves routine OpenCode permission dialogs, and reports destructive ones. Invoked
  by the user with /team.
---

# Multi-job workflow

A run holds one to five jobs. Each job has its own implementer in its own Orca worktree.
The orchestrator is the session the user talks to: it plans, reviews, and answers help
requests. Work passes through handover documents. One watcher script routes prompts
between agents, approves routine permission dialogs, and logs the requests that need the
orchestrator.

Neither agent can observe the other directly. The handover documents are the entire
channel, which is why their formats are fixed and parsed.

## Determine the role first

Identify which agent is reading this file before acting. The prompt that led here
determines the role:

| Signal in the incoming prompt | Role | Read |
| --- | --- | --- |
| A path to `PLAN.md`, and an instruction to follow this skill | **Implementer** | [Implementer](#implementer) |
| A prompt reporting that a help answer is in `HELP.md` | **Implementer** | [Asking for help](#asking-for-help) |
| A path to `IMPLEMENTATION.md`, and a request to review | **Reviewer** | [Reviewing a report](#reviewing-a-report) |
| A help request in `HELP.md`, to answer | **Reviewer** (as helper) | [Answering a help request](#answering-a-help-request) |
| A bare request from the user to start jobs, no other agent involved yet | **Planner** (the orchestrator) | [Planner](#planner) |

The watcher never sends a message naming the role, because it does not track roles.
Classify from the file path in the prompt. The orchestrator reviews, so it is also the
reviewer for every job.

## Layout

| Role | Agent | Works in |
| --- | --- | --- |
| Orchestrator (planner and reviewer) | Claude Code session the user talks to | the repo's main worktree |
| Reviewer pane (optional) | Claude Code pane, pinned with `-ReviewerTerminal` | the repo's main worktree |
| Implementer | OpenCode, one per job | that job's own worktree |

Two agents editing one checkout interleave writes: a review then describes a file state
that no longer exists, and change requests land against a moving target. Separate
worktrees make review a diff, and keep exactly one agent responsible for writing code.

The Orca commands, their flags, and the output fields they return are in
[references/orca-cli.md](references/orca-cli.md).

## Handover directory

All handover documents live outside any worktree, in one folder per job:

```
<main-repo>/.orca/team/<job-slug>/
```

Two run-level files sit beside them, in `<main-repo>/.orca/team/`:

- `jobs.json`: the run's job list, read by the watcher. The orchestrator writes it.
- `watcher.log`: every job's lines, each tagged with its slug.

Process artifacts placed inside a job worktree would otherwise land in the commit under review.

| File | Written by | Read by |
| --- | --- | --- |
| `REQUEST.md` | orchestrator | orchestrator, reviewer |
| `PLAN.md` | orchestrator | implementer |
| `IMPLEMENTATION.md` | implementer | reviewer |
| `REVIEW.md` | reviewer | implementer |
| `HELP.md` | implementer (requests), reviewer as helper (answers) | both: see [references/help.md](references/help.md) |
| `state.json` | watcher | watcher only: never edit by hand |

## Language

Every handover document and every message either agent sends the other is in English,
and plain ASCII. The watcher types each prompt into the other terminal, and that path
carries ASCII intact while mangling anything else.

Every prompt names its document by path instead of quoting it, which is also what keeps
the text short enough to submit in one go. A path is one ASCII line that the reading
agent resolves itself, in whatever encoding the file uses.

## Permissions

Two layers keep OpenCode from stalling on routine reads and writes.

1. **Configuration, once per machine.** A `permission.external_directory` allow rule for
   the TEMP directory in `~/.config/opencode/opencode.jsonc`. Set it before the first
   implementer launches, because a running session keeps the config it loaded. The exact
   block is in [references/permissions.md](references/permissions.md).
2. **The watcher's monitor.** While an implementer is `waiting` on a "Permission required"
   dialog, the watcher presses Enter (Allow once) when the request is routine. A destructive
   command, or a path outside the job's worktree, handover folder, TEMP, or the OpenCode
   config and skills folders, is logged as `NEEDS YOU` and left for a person. The watcher
   never chooses "Allow always".

The policy, its allowed roots, and its limits are in
[references/permissions.md](references/permissions.md). Its self-test is
`scripts/test-permission.ps1`.

## Planner

The orchestrator does the setup for a run and then reviews. The watcher routes the prompts.
To start a run, follow [references/run.md](references/run.md). It covers one job and five
alike: preflight, split the request, write each plan, register the repo, create each job's
worktree and implementer, write `jobs.json`, and start the watcher.

### Writing `PLAN.md`

The first line is load-bearing, and the watcher refuses to deliver a plan without it:

```
Read and follow the "team" skill before touching any file.
```

OpenCode loads `~/.claude/skills/` automatically, so this line is what puts the
implementer under the same contract as the orchestrator. The watcher reads only the first
line, so keep the directive on its own line.

The plan covers:

- **Scope**: what "done" means, in the user's terms.
- **Ordering**: a worktree that already holds uncommitted work (a previous job's,
  say) has it committed as the plan's first step, before any edit: review reads a diff,
  and two jobs in one diff cannot be reviewed. Commits are the implementer's to make,
  only when the plan or the user asks for one.
- **Files to touch**: the specific paths expected to change. Naming them turns a vague
  task into something checkable, and gives the reviewer a diff to compare against. Confirm
  each named path exists, or say that the job creates it. Do not guess a path: a guessed
  path returns 404 and costs an implementer a round. Grep the whole repository for each
  path or symbol the change touches, including the scripts, hooks, and docs as well as the
  source tree. A live file naming a path that no longer exists is a defect.
- **Interfaces and constraints**: signatures, data shapes, invariants. State these as
  rules, so the implementer can tell a violation from a preference.
- **Forbidden**: what must not change: public API breaks, unrelated refactors, anything
  outside the file list, anything the user ruled out. Scope each exclusion to the
  behaviour you mean to hold rather than to a path: a frozen file freezes its comments too,
  and they go stale the moment the behaviour moves.
- **Test commands**: the exact commands that prove the work, so the implementer runs the
  same checks the reviewer will look for. Confirm the machine can run them before making
  them a gate. A real application run is optional evidence, never an acceptance criterion,
  because starting an app writes the operator's own profile. A documentation job has no
  build: its test commands are the link or lint checks the repo already has, or none. A
  screenshot at a narrow width needs the DevTools protocol on this Windows host, because
  Chrome clamps `--window-size` (see [references/run.md](references/run.md)).
- **Acceptance criteria**: a checklist the implementer can verify before reporting done.

Where the codebase already has a pattern, point at the file that demonstrates it rather
than describing the pattern. The implementer can read code, and matching surroundings
beats a paraphrase of them.

## Reviewer

The orchestrator reviews by default. When the watcher logs `ACTION: Review requested`,
read the job's report, verify it, and write `REVIEW.md`. When it logs
`ACTION: Help requested`, append a solution entry to `HELP.md`. A pinned reviewer pane,
if one exists, receives the same requests one at a time, and works on the job named in the
prompt and nothing else.

### Reviewing a report

When the report is ready, review it against the plan rather than against an independent
first instinct of how the feature should look.

The implementer commits only when the plan says so, which makes the worktree's own diff the
subject. Read the branch name from `result.worktree.branch` rather than building it:

```powershell
git -C "<implementer-worktree>" status --short
git -C "<implementer-worktree>" log --oneline -3
git -C "<implementer-worktree>" diff -M <base>..HEAD
```

`/code-review` reads the reviewer's own checkout and sees nothing while the work is
uncommitted, so run it once there is a commit.

Verify in the worktree rather than trusting the report's word: run the plan's own commands
there, and re-measure each number the report states. [references/run.md](references/run.md)
has the full checklist.

Automated findings are input, not the verdict. They miss design problems, unmet
requirements, and code that is correct but wrong for this codebase. They also carry false
positives, which cost the implementer a round if passed through unexamined.

Judge two categories separately, because they need different fixes:

- **Defects**: wrong behaviour. Name file and line, say what breaks, state the fix.
- **Requirement gaps**: acceptance criteria from the plan that were not met. Part of any
  gap traces back to plan ambiguity; when so, say so and clarify the plan instead of
  writing a finding the implementer cannot act on.

An honest partial implementation reported as partial is worth more than a
complete-looking one hiding a gap. Name gaps plainly as findings: a softened finding costs
another round.

### Writing `REVIEW.md`

The first line is the verdict, and the watcher parses only that line (`#` prefixes and
surrounding whitespace are tolerated):

```
APPROVED
```

```
CHANGES REQUESTED
```

Any other first line leaves the watcher waiting, so a typo stalls the job.

After the verdict, list findings. Each needs file, line, what is wrong, and the change
required, specific enough to act on without interpretation.

After `APPROVED`, note anything a human should still check before shipping. The watcher
marks the job approved at that point, and nothing is merged.

### Answering a help request

The watcher logs `ACTION: Help requested` when the implementer has written a request to
`HELP.md` and stopped. Read [references/help.md](references/help.md) before writing the
answer: it holds the entry format and the steps. Append one solution entry to `HELP.md` and
write nothing else. The answer is advice; the implementer applies it.

### Do not write code during review

Even a one-line certain fix belongs to the implementer. Keeping the write path with a
single agent is what keeps the diff readable and the review meaningful.

## Implementer

### Receiving the plan

The plan is authoritative. Follow its constraints and forbidden items exactly. Where the
plan and independent judgement disagree, implement what the plan says and record the
disagreement in the report. A silent deviation destroys the reviewer's ability to trust
the report; a recorded one is a conversation.

Work only inside your job's worktree. Never touch the orchestrator's checkout or another
job's worktree. Something needed from outside the current scope is a reason to report
back, not to reach over.

### Asking for help

Ask the reviewer when you are stuck, rather than trying a fourth fix to the same problem:
a reviewer who reads the trail usually sees the cause sooner. Ask when either holds:

- The same problem has survived three attempts at a fix: the same test or error, after
  changes.
- You are unsure what the plan requires or how the code behaves, and reading the plan
  and the code does not settle it.

Read [references/help.md](references/help.md) before writing the request. Write it to
`HELP.md`, then end your turn. The watcher sends the answer as a prompt; until then, make
no edits. The reviewer answers when it reads the log, so an answer can wait; it still
arrives.

### Reporting completion

When the implementation is done, write to the `IMPLEMENTATION.md` path given in the
prompt. It states:

- which files changed
- which acceptance criteria were verified, and how
- the exact commands run, with their real output
- anything left unfinished, and why

Honesty about gaps is what makes the report useful. A confident report that hides an
unfinished item costs a full round-trip to discover; an honest one costs nothing.

Run the project's own review tooling before reporting: in Claude Code that is `/code-review`,
in OpenCode the review view (`/review`, or `diff.open` where that build has no `/review`).
This is a self-check, not the reviewer's pass.

Do not merge, push, or open a pull request. The reviewer decides the next step, and a human
decides what merges.

### Receiving changes

When the watcher supplies a `REVIEW.md` path, address every finding. Where a finding is
wrong, implement the rest and state the objection in the updated report rather than
skipping it silently.

Then stop and wait. The watcher routes the updated report back automatically; polling or
asking for confirmation only stalls the loop.

## Boundaries

- **Neither agent merges or pushes.** The watcher never touches git either.
- **One writer per worktree.** The orchestrator writes plans, reviews, and help answers;
  each implementer writes code only in its own worktree. A help answer goes to `HELP.md`
  and nothing else.
- **Five jobs per run at most.** A sixth is refused before anything is created.
- **Reviews go to the orchestrator.** A pinned reviewer pane, if any, takes them one at a
  time, help requests first.
- **Help requests are capped** at 5 per job by default (`-MaxHelp`). They do not count as
  rounds.
- **Permission dialogs are approved or reported.** Routine ones are approved by the watcher.
  A destructive or out-of-scope one is logged as `NEEDS YOU`, and a person answers it in the
  implementer's pane ([references/permissions.md](references/permissions.md)).
- **A stall with no `NEEDS YOU` line has another cause.** Read the implementer's pane.
- **Rounds are capped** at 5 per job by default. Hitting the cap ends that job only; the
  other jobs keep running. Repeated findings usually indicate a flawed plan rather than an
  implementer needing more attempts, so read the pattern before rerunning.

## Troubleshooting

**Nothing happens after the plans are written.** Read `watcher.log`; every line names its
job. The usual causes are an unresolved implementer terminal (the watcher exits 2 and names
the jobs involved), or an implementer not running in the worktree listed in `jobs.json`.

**The watcher logs `ACTION:` and nothing else happens.** Expected. The orchestrator must act,
and the watcher does not wake it. Check the log at each turn, or schedule a check while jobs
run. A reviewer pane is optional. Do not pin the orchestrator's own session as the reviewer
pane.

**The watcher exits 2 with `No connected 'opencode' terminal in '<path>'`.** That job's
implementer is not running in its worktree. A plain shell terminal sitting there does not
satisfy the lookup, because a shell reports no agent identity at all. Rerun the
`orca terminal create` from run.md, step 6, against that worktree.

**`worktree create` fails with an unknown repo.** Orca has not registered the project yet.
Run `orca repo add --path <path> --json` first (run.md, step 4).

**`orca` is not recognized.** Orca puts its CLI on `PATH` for the terminals it manages, so
this means the watcher was started outside one. Launch it from an Orca-managed terminal.

**`Unknown flag --model for command: terminal create`.** The `--command` value was split
into separate arguments, so Orca parsed `--model` as one of its own flags. `Start-Process`
joins `ArgumentList` with spaces and quotes nothing; quote any argument containing a space,
as `Invoke-OrcaJson` in `watcher.ps1` does.

**The plan arrives twice, or an implementer is sent a prompt while still busy.** The
implementer's turn was read as finished while it was still running. OpenCode reports
`waiting` while a dialog or a tool call is open and `done` at rest, so only `done` counts as
the turn ending. Confirm what Orca currently sees with
`orca worktree ps --json`, and read the agent `state` values.

**`.orca/` shows up as untracked in the main repo.** By design the handover directory lives
inside the checkout. Add `.orca/` to the project's `.gitignore`, or a `git add -A` there
stages handover documents.

**A prompt is stuck in an agent's input box, or arrives as gibberish.** `orca terminal send`
answers `ok` for keystrokes that were accepted and never submitted. The watcher proves
delivery to an implementer by waiting for its turn to start, and logs an ERROR when it does
not. A prompt sent to a pinned reviewer pane is not checked this way. Either way, read the
pane with `orca terminal read --terminal <handle> --screen --json`.

Text parked in the input box did not submit. Clear the box by hand; the watcher sends again
on its next pass, and stops after a couple of attempts so it cannot spam a pane that is
stuck. The Language rule above is what keeps this from starting.

**A pane shows `QUEUED`.** The prompt is waiting behind the running turn. It will run. Do
not resend it, or the prompt runs twice.

**A permission dialog stalls a job.** Read `watcher.log`. A `NEEDS YOU` line names the action:
answer it in the implementer's pane with Allow once or Reject. If a routine dialog came back
after a press, the log shows `approval did not clear the prompt`. Read that pane with
`--screen`.

**The self-test fails.** `scripts/test-permission.ps1` exits 1 when the policy changed in a way
a sample dialog no longer matches. Read the failing line before changing the policy.

**A review request arrives for a report you have already read.** The implementer ended its
turn without rewriting `IMPLEMENTATION.md`, so the report predates the review it is meant to
answer. The watcher tests exactly that, the report's write time against the review's, and
re-sends the change request rather than asking for a review of stale work.

**A job sits in `help-queued` or `review-queued`.** Only a pinned reviewer pane holds these
phases, and that pane takes one job at a time. Read the pane. Without a pin, the phase moves on
at once and the `ACTION` line carries the request.

**The phase stays at `helping`.** Expected until the orchestrator appends a solution entry to
that job's `HELP.md`. Read the request and answer it.

**The watcher exits 3.** At least one job reached `MaxHelp` or `MaxRounds`. The other jobs keep
running and the watcher exits once all are finished, so read `watcher.log` for the slug. For
`MaxHelp`, group that job's `HELP.md` requests by keyword: a keyword that repeats means the same
problem came back, which usually points at the plan or the environment rather than at the
implementer.

**A new job needs a new run.** The watcher reads `jobs.json` once, at startup. Add jobs by
starting another run, with its own jobs file and its own implementers.

**State was lost mid-run.** Rerun the watcher with the same `-JobsFile`. Each job resumes from
its own `state.json` instead of restarting.

**A run where every job is finished** exits at once without sending anything. Its exit code
reflects the final states: 0 if all approved, 3 if one was exhausted.

**Verify the wiring without sending anything:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.claude\skills\team\scripts\watcher.ps1" `
  -JobsFile <main-repo>\.orca\team\jobs.json -ReviewerWorktreePath <main-repo> -Once
```

`-Once` prints the agents Orca can see, with their types and states, and each job's phase. It
resolves every implementer terminal first, so exit code 2 is the same precondition failure
described above.

## Reference files

- [references/run.md](references/run.md): the run, step by step, with preflight, verification,
  and lessons from the first real run.
- [references/orca-cli.md](references/orca-cli.md): the Orca commands the skill uses, with flags
  and output fields.
- [references/permissions.md](references/permissions.md): OpenCode's permission setup, the
  monitor's policy, and its limits.
- [references/help.md](references/help.md): the help dialogue's entry format and steps.
