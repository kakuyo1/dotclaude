---
name: news
disable-model-invocation: true
description: >-
  Two-track news digest built on the team workflow. Two jobs crawl international news (BBC, The Guardian, Al Jazeera, NPR) and tech frontier sources (Hacker News, arXiv cs.AI/cs.LG/cs.CL, Techmeme, Simon Willison's Weblog), each keeping 25-30 English items. Each job runs one crawl script and writes summaries; the scripts fetch, check, and build the candidate list. Reuters and Ars Technica are off unless requested. The orchestrator removes duplicates and selects 20 stories, then fills the page template with them, so no page is written from scratch. The page is written into the project the skill was triggered from, and the run's worktrees are removed afterwards. Invoked by the user with /news.
---

# Daily news digest

Three steps, one page. Stage 1 is a [team](../team/SKILL.md) run: invoke the `team` skill and
follow its planner section and `references/run.md`. Stages 2 and 3 are the orchestrator's work,
done with scripts, with no team run.

Everything stays in English. Titles and summaries are not translated.

Where things are:

- `scripts/`: feed and article fetching, the crawl filter, the plan and selection writers, and the
  page filler and screenshot check. Use these rather than writing new fetch or HTML code.
- `template/news-template.html`: the page. Stage 3 fills it; it is not regenerated.
- `references/crawl-workflow.md`: what the crawl guarantees and what the implementer does.
- `references/template.md`: how the template is filled, checked, and changed.
- `references/pitfalls.md`: what past runs got wrong. Read it before changing a script or a feed.

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

Reuters and Ars Technica are off by default, because their articles cannot be reached through the
proxy. They are listed in `scripts/crawl_track.py` and run only with `--include-blocked`, which the
user must ask for. Feeds go through the proxy at `127.0.0.1:7890`.

Quirks to plan for:

- arXiv is often empty, on weekends and some weekdays. The track fills from its other sources.
- Hacker News has no descriptions and no point counts. The crawl reads each item's article page,
  and front-page order is its attention signal.
- Techmeme permalinks answered 403 in the 2026-10-13 run. The crawl drops them before summarising.

## Run folder

Each run writes to one folder, named for the minute it starts:

```
<project>/.orca/team/YYYY-MM-DD-HH-mm/
```

Take the name from `date +%Y-%m-%d-%H-%M` at the start of Preflight. `<run>` below means this
folder. It holds the run manifest `news-run.json`, the team run's `jobs.json` and `watcher.log`, one
folder per job (`news-international/`, `news-tech/`), and `news-html/` for the selection, the
screenshots, and `REVIEW.md`. The page itself goes in the project root.

Never reuse a run folder. The watcher resumes from the `state.json` files in it, so a second run
there would inherit the first run's phases. If the name already exists, take the next minute's name. The 2026-10-13 run
predates this layout; its unstamped `.orca/team/news-*` folders are its record.

## Preflight

1. The project is the current working directory. It must be a git repo with at least one commit.
   Add `.orca/` to `.git/info/exclude` (not `.gitignore`), so the handover folder stays out of
   the project's tracked files.
2. Run the proxy and Orca checks from `run.md`.
3. Create the run manifest `<run>/news-run.json` before the first worktree. Record each worktree
   (path, id, branch) as soon as `orca worktree create` returns it. Cleanup reads only this file.

## Stage 1: two crawl jobs (team run)

Start one team run with two jobs, `news-international` and `news-tech`, in `<run>`. Each job has its
own worktree and implementer. Neither commits. Start the watcher with `-JobsFile <run>/jobs.json`:
the stop in Monitoring finds it by that folder name.

Before the run, write each job's plan with the script. Do not hand-write it:

```bash
python scripts/write_crawl_job.py --track international --handover <run>/news-international
python scripts/write_crawl_job.py --track tech --handover <run>/news-tech
```

The script writes `REQUEST.md` and `PLAN.md`, with the commands, paths, and rules filled in. Use
`PLAN.md` as it is. The implementer then runs three commands:

1. `crawl_track.py` fetches the feeds and each candidate's article page. It keeps an item only when
   its Link answers 200 and its text has at least 25 words, so dead or textless items never reach
   the implementer. It writes `items.json`.
2. The implementer writes `summaries.json`, one summary per item, from the item's `text` field.
3. `build_candidates.py` writes `CANDIDATES.md`. It reuses the Link results from step 1 and checks
   the images. The implementer then runs `check_candidates.py`.

Summary rules: 1 to 3 sentences, 60 words at most. Only facts the text gives, with the source's own
figures and attribution. Nothing from memory, and no adjectives such as "groundbreaking".

No review for crawl jobs. The implementer writes `CANDIDATES.md` and a one-line `IMPLEMENTATION.md`. The
watcher needs that line to treat the turn as finished, and without it the watcher re-sends the plan.
The watcher then logs `ACTION: Review requested` for each job. That line is expected. The orchestrator
does not write `REVIEW.md` for either job, and does not run the checks again. When both `CANDIDATES.md`
files exist, start Stage 2 at once.

A crawl that exits 1 has fewer than 25 usable items. The job still finishes, and the track goes to
selection with what it has. Take the count per source from the `sources` list in `items.json`, and report it in the final report. The cause is the
48-hour window. Ask the user before widening it with `--since`, and do not widen it silently.

## Stage 2: select (orchestrator)

1. List both candidate files compactly. The list shows each candidate's summary and the pairs with
   similar titles:

   ```bash
   python scripts/select.py list <run>/news-international/CANDIDATES.md <run>/news-tech/CANDIDATES.md
   ```

   Open a full CANDIDATES.md only for a story the summary cannot settle.
2. Choose 20 stories, aiming for 10 per track. If one track has fewer than 8 strong stories, give the
   other track the extra slots and say so. Judge by reach and consequence, then by the source's own
   order. Group the same event, and list the other sources under `--also`. If fewer than 20 unique
   stories remain, deliver fewer and say so. Never pad.
3. Build `SELECTED.md`. Picks are in rank order, and each `--pick` names one candidates file:

   ```bash
   python scripts/select.py build --out <run>/news-html/SELECTED.md \
     --pick <run>/news-international/CANDIDATES.md:9,23,22 --pick <run>/news-tech/CANDIDATES.md:12,7 \
     --also "<run>/news-international/CANDIDATES.md:9=Al Jazeera English <link>"
   ```

   The first pick is rank 1. Each block is copied from its candidate, with Rank, Section, and
   `Also covered by` added.

## Stage 3: the page (no team run)

1. Fill the template. It writes into the project root and refuses to overwrite a file. Take HHMM
   from `date +%H%M`:

   ```bash
   node scripts/fill_template.mjs --selected <run>/news-html/SELECTED.md \
     --date <YYYY-MM-DD> --out <project>/news-<YYYY-MM-DD>-<HHMM>.html
   ```

2. Screenshot and check the layout. The script needs Chrome: pass `--chrome <path>`, or set the
   `CHROME_PATH` environment variable, or put `chrome` or `msedge` on `PATH`. It writes `desktop.png`
   and `mobile.png`, and exit 0 is required:

   ```bash
   node scripts/shoot_page.mjs --page <project>/news-<YYYY-MM-DD>-<HHMM>.html --out <run>/news-html
   ```

3. Check the page rules. `grep -c '<article'` equals the number of selected stories. The dash and
   non-ASCII counts are 0. There is no `<script`, `<link`, or `@font-face`. The filler already
   enforces these, so these checks confirm the output.
4. Open both screenshots with the Read tool. Spot-check three story links through the proxy. Write
   `REVIEW.md` in the `news-html` folder.

The page stays uncommitted until the user says otherwise (see Delivery). Design calls are fixed by
the template: Plantin falls back to Georgia; cards and the lead sit on white; no yellow accent; light
only. To change the design, edit the template and run the regression check in `references/template.md`.

## Monitoring

The watcher cannot wake the orchestrator, and sleep-and-check loops miss events between checks. Start
a background wait instead, and run it with `run_in_background`.

The wait returns on the first of three events: both `CANDIDATES.md` files exist, a `Help requested`
line (answer it as the team's help reference describes, then start the wait again), or `Finished:`.

When both files exist, the wait stops the run's watcher before it returns, so nothing is left logging
for these jobs. The stop does not prevent the re-send. The one-line `IMPLEMENTATION.md` does: the
2026-10-14 run re-sent the tech plan about a minute after its `CANDIDATES.md` was written, because the
plan had told the implementer to write no report. The stop only ends the run, and it comes after both
files exist, so the first job to finish stays exposed until the other one is done. The wait does the
stop itself, because the orchestrator acts only when a background task returns. A help request leaves
the watcher running, because it still routes the answer.

```bash
RUN_NAME=YYYY-MM-DD-HH-mm; RUN=<project>/.orca/team/$RUN_NAME; LOG="$RUN/watcher.log"; N=$(wc -l < "$LOG")
for i in $(seq 1 360); do
  [ -f "$RUN/news-international/CANDIDATES.md" ] && [ -f "$RUN/news-tech/CANDIDATES.md" ] && break
  tail -n +$((N+1)) "$LOG" | grep -qE 'Help requested|Finished:' && break
  sleep 5
done
if [ -f "$RUN/news-international/CANDIDATES.md" ] && [ -f "$RUN/news-tech/CANDIDATES.md" ]; then
  powershell.exe -NoProfile -Command 'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "powershell.exe" -and $_.ProcessId -ne $PID -and $_.CommandLine -like "*watcher.ps1*" -and $_.CommandLine -like "*'"$RUN_NAME"'*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }'
fi
tail -n +$((N+1)) "$LOG"
```

The stop matches a watcher whose command line names both `watcher.ps1` and the run folder, so only
this run's watcher is stopped. The 360 iterations cap the wait at 30 minutes. On timeout the watcher
keeps running; read `watcher.log` and the implementer pane before deciding anything.

Stages 2 and 3 do not use the watcher.

## Delivery and cleanup

Run this only after stage 3 passes its checks and the orchestrator has reviewed the page. A run that
stopped before delivery keeps its worktrees and branches, and the report names the stage that
stopped. Whether to delete failed work is the user's call.

0. If the watcher is still running (the wait timed out), stop it with the `powershell.exe` line from
   Monitoring, with `RUN_NAME` set. Stopping the background task alone can leave the PowerShell
   process running.
1. The page is in the project root from stage 3, uncommitted. Confirm it exists and that
   `git -C <project> status --short` lists only it.
2. Remove the worktrees. For each worktree in `<run>/news-run.json`, run
   `orca worktree rm --worktree id:<id> --force --json`. Orca removes the worktree and its local
   branch when it can prove the branch merged. `--force` is needed because the run leaves untracked
   files behind.
3. Branches that Orca keeps are unmerged. Do not delete them with `git branch -D` from this skill.
   List the manifest branches that still exist
   (`git -C <project> rev-parse --verify --quiet refs/heads/<branch>`), and ask the user before
   removing any.
4. Verify. `git -C <project> worktree list` and `git -C <project> branch --list` must show no
   manifest entry. Report the output.

The run folder under `.orca/team/` stays. It holds the candidate lists, the selection, and the
screenshots, which are the record of how the page was built.

## Final report

Give the user:

- the path to the HTML file in the project root
- what cleanup removed, and the branches still present
- the count per track: candidates, dropped in the crawl (link, text), selected, and merged duplicates
- any track that came up short, and by how much
- any feed that failed, and what replaced it
- the design calls, which the template fixes (see Stage 3)

Stop there. Committing or publishing the page is outward-facing, so it waits for the user's go-ahead.
