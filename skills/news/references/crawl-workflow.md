# Crawl workflow: from feeds to CANDIDATES.md

The implementer runs three commands and writes one JSON file. Everything else is inside the
scripts. Run them from the skill's `scripts/` folder. The handover folder is passed as the
argument, so no path is typed by hand.

## Setup, once

```bash
cd ~/.claude/skills/news/scripts && npm install
```

`npm install` is only needed for the screenshot script. The crawl needs Python alone.

## Steps

1. **Crawl the track.** This fetches the feeds in parallel, applies the window and caps, and
   fetches the article pages it needs. It writes `items.json` into the handover folder.

   ```bash
   python scripts/crawl_track.py --track international --handover "$HANDOVER"
   python scripts/crawl_track.py --track tech --handover "$HANDOVER"
   ```

   The 48-hour window ends at the run's start, computed in UTC. Use `--since` to set it
   explicitly. Use `--include-blocked` only when the user asks for Reuters or Ars Technica.

   The output lists each source's status: `ok`, `failed`, or `skipped`. Exit 1 means fewer than
   25 items remain after widening. Report that; do not curate a thin list.

2. **Write the summaries.** Read `items.json`. For each item, write 1 to 3 sentences, at most 60
   words, from its `text` field. If `text` is empty, use `description`. Save the result as
   `summaries.json` in the same folder, keyed by item id:

   ```json
   {"1": "Summary for item 1.", "2": "Summary for item 2."}
   ```

   Leave an item out when it has no usable text. Keep at least 25 summaries.

3. **Build the candidate list.** This checks each Link and Image through the proxy, retries once,
   and writes `CANDIDATES.md`:

   ```bash
   python scripts/build_candidates.py "$HANDOVER"
   ```

   It prints any dropped items (a Link that still fails) and any `unverified` images. Those
   counts go into the job's IMPLEMENTATION.md.

## What the orchestrator checks

The orchestrator does not read the implementer's report. It runs the two checks:

```bash
python scripts/check_candidates.py "$HANDOVER/CANDIDATES.md"
python scripts/check_urls.py "$HANDOVER/CANDIDATES.md"
```

Both must exit 0. A failure is a finding in REVIEW.md.

## Measured timings

Measured on the 2026-10-13 run, through the proxy:

| Step | Time |
| --- | --- |
| 12 feeds, parallel | a few seconds |
| 16 article pages, parallel (8 workers) | 10 s |
| 30 links and 24 images, parallel | 17 s |
| Full crawl_track.py, international | 10 s |
| Full crawl_track.py, tech | 8 s |
| build_candidates.py, 30 items | 7 to 11 s |
| Screenshot run, two widths | 45 s |

The first run's two crawl jobs ran from about 15:10 to 15:37 by the watcher log. Their per-step
times were not recorded, so no before/after figure is claimed. The slow part was the agents
restarting after failed commands and waiting on their own serial loops, not the network.

## What the scripts do not do

- Pick the 25 to 30 items beyond the round-robin order. The order is the stated rule, and it
  favours feed rank over editorial weight. Stage 2 is where editorial choices are made.
- Write summaries. The 60-word limit is checked by `build_candidates.py`, but the content is not.
- Resolve Google News links. The Reuters track is off by default (see pitfalls.md), so no resolver
  is kept.
