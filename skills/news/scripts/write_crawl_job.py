#!/usr/bin/env python3
"""Write REQUEST.md and PLAN.md for a crawl job, so the planner does not hand-write them.

Usage: python write_crawl_job.py --track international|tech --handover DIR

The job slug is the handover folder's name. Source names come from crawl_track.SOURCES. The
interpreter and script paths are this run's, so the plan can be run as written.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from crawl_track import SOURCES, TRACK_LABEL  # noqa: E402

REQUEST = """# Request: {slug}

Produce the {label} candidate list for the news digest.

Sources: {names}. Blocked by default: {blocked}.

Output: CANDIDATES.md in the handover folder.
"""

PLAN = """Read and follow the "team" skill before touching any file.

This is a crawl job for the news digest. The scripts fetch, filter, and build. You only write
summaries. Do not write fetching or parsing code, and do not fetch any URL yourself. crawl_track.py
already checks each Link and drops dead or textless items. If a source failed, do not investigate it.
Your deliverables are CANDIDATES.md and a one-line IMPLEMENTATION.md. Nobody reviews this job. The
watcher reads a turn with no IMPLEMENTATION.md as a stalled round and sends this plan again, so the
one line is required, not optional.

## Scope

- Job: {slug}. Track: {label}. Output only in {handover}. No change and no commit in this worktree.
- Interpreter for every script: {python}

## Steps

1. "{python}" "{crawl}" --track {track} --handover "{handover}"
   Expect a line "{label}: N items". Exit 1 means fewer than 25 usable items remain. Continue
   anyway: every usable item is already kept, and the count is in items.json.
2. Read items.json (its items array). Write one summary for each item, from its text field only:
   1 to 3 sentences, 60 words at most. State only facts the text gives, keep its figures and
   attribution, add nothing from memory, and use no adjectives such as "groundbreaking". Save
   {{"<id>": "<summary>"}} as summaries.json in the handover folder, UTF-8 without BOM, with the
   Write tool. Keep at least 25 summaries.
3. "{python}" "{build}" "{handover}"
4. "{python}" "{check}" "{handover}/CANDIDATES.md". Below 25 blocks it prints FAIL, which is the
   expected result of a short crawl: leave the file as it is.
5. Write IMPLEMENTATION.md in the handover folder with one line: the item count from step 1, and
   OK or FAIL from step 4. Write nothing else in it.

## Forbidden

- Editing anything in {scripts}.
- Passing --include-blocked.
- Touching the main repo or another job's worktree.
- Committing, pushing, or opening a pull request.

## Acceptance

- items.json, summaries.json, CANDIDATES.md, and IMPLEMENTATION.md are in the handover folder, and no other file is written.
- Every block's Track is {label}. check_candidates ran: OK, or FAIL for a short crawl.
- git status --short in this worktree prints nothing.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--track", required=True, choices=sorted(SOURCES))
    ap.add_argument("--handover", required=True)
    args = ap.parse_args()

    handover = os.path.abspath(args.handover)
    os.makedirs(handover, exist_ok=True)
    listed = SOURCES[args.track]
    fields = {
        "slug": os.path.basename(handover),
        "label": TRACK_LABEL[args.track],
        "track": args.track,
        "handover": handover,
        "names": ", ".join(name for name, *_ in listed),
        "blocked": ", ".join(name for name, *_, blocked in listed if blocked) or "none",
        "python": sys.executable,
        "scripts": HERE,
        "crawl": os.path.join(HERE, "crawl_track.py"),
        "build": os.path.join(HERE, "build_candidates.py"),
        "check": os.path.join(HERE, "check_candidates.py"),
    }
    for name, text in (("REQUEST.md", REQUEST), ("PLAN.md", PLAN)):
        path = os.path.join(handover, name)
        with open(path, "w", encoding="ascii", newline="\n") as f:
            f.write(text.format(**fields))
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
