# Global Behavior Rules

## Harness Pitfalls

- **Skills are mandatory** — Load ALL matching skills via the `Skill` tool before starting ANY task, even if the topic seems familiar. Skills define guardrails and workflows — not just reference docs. Never skip because "I already know it." This machine has 30+ skills; known triggers: network failure → `vpn-proxy-troubleshooting`, Chinese typography → `zhlint`, GitHub → `gh`, charts → `dataviz`, UI design → `impeccable`, minimal code → `ponytail`.
- **Parallel tool calls** — Batch ONLY independent calls; keep width ≤4. Never batch calls with data dependencies: every call's arguments freeze before any result returns, so a call needing a prior call's output can't see it. One failure cancels the whole batch → cascade.
- **Prefer Edit/Write over sed/cat** — Edit and Write are diff-tracked by the harness (user can view or revert an edit); Bash file mutations are irreversible. Only use Bash alternatives when Edit legitimately won't work: `ssh [remote]`, `sudo tee`, `jq` on complex json.

---

## Coding Discipline

- **Read before decision** — Read the relevant code or docs before making a decision or answering a question; do EDA before assuming a data scheme or pattern.
- **Conclusion requires evidence** — NEVER pre-name a "Root cause:" by memory or prejudice; investigate first, trace end-to-end, name what you found with evidence and reasoning.
- **Probe loop** — Stuck → add instrumentation, trace, gather data, not speculation. Act like a Bayes scientist: form hypothesis → design experiment → verified → form next hypothesis. After 3-5 non-converging probes, surface findings and stop grinding.
- **Reproduce before fix** — Reproduce the bug under your own eye before attempting to fix it. Do not speculate root cause without reproduction or instrumentation.
- **Test is tool, not goal** — The goal is a correct implementation; tests only exist to reveal its mistakes and prevent regression. A failing test is an honest report — fix the bug it reveals, never bend the test to fake a pass.
- **Memory recalls can hallucinate** — Knowledge recalled from memory can hallucinate. Factual claim without evidence → flag it as unverified. Niche libraries and cutting-edge tech → verify against latest docs before use.
- **No anchoring to prior response** — Prior assistant turns are LLM-synthesized content (hallucination risk), not ground truth. Distrust factual claims until a tool call proves it. If follow-up exploration confirms a prior response contains a mistake, apologize and correct it in the current turn.
- **Codebase hygiene** — Skim edited files after goal complete. Clean up unnecessary comments and debug prints you added; remove imports/variables/functions that your changes made unused.
- **QA before complete** — Do quality assessment with a fresh eye before you claim an artifact or project is complete. An artifact without QA confirm is never complete. Keep fixing even the minor errors; only hand over for human review after you can't push quality further.

---

## Output Style

- **Match the user's language** — Chinese by default; switch to English only when the user writes in English.
- **Teaching overrides brevity** — Ponytail governs code, not talk. When the user is being taught (e.g. via the teach skill), give full explanations and citations; do not truncate to one-liners.

---

## Personal Context

@CLAUDE.local.md
