---
name: news
disable-model-invocation: true
description: >-
  Two-track news digest built on the team workflow. Two jobs crawl international news (BBC, The Guardian, Al Jazeera, NPR, Reuters via Google News) and tech frontier sources (Hacker News, arXiv cs.AI/cs.LG/cs.CL, Techmeme, Ars Technica, Simon Willison's Weblog), each keeping 25-30 English items. The orchestrator removes duplicates and selects 20 stories, then a third team job builds one HTML page to DESIGN.md. The page is copied into the project the skill was triggered from, and the run's own branches and worktrees are deleted afterwards. Invoked by the user with /news.
---

# Daily news digest

Three stages, one page. Stages 1 and 3 are [team](../team/SKILL.md) runs: invoke the `team`
skill and follow its planner section and `references/run.md`. Stage 2 is the orchestrator's
own work. This skill fixes the jobs, the handover formats, and the page; the team workflow
itself is unchanged.

Everything stays in English. Titles and summaries are not translated.

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

All ten feeds answered 200 through the proxy when this skill was written. The feeds are
fetched through the proxy at `127.0.0.1:7890`; see the preflight in `run.md`.

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

Each job's `PLAN.md` carries these rules, with the job's own source list substituted:

- Fetch the feeds with `curl -sS -x http://127.0.0.1:7890`, writing each response to a file.
  Check that the body is XML before parsing it, since an error page comes back as a 200.
- Keep items published within the last 48 hours. If the track ends up under 25 items, widen to
  the feed's full list and say so.
- At most 8 items per source. Rank within each source by feed order (front page for Hacker
  News and Techmeme). Across the track, keep the 25 to 30 items with the most attention. Stop
  at 30 even if more qualify.
- Summarise from the article, not the title. When the feed's description is under two
  sentences of substance, fetch the article page once through the proxy and summarise from it.
- Each summary is 1 to 3 sentences, 60 words at most. It states only facts the source gives,
  keeps the source's own figures and attribution, and adds no context from memory and no
  adjectives such as "groundbreaking".
- Titles are verbatim. Replace an em dash or en dash with a hyphen, and write any other
  non-ASCII character as an HTML entity (for example `&eacute;`), so the file stays ASCII.
- Images come only from the feed (`media:thumbnail`, `media:content`, `enclosure`) or the
  article's `og:image` tag. Otherwise write `none`. Never construct an image URL.
- Before reporting, every Link and Image responds 200 through the proxy. A URL that fails
  once is retried once. Anything still failing is written as `unverified`, not dropped
  silently.

Each item in `CANDIDATES.md` in the handover folder uses this block, in this order:

```
## 1
Track: International
Source: BBC News
Title: <verbatim English title>
Published: <as the feed states it>
Link: <article URL>
Image: <image URL> | none
Summary: <1-3 sentences>
```

Tech items may add a `Discussion:` line with the Hacker News comments URL.

The job's `IMPLEMENTATION.md` is a short report: item count, sources used, any source that was
empty or failed and what replaced it, any Google News link left unresolved, and anything
skipped.

When the watcher shows `ACTION: Review requested` for a crawl job, the orchestrator checks
`CANDIDATES.md` itself: 25 to 30 blocks, every field present, ASCII only, and five randomly
chosen links re-fetched through the proxy. Then it writes `REVIEW.md`. Crawl reports have no
diff, so the worktree check is `git status --short` returning nothing.

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

## Stage 3: the page (team run, one job)

Start a second team run with one job, `news-html`. The job works in its own worktree and
writes a single HTML file there. The handover folder receives the design file as well:

- Copy `references/DESIGN.md` to `<handover>/news-html/DESIGN.md`. The implementer reads the
  copy from the handover folder, which the watcher always allows, so no permission prompt
  fires.
- Write `SELECTED.md` there (stage 2).

The `PLAN.md` for `news-html` states:

- **Scope.** One self-contained file, `news-<date>.html`, at the worktree root, built only from
  `SELECTED.md`. Nothing else is created, and nothing is committed.
- **Design.** DESIGN.md is the authority. Where a general taste rule and DESIGN.md differ
  (serif type, eyebrow labels, 8px radii, light-only theme), DESIGN.md wins.
- **Layout.** A 1200px maximum container. A masthead reading "Daily Digest" with the date. A
  pipe-separated nav row that links to the two sections. Two sections, International (ranks
  of the International stories, in rank order) then Technology. Within each section the first
  story is the lead, two columns wide. The rest form a grid of equal cards separated by 1px
  rules, arranged so that no cell is empty. Below 768px everything collapses to one column.
- **Type.** Plantin first, then Georgia, then `serif`, because Plantin is not installed on
  most machines. Headlines 28px for leads and 20px for cards, body 16px, eyebrows 13px uppercase
  with 0.075em tracking, negative tracking on headlines. Navigation in Helvetica Neue, Arial,
  `sans-serif`.
- **Colour.** Canvas `#fdfcf3`, text `#000000`, secondary text `#6e6e6e`, rules `#d9d9d9`, card
  surfaces `#ffffff`. Do not use `#b3b3b3` for any text that carries information: it fails
  contrast. Do not use `#ffc500`: DESIGN.md reserves it for the subscribe button, radio card,
  and illustrations, and this page has none of them.
- **Shape and depth.** 0px radius everywhere except image containers, which use 8px. No drop
  shadows. Light theme only.
- **Story content.** The eyebrow is the source name. The headline is the title, linked to the
  article. Then the summary, the published date as the feed gives it, and the `Also covered by`
  links where present. No read time: the source does not supply one, so do not invent it.
- **Images.** `<img>` with `loading="lazy"`, `referrerpolicy="no-referrer"`, the title as `alt`,
  and a fixed aspect-ratio box, so loading does not shift the layout. A story with `Image: none`
  has no image box and no placeholder graphic.
- **Copy rules.** Visible text is only the summaries, titles, and fixed labels. No em dash or
  en dash anywhere in visible text. No emoji, no scroll cues, no version or build labels, no
  decorative dots.
- **Self-contained.** No external stylesheet, script, or font file. Images are hot-linked from
  their sources.

Acceptance criteria the implementer runs and reports with real output:

1. Exactly 20 story articles: `grep -c '<article' news-<date>.html` prints `20`.
2. No em dash or en dash in the file: `grep -c $'\xe2\x80\x94' news-<date>.html` and
   `grep -c $'\xe2\x80\x93' news-<date>.html` both print `0`.
3. Two screenshots, `desktop.png` at 1280px and `mobile.png` at 390px, saved to the handover
   folder. Set the width through the DevTools protocol (`Emulation.setDeviceMetricsOverride`)
   or a Playwright viewport. Do not use `--window-size`: on Windows it clamps below about
   500px and crops the narrow capture. At 390px, `document.documentElement.scrollWidth` must
   equal `innerWidth`, so nothing overflows horizontally.
4. Each image that is not `none` either loads or sits in its fixed box with no layout shift.

The orchestrator then opens both screenshots with the Read tool, checks the layout at both
widths, spot-checks three story links, and writes `REVIEW.md`. The HTML stays in the worktree
until the delivery step copies it out.

## Monitoring

The watcher cannot wake the orchestrator. While a stage runs, read `watcher.log` at each
check, and schedule the next check with ScheduleWakeup in intervals under 270 seconds. A
stage that finishes while the user is away would otherwise wait.

## Delivery and cleanup

Run this only after stage 3 passes its checks and the orchestrator has reviewed the page. A
run that stopped before delivery keeps its worktrees and branches, and the report names the
stage that stopped. Whether to delete failed work is the user's call.

1. Copy the page. Copy the worktree's `news-<date>.html` to the project root as
   `news-<date>-<HHMM>.html` (time from `date +%H%M`). Never overwrite an existing file. Run
   `cmp` to confirm the copy matches the worktree file. Leave the copy uncommitted.
2. Remove the worktrees. For each worktree in `news-run.json`, run
   `orca worktree rm --worktree id:<id> --force --json`. Orca removes the worktree and its local
   branch. `--force` is needed because the run leaves untracked files behind. Orca keeps any
   branch it cannot prove merged, which step 3 handles.
3. Delete the branches. For each branch in the manifest that still exists
   (`git -C <project> rev-parse --verify --quiet refs/heads/<branch>`), run
   `git -C <project> branch -D <branch>`. These are the run's own unmerged branches, and only
   branches named in the manifest are deleted.
4. Verify. `git -C <project> worktree list` and `git -C <project> branch --list` must show no
   manifest entry. Report the output.

The handover folder under `.orca/team/` stays. It holds the candidate lists, the selection,
and the screenshots, which are the record of how the page was built.

## Final report

Give the user:

- the path to the HTML file in the project root
- what cleanup removed: the worktrees and branches from the manifest, and the handover folder
  that stayed
- the count per track, and the stories removed as duplicates
- any feed that was empty or failed, and what replaced it
- any Google News link left unresolved, and any image marked `unverified`
- the design calls made: Plantin falls back to Georgia on machines without it; no yellow
  accent, since the page has no subscribe button or radio card; the layout ran light-only
  because DESIGN.md is light

Stop at this point. Committing or publishing the page is outward-facing, so it waits for the
user's go-ahead.
