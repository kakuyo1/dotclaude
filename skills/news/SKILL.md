---
name: news
disable-model-invocation: true
description: >-
  Two-track news digest built on the team workflow. Two jobs crawl international news (BBC, The Guardian, Al Jazeera, NPR) and tech frontier sources (Hacker News, arXiv cs.AI/cs.LG/cs.CL, Techmeme, Simon Willison's Weblog), each keeping 25-30 English items. Each job runs one crawl script and writes summaries; the scripts fetch, check, and build the candidate list. Reuters and Ars Technica are off unless requested. The orchestrator removes duplicates and selects 20 stories, then fills the page template with them, so no page is written from scratch. The page is written into the project the skill was triggered from, and the run's worktrees are removed afterwards. Invoked by the user with /news.
---

# Daily news digest

Three stages, one page. Stages 1 and 3 are [team](../team/SKILL.md) runs: invoke the `team`
skill and follow its planner section and `references/run.md`. Stage 2 is the orchestrator's
own work. This skill fixes the jobs, the handover formats, and the page; the team workflow
itself is unchanged.

Everything stays in English. Titles and summaries are not translated.

Where things are:

- `scripts/` fetches, parses, and checks feeds and links in parallel, and fills the page
  template. Use these rather than writing new fetch code.
- `template/news-template.html` is the page. Stage 3 fills it; it is not regenerated.
- `references/crawl-workflow.md` is the crawl procedure and its timings.
- `references/template.md` is how the template is filled, checked, and changed.
- `references/pitfalls.md` lists what the runs got wrong, so it is not repeated.

## Sources

| Track | Source | Feed |
| --- | --- | --- |
| International | BBC News, world | `https://feeds.bbci.co.uk/news/world/rss.xml` |
| International | The Guardian, world | `https://www.theguardian.com/world/rss` |
| International | Al Jazeera English | `https://www.aljazeera.com/xml/rss/all.xml` |
| International | NPR, news | `https://feeds.npr.org/1001/rss.xml` |
| International | Reuters, via Google News | `https://news.google.com/rss/search?q=when:24h+site:reuters.com&hl=en-US&gl=US&ceid=US:en` |
| Tech | Hacker News | `https://news.ycombinator.com/rss` |
| Tech | arXiv cs.AI, cs.LG, cs.CL | `https://rss.arxiv.org/rss/cs.AI`, `.../cs.LG`, `.../cs.CL` |
| Tech | Techmeme | `https://www.techmeme.com/feed.xml` |
| Tech | Ars Technica | `https://feeds.arstechnica.com/arstechnica/index` |
| Tech | Simon Willison's Weblog | `https://simonwillison.net/atom/everything/` |

All ten feeds answered 200 through the proxy when this skill was written, but two sources are
off by default because their articles cannot be reached on this machine: Reuters (its Google News
links resolve to a 401 interstitial) and Ars Technica (its article pages are behind a WAF). Both
are listed in `scripts/crawl_track.py` and run only with `--include-blocked`, which the user must
ask for. The feeds are fetched through the proxy at `127.0.0.1:7890`; see the preflight in `run.md`.

Quirks to plan for:

- arXiv feeds are empty on weekends and on some weekdays. A track that gets nothing from
  arXiv fills those slots from its other sources, and says so in its report.
- Google News links are redirects to the publisher. Follow them through the proxy and store
  the final URL. If one does not resolve, keep the `news.google.com` link and say so.
- The Hacker News feed has no point counts. Front-page order is its attention signal.

## Preflight

1. The project. It is the git repo the skill was triggered from, the current working directory.
   If that is not a git repo with at least one commit, stop and tell the user. Add `.orca/` to
   `.git/info/exclude`, not to `.gitignore`: the handover folder lives there, and the project's
   tracked files stay untouched.
2. The design file. Confirm `references/DESIGN.md` exists in this skill's folder
   (`~/.claude/skills/news/references/DESIGN.md`).
3. The proxy and Orca checks from `run.md`.
4. The run manifest. Create `<project>/.orca/team/news-run.json` before the first worktree.
   Record every worktree and branch this run creates (path, id, branch) as soon as
   `orca worktree create` returns. Cleanup reads only this file. A branch or worktree that is
   not listed stays, even if its name looks similar.

## Stage 1: two crawl jobs

Start one team run with two jobs: `news-international` and `news-tech`. Each job has its own
worktree and implementer. Neither worktree receives a commit: the crawl writes only to the
handover folder.

The implementer does not write fetching code and does not write `CANDIDATES.md` by hand. It runs
three commands and writes one JSON file. The commands are fixed in the PLAN, and the procedure is
in [references/crawl-workflow.md](references/crawl-workflow.md). A PLAN that asks for its own
fetcher is wrong: say so and use the scripts.

The PLAN gives the implementer these steps, with the job's track substituted:

1. `python scripts/crawl_track.py --track <international|tech> --handover <handover>`. It fetches
   the feeds, applies the 48-hour window, the 8-per-source cap, and the round-robin order (stops
   at 30), widens to the full list when fewer than 25 remain, and fetches article pages. It writes
   `items.json`. Blocked sources are off unless the user asks for them (`--include-blocked`).
2. Read `items.json`. For each item, write a summary from its `text` field, not the title, and
   store it in `summaries.json` as `{"<id>": "<summary>"}`. Summaries are for the items the
   implementer keeps; at least 25 must have one.
3. `python scripts/build_candidates.py <handover>`. It checks each Link and Image through the
   proxy and writes `CANDIDATES.md`.

The summary rules are the implementer's to follow:

- Each summary is 1 to 3 sentences, 60 words at most. It states only facts the source gives,
  keeps the source's own figures and attribution, and adds no context from memory and no
  adjectives such as "groundbreaking".
- If an item's `text` is empty, summarise from `description`. If both are empty or only a
  headline, leave the item out of `summaries.json`.

`build_candidates.py` owns everything else, so the implementer does not copy fields by hand:

- Titles and summaries become ASCII: dashes become hyphens and other characters become entities.
- Image is the feed image if it answers 200, else the `og:image` if that does, else `none` when no
  URL exists, or `unverified` when URLs exist but none answer. No image URL is constructed.
- A Link that fails after one retry drops its item, and the drop is listed in the output.

The block format it writes is:

```
## 1
Track: International
Source: BBC News
Title: <verbatim English title>
Published: <as the feed states it>
Link: <article URL>
Image: <image URL> | none | unverified
Summary: <1-3 sentences>
```

Tech items may add a `Discussion:` line with the Hacker News comments URL.

A crawl job's `IMPLEMENTATION.md` is a short paste of the three commands' output, not a report
to review. The orchestrator does not read it. The mechanical checks replace the review:

- `scripts/check_candidates.py CANDIDATES.md` checks the block count, the fields, ASCII, the
  dashes, and the summary length.
- `scripts/check_urls.py CANDIDATES.md` rechecks every Link and Image through the proxy.

When the watcher shows `ACTION: Review requested` for a crawl job, the orchestrator runs both
checks, writes `REVIEW.md` with the results, and does not read the implementer's report. A failing
check is a finding. Crawl reports have no diff, so the worktree check is `git status --short`
returning nothing.

## Stage 2: dedupe and select (orchestrator)

Read both `CANDIDATES.md` files, 50 to 60 items in total. If fewer than 40 items exist, stop
and report which job came up short, rather than curating a thin list.

1. Group items about the same event: the same announcement or incident covered by several
   sources. Keep the entry with the stronger summary, and list the others under an
   `Also covered by:` line with their links. Different angles with new facts count as one
   story.
2. Select 20 stories. Aim for 10 per track. If one track has fewer than 8 strong stories,
   give the other track the extra slots and say so. Judge strength by reach and consequence,
   then by the source's own ranking.
3. If fewer than 20 unique stories remain, deliver fewer and say so. Never pad the list with
   duplicates.

Write `SELECTED.md` into the design job's handover folder (stage 3, after its run starts).
Each entry uses the `CANDIDATES.md` block, plus:

```
Rank: <1-20>
Section: International | Technology
Also covered by: <Source> <link>; <Source> <link>
```

Omit the `Also covered by:` line when there is no duplicate.

## Stage 3: the page (from the template, no team run)

The page is built from `template/news-template.html`, the approved 2026-10-13 page with its
stories removed. The orchestrator fills it from `SELECTED.md` with a script, so no agent writes
HTML and no team run is needed. The design and the template are described in
[references/template.md](references/template.md).

1. Write `SELECTED.md` into `<project>/.orca/team/news-html/` (stage 2).
2. Fill the template. It writes into the project root, so no worktree is needed.

   ```bash
   node ~/.claude/skills/news/scripts/fill_template.mjs \
     --selected <project>/.orca/team/news-html/SELECTED.md \
     --date <YYYY-MM-DD> --out <project>/news-<YYYY-MM-DD>-<HHMM>.html
   ```

   The script refuses to overwrite an existing file. Time from `date +%H%M`.
3. Screenshot and check the page. `shoot_page.mjs` writes `desktop.png` (1280px) and `mobile.png`
   (390px) into the handover folder, and checks image boxes and horizontal overflow. Exit 0 is
   required.

   ```bash
   node ~/.claude/skills/news/scripts/shoot_page.mjs \
     --page <project>/news-<YYYY-MM-DD>-<HHMM>.html --out <project>/.orca/team/news-html
   ```

4. Check the page's own rules: `grep -c '<article'` must print 20; the dash and non-ASCII
   counts must be 0; no `<script`, `<link`, or `@font-face`. The filler enforces the dashes,
   placeholders, and ASCII on its output, so these checks confirm rather than discover.
5. Open both screenshots with the Read tool, spot-check three story links through the proxy, and
   write `REVIEW.md` in the handover folder.

The page is written straight into the project root, so there is no worktree to copy from. It is
uncommitted until the user says otherwise (see Delivery).

Design calls are fixed by the template: Plantin falls back to Georgia; cards and the lead sit on
white; no yellow accent; light-only. To change the design, edit the template, not the generated
page, and run the regression check in references/template.md.

## Monitoring

The watcher cannot wake the orchestrator, and sleep-and-check loops miss events between checks. While
a stage runs, start a background wait instead. It exits on the next `ACTION:` or `Finished:` line
added to `watcher.log`, and the exit notifies the orchestrator at once. Lines already in the log
are skipped, because the log is shared across runs:

```bash
LOG=<project>/.orca/team/watcher.log; N=$(wc -l < "$LOG")
for i in $(seq 1 120); do tail -n +$((N+1)) "$LOG" | grep -qE 'ACTION:|Finished:' && break; sleep 15; done
tail -n +$((N+1)) "$LOG"
```

Run it with `run_in_background`. Each `ACTION:` line ends the wait, so handle it and start the wait
again. The 120 iterations cap the wait at 30 minutes.

## Delivery and cleanup

Run this only after stage 3 passes its checks and the orchestrator has reviewed the page. A
run that stopped before delivery keeps its worktrees and branches, and the report names the
stage that stopped. Whether to delete failed work is the user's call.

1. The page is already in the project root from stage 3, uncommitted. Confirm the file exists
   and that `git -C <project> status --short` lists only it.
2. Remove the worktrees. For each worktree in `news-run.json`, run
   `orca worktree rm --worktree id:<id> --force --json`. Orca removes the worktree and its local
   branch when it can prove the branch merged. `--force` is needed because the run leaves
   untracked files behind.
3. Branches that Orca keeps are unmerged. Do not delete them with `git branch -D` from this
   skill: the run's hook refuses that command, and deleting unmerged work is the user's call.
   List the manifest branches that still exist
   (`git -C <project> rev-parse --verify --quiet refs/heads/<branch>`) and ask the user before
   removing any. Only branches named in the manifest are ever candidates.
4. Verify. `git -C <project> worktree list` and `git -C <project> branch --list` must show no
   manifest entry. Report the output.

The handover folder under `.orca/team/` stays. It holds the candidate lists, the selection,
and the screenshots, which are the record of how the page was built.

## Final report

Give the user:

- the path to the HTML file in the project root
- what cleanup removed: the worktrees from the manifest, the branches Orca removed, the branches
  still present and waiting for the user, and the handover folder that stayed
- the count per track, and the stories removed as duplicates
- any feed that failed, what replaced it, and the output of `check_urls.py` for any `unverified`
  image or failed link
- the design calls made, which are fixed in the template: Plantin falls back to Georgia; no
  yellow accent, since the page has no subscribe button or radio card; the layout is light-only
  because DESIGN.md is light

Stop at this point. Committing or publishing the page is outward-facing, so it waits for the
user's go-ahead.
