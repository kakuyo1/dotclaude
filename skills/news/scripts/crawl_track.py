#!/usr/bin/env python3
"""Crawl one news track and write items.json for the implementer to summarise.

Usage: python crawl_track.py --track KEY --handover DIR --project DIR [--since ISO]
           [--work DIR] [--include-blocked]

KEY is a track in tracks.TRACKS. Fetches the track's feeds in parallel and keeps items published on
or after --since (default: the track's window_hours ago). Candidates are taken round-robin across
sources (rank 1 of each source, then rank 2, and so on), at most 8 per source in the first pass. Each
candidate's article
page is fetched, and it is kept only when its Link answers 200 and its text has at least MIN_WORDS
words. The list stops at 30 kept items, and a track's max_per_source (when set) caps what one source keeps.
If the first pass keeps fewer than 25, the rest of the
in-window items are tried and the run is marked widened. Only kept items reach items.json, so the
implementer never summarises a dead link or an empty page. Writes HANDOVER/items.json.

Sources marked blocked in tracks.py are skipped unless --include-blocked is given.

Items that an earlier news-*.html digest in --project already carries are dropped before the first
pass (see reported.py). They are listed under "reported" in items.json.

Exit 1 when fewer than 25 items are kept after widening.
"""
import argparse
import json
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fetch_articles  # noqa: E402
import fetch_feeds  # noqa: E402
import reported  # noqa: E402
from fetch_articles import MIN_WORDS  # noqa: E402
from parse_feeds import ATOM, atom_items, parse_date, rss_items  # noqa: E402
from tracks import TRACKS  # noqa: E402

MIN_ITEMS, MAX_ITEMS, PER_SOURCE = 25, 30, 8


def load_feed(path):
    root = ET.parse(path).getroot()
    return list(atom_items(root) if root.tag == ATOM + "feed" else rss_items(root))


def in_window(raw, since):
    kept = []
    for rank, item in enumerate(raw, start=1):
        d = parse_date(item["published"])
        if since and d and d < since:
            continue
        kept.append(dict(item, rank=rank, published_utc=d.strftime("%Y-%m-%dT%H:%M:%SZ") if d else None))
    return kept


def drop_reported(win, history):
    """Split win into the items no earlier digest carries, and (page, item) for each one dropped."""
    fresh, dropped = [], []
    for item in win:
        page = history.repeat(item["link"])
        if page:
            dropped.append((page, item))
        else:
            fresh.append(item)
    return fresh, dropped


def interleave(per_source):
    """Rank-major order across sources as (depth, source, item). A prefix of it is the capped first pass."""
    depth = max((len(items) for _, items in per_source), default=0)
    return [(rank, name, items[rank]) for rank in range(depth) for name, items in per_source if rank < len(items)]


def fetch_checked(row, articles_dir):
    page = fetch_articles.work(row["cand"], row, articles_dir)
    if page["http"] != "200":
        page = fetch_articles.work(row["cand"], row, articles_dir)
    return page, page["text"] or row["description"]


def evaluate(rows, kept, stats, articles_dir, cap):
    """Fetch rows in batches until MAX_ITEMS are kept, and append the usable ones to kept. A source
    keeps at most cap items. A batch asks each source only for the items it still has room for: a row
    past that waits for a later batch, and a row of a full source counts as capped and is not fetched."""
    remaining = list(rows)
    while remaining and len(kept) < MAX_ITEMS:
        size = max(8, 2 * (MAX_ITEMS - len(kept)))
        batch, planned, later = [], Counter(), []
        for row in remaining:
            s = stats[row["source"]]
            room = size if cap is None else cap - s["kept"]
            if room <= 0:
                s["capped"] += 1
            elif len(batch) < size and planned[row["source"]] < room:
                batch.append(row)
                planned[row["source"]] += 1
            else:
                later.append(row)
        remaining = later
        with ThreadPoolExecutor(max_workers=8) as pool:
            fetched = list(pool.map(lambda r: fetch_checked(r, articles_dir), batch))
        for row, (page, text) in zip(batch, fetched):
            if len(kept) >= MAX_ITEMS:
                break
            s = stats[row["source"]]
            if page["http"] != "200":
                s["link_failed"] += 1
            elif len(text.split()) < MIN_WORDS:
                s["no_text"] += 1
            else:
                s["kept"] += 1
                kept.append(dict(row, page=page, text=text))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--track", required=True, choices=sorted(TRACKS))
    ap.add_argument("--handover", required=True)
    ap.add_argument("--project", required=True, help="the project folder whose news-*.html digests are the history")
    ap.add_argument("--since", help="ISO 8601 UTC, e.g. 2026-10-11T06:30:00Z (default: the track's window_hours ago)")
    ap.add_argument("--work", help="scratch folder (default: $TEMP/news-crawl-<track>)")
    ap.add_argument("--include-blocked", action="store_true")
    args = ap.parse_args()

    label = TRACKS[args.track]["label"]
    window = timedelta(hours=TRACKS[args.track]["window_hours"])
    since = parse_date(args.since) if args.since else datetime.now(timezone.utc) - window
    work = args.work or os.path.join(os.environ.get("TEMP") or tempfile.gettempdir(), f"news-crawl-{args.track}")
    feeds_dir = os.path.join(work, "feeds")
    articles_dir = os.path.join(work, "articles")
    for folder in (args.handover, feeds_dir, articles_dir):
        os.makedirs(folder, exist_ok=True)

    history = reported.load(args.project)
    listed = TRACKS[args.track]["sources"]
    sources = [s for s in listed if args.include_blocked or not s[3]]
    report = [{"source": s[0], "status": "skipped: blocked on this machine"}
              for s in listed if s not in sources]

    with ThreadPoolExecutor(max_workers=len(sources)) as pool:
        fetched = list(pool.map(lambda s: fetch_feeds.fetch(s[1], s[2], feeds_dir), sources))

    per_source, stats, reported_items = [], {}, []
    for (name, key, _url, _blocked), (_k, code, _size, _xml, ok, note) in zip(sources, fetched):
        if not ok:
            report.append({"source": name, "status": f"failed: http={code} {note}".strip()})
            continue
        raw = load_feed(os.path.join(feeds_dir, key + ".xml"))
        win = in_window(raw, since)
        fresh, dropped = drop_reported(win, history)
        per_source.append((name, fresh))
        stats[name] = {"kept": 0, "link_failed": 0, "no_text": 0, "capped": 0, "reported": len(dropped)}
        reported_items += [{"source": name, "title": item["title"], "link": item["link"], "page": page}
                           for page, item in dropped]
        report.append({"source": name, "status": "ok", "feed_items": len(raw), "in_window": len(win)})

    ordered = [dict(item, source=name, depth=depth, cand=i)
               for i, (depth, name, item) in enumerate(interleave(per_source), start=1)]
    first = [r for r in ordered if r["depth"] < PER_SOURCE]
    rest = ordered[len(first):]

    cap = TRACKS[args.track].get("max_per_source")
    kept = []
    evaluate(first, kept, stats, articles_dir, cap)
    widened = len(kept) < MIN_ITEMS and bool(rest)
    if widened:
        evaluate(rest, kept, stats, articles_dir, cap)

    items = [{
        "id": n,
        "track": label,
        "source": row["source"],
        "title": row["title"],
        "published": row["published"],
        "published_utc": row["published_utc"],
        "link": row["link"],
        "discussion": row["discussion"],
        "feed_image": row["image"],
        "og_image": row["page"]["og_image"],
        "text": row["text"],
        "article_http": row["page"]["http"],
    } for n, row in enumerate(kept, start=1)]

    for entry in report:
        entry.update(stats.get(entry["source"], {}))
    out = {"track": label, "since": since.strftime("%Y-%m-%dT%H:%M:%SZ"),
           "widened": widened, "sources": report, "items": items, "reported": reported_items}
    path = os.path.join(args.handover, "items.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    for row in report:
        line = f"  {row['source']:<20} {row['status']}"
        if "feed_items" in row:
            line += (f"  feed_items={row['feed_items']} in_window={row['in_window']} kept={row['kept']}"
                     f" link_failed={row['link_failed']} no_text={row['no_text']} capped={row['capped']}"
                     f" reported={row['reported']}")
        print(line)
    fetched_pages = sum(s["kept"] + s["link_failed"] + s["no_text"] for s in stats.values())
    print(f"{label}: {len(items)} items, widened={widened}, "
          f"article pages fetched={fetched_pages} -> {path}")
    sys.exit(0 if len(items) >= MIN_ITEMS else 1)


if __name__ == "__main__":
    main()
