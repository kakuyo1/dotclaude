# Help dialogue

The help dialogue is one file where a stuck implementer asks the planner for help and
the planner answers. It is `HELP.md`, in the handover directory beside `PLAN.md` and
`REVIEW.md`. The watcher routes each entry: a request goes to the reviewer's pane, and
the answer goes back to the implementer's pane. The watcher reads only the headings, so
the format is fixed.

## Entry format

Each entry starts with one heading line. Its body is free text up to the next heading.

```
## 1 | request | implementer | keyword: token-refresh-race

Tried: ...
```

| Field | Values |
| --- | --- |
| number | Next integer, starting at 1. For readers only: the watcher routes on order. |
| kind | `request` from the implementer, or `solution` from the helper. |
| role | `implementer` for requests, `helper` for solutions. |
| keyword | Kebab-case name for the problem, such as `token-refresh-race`. |

The keyword makes the file searchable. Every request about one problem uses the same
keyword, so `grep "keyword: token-refresh-race" HELP.md` returns the whole history.
Choose it from the problem once, then reuse it on every follow-up.

Append only. Never edit or delete an earlier entry, because the next helper reads the
history.

## Asking (implementer)

A request states, in this order:

1. The problem, in one sentence.
2. What you tried: one line per attempt, with the change and the exact result (error
   text, failing test, file and line).
3. The question: what you need explained or decided.
4. The files to read, as paths in your worktree. Cite them rather than pasting them.

Then end your turn. Write nothing else and make no edits until the answer arrives. The
watcher sends the answer to you as a prompt.

If the answer does not work, write a new request with the same keyword. Say what the
answer was and why it failed. Do not ask about something the plan already settles:
follow the plan, and record the question in your report.

## Answering (helper)

1. Read the request and the entries before it.
2. Read the cited files in the implementer's worktree. Read only. Verify the cause
   yourself before trusting the request's account: a grep or a read of the code path
   is usually enough.
3. Append one `solution` entry with the same keyword. Include:
   - Cause: what is wrong, with file, line, and evidence. Say "not sure" when the
     evidence does not settle it.
   - Fix: the concrete change. A snippet is fine; the implementer applies it.
   - Check: the command or observation that shows the fix worked.
   - Plan conflict, only when it applies: if the plan is wrong or silent, state the
     rule to follow. The implementer records the deviation in its report.
4. Write nothing else. Do not edit the implementer's worktree or `PLAN.md`. A solution
   is advice, and the implementer owns every write.
