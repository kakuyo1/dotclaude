---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
disable-model-invocation: true
---

Write a handoff document summarising the current conversation so a fresh agent can continue the work. Save to the temporary directory of the user's OS (`$TMPDIR`, else `/tmp`; `%TEMP%` on Windows) - not the current workspace.

Include a "suggested skills" section in the document, naming which skills the next agent should call the Skill tool for.

Do not duplicate content already captured in other artifacts (specs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

Before writing, check that each decision the user made in this conversation is recorded in the repo: an ADR under `docs/adr/`, or the doc that owns the topic. Record any that is missing, then reference it by path. A decision held only in the handoff is invisible to every later session that does not receive that file.

Start the document with a "Read first" list of the repo paths the next session must read before editing (ADRs, prototypes, docs). Have that session restate the acceptance criteria before its first edit.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.
