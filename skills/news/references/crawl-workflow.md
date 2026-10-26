# Crawl workflow

What `crawl_track.py` guarantees, what the implementer does, and what the scripts measured.

## What the crawl does

1. Fetches the track's feeds in parallel through the proxy. Blocked sources are skipped unless
   `--include-blocked` is given.
2. Keeps items published within the track's `window_hours` (UTC): 48 hours for International and Tech,
   7 days for China. `--since` sets the window explicitly.
3. Drops items that an earlier digest in `--project` already carries, by their feed Link, their article link, or an "Also covered by"
   link, after normalising the URL (`reported.py`). Dropped items are listed under `reported` in `items.json`
   and never reach the first pass.
4. Orders candidates round-robin across sources: rank 1 of each source, then rank 2, up to 8 per
   source in the first pass. A track's `max_per_source`, when set, is the most items one source keeps;
   its other rows count as `capped` and are not fetched.
5. Fetches each candidate's article page (for a Techmeme item, the publisher page its description links to), retrying once on a non-200 answer. An item is kept only
   when its page answers 200 and its text has at least 25 words. Text comes from the page's
   `<article>` body, else its description, else every paragraph on the page. A body over 1400
   characters keeps its opening, middle, and closing, in that order. The list stops at 30.
6. If the first pass keeps fewer than 25 items, it tries the rest of the in-window items and sets
   `widened`.
7. Writes `items.json` with the kept items only, and the dropped items under `reported`. Each item has `article_http` and `text`.

It prints one line per source: `kept`, `link_failed`, `no_text`, `capped`, and `reported`. Exit 1 means fewer than 25 items
were kept after widening.

## Steps for the implementer

The plan from `write_crawl_job.py` gives these steps in order:

1. `crawl_track.py --track <track> --handover <folder>`
2. Write `summaries.json`, one entry per item, from its `text` field: `{"<id>": "<summary>"}`.
   Save it as UTF-8 without a BOM. Summaries follow the rules in SKILL.md.
3. `build_candidates.py <folder>`. It reuses the Link result from step 1 and checks each image through
   the proxy. It writes `CANDIDATES.md`.
4. `check_candidates.py <folder>/CANDIDATES.md`. Below 25 blocks it prints FAIL, which is the expected
   result of a short crawl.
5. Write `IMPLEMENTATION.md`: one line with the item count and the step 4 result. The watcher needs
   this file to see the turn as finished. Without it, the watcher re-sends the plan.

With `--sub`, the plan is the same without step 5: the subagent has no watcher, so its one-line
report is its final reply instead of a file.

The report says nothing else. The per-source counts come from the `sources` list in `items.json`.

## Checks

- `check_candidates.py CANDIDATES.md`: the implementer's last check, not an orchestrator review. Block
  count 25 to 30, fields, ASCII, no dashes, summaries at most 60 words.
- `test_extract.py [items.json]`: offline check of the text extraction. With an `items.json`, it also
  asserts that every kept item has `article_http` 200 and at least 25 words of text.
- `test_crawl.py`: offline check of the per-source cap and of the earlier-digest drop. A source is never fetched past its room.
- `test_reported.py`: offline check of the digest parsing, the link matching, and the title flag.

## Measured timings

Measured through the proxy on 2026-10-13, with the crawl alone:

| Track | Crawl time | Items kept |
| --- | --- | --- |
| International | 2 to 4 s | 30 |
| Tech | 6 to 9 s | 24 (Techmeme 15 of 15 dropped, Hacker News 21 of 28 kept) |
| China, 2026-10-14, 7-day window, cap 15 | not timed | 20 (SCMP 15, The Diplomat 5; FT blocked; China Digital Times 0 in window); exit 1 |

Tech stayed at 24 because the 48-hour window has no more usable items. The run before this change
finished its Tech job about four minutes after the International job: the implementer summarised items
whose Links were dead, then stopped to ask for help about the short list.

## What the scripts do not do

- Widen a track's window beyond its `window_hours`. Ask the user first. China's 7 days was approved on
  2026-10-14.
- Judge the content of a summary. Summaries are the implementer's, and `check_candidates.py` checks their shape.
- Resolve Google News links. Reuters stays off by default (see `pitfalls.md`).
