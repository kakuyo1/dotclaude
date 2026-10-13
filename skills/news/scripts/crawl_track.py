#!/usr/bin/env python3
"""Crawl one news track and write items.json for the implementer to summarise.

Usage: python crawl_track.py --track international|tech --handover DIR [--since ISO]
           [--work DIR] [--include-blocked]

Fetches the track's feeds in parallel and keeps items published on or after --since (default:
48 hours ago). Candidates are taken round-robin across sources (rank 1 of each source, then rank 2,
and so on), at most 8 per source in the first pass. Each candidate's article page is fetched, and it
is kept only when its Link answers 200 and its text has at least MIN_WORDS words. The list stops at
30 kept items. If the first pass keeps fewer than 25, the rest of the in-window items are tried and
the run is marked widened. Only kept items reach items.json, so the implementer never summarises a
dead link or an empty page. Writes HANDOVER/items.json.

Sources marked blocked in SOURCES are skipped unless --include-blocked is given.

Exit 1 when fewer than 25 items are kept after widening.
"""
import argparse
import json
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fetch_articles  # noqa: E402
import fetch_feeds  # noqa: E402
from fetch_articles import MIN_WORDS  # noqa: E402
from parse_feeds import ATOM, atom_items, parse_date, rss_items  # noqa: E402

TRACK_LABEL = {"international": "International", "tech": "Tech"}
MIN_ITEMS, MAX_ITEMS, PER_SOURCE = 25, 30, 8
REUTERS = "https://news.google.com/rss/search?q=when:24h+site:reuters.com&hl=en-US&gl=US&ceid=US:en"

# (source name, file key, feed URL, blocked on this machine)
SOURCES = {
    "international": [
        ("BBC News", "bbc", "https://feeds.bbci.co.uk/news/world/rss.xml", False),
        ("The Guardian", "guardian", "https://www.theguardian.com/world/rss", False),
        ("Al Jazeera English", "aljazeera", "https://www.aljazeera.com/xml/rss/all.xml", False),
        ("NPR", "npr", "https://feeds.npr.org/1001/rss.xml", False),
        ("Reuters", "reuters", REUTERS, True),
    ],
    "tech": [
        ("Hacker News", "hn", "https://news.ycombinator.com/rss", False),
        ("arXiv cs.AI", "arxiv_ai", "https://rss.arxiv.org/rss/cs.AI", False),
        ("arXiv cs.LG", "arxiv_lg", "https://rss.arxiv.org/rss/cs.LG", False),
        ("arXiv cs.CL", "arxiv_cl", "https://rss.arxiv.org/rss/cs.CL", False),
        ("Techmeme", "techmeme", "https://www.techmeme.com/feed.xml", False),
        ("Ars Technica", "ars", "https://feeds.arstechnica.com/arstechnica/index", True),
        ("Simon Willison", "willison", "https://simonwillison.net/atom/everything/", False),
    ],
}


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


def interleave(per_source):
    """Rank-major order across sources as (depth, source, item). A prefix of it is the capped first pass."""
    depth = max((len(items) for _, items in per_source), default=0)
    return [(rank, name, items[rank]) for rank in range(depth) for name, items in per_source if rank < len(items)]


def fetch_checked(row, articles_dir):
    page = fetch_articles.work(row["cand"], row, articles_dir)
    if page["http"] != "200":
        page = fetch_articles.work(row["cand"], row, articles_dir)
    return page, page["text"] or row["description"]


def evaluate(rows, kept, stats, articles_dir):
    """Fetch rows in batches until MAX_ITEMS are kept, and append the usable ones to kept."""
    pos = 0
    while pos < len(rows) and len(kept) < MAX_ITEMS:
        batch = rows[pos:pos + max(8, 2 * (MAX_ITEMS - len(kept)))]
        pos += len(batch)
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
    ap.add_argument("--track", required=True, choices=sorted(SOURCES))
    ap.add_argument("--handover", required=True)
    ap.add_argument("--since", help="ISO 8601 UTC, e.g. 2026-10-11T06:30:00Z (default: 48 hours ago)")
    ap.add_argument("--work", help="scratch folder (default: $TEMP/news-crawl-<track>)")
    ap.add_argument("--include-blocked", action="store_true")
    args = ap.parse_args()

    since = parse_date(args.since) if args.since else datetime.now(timezone.utc) - timedelta(hours=48)
    work = args.work or os.path.join(os.environ.get("TEMP") or tempfile.gettempdir(), f"news-crawl-{args.track}")
    feeds_dir = os.path.join(work, "feeds")
    articles_dir = os.path.join(work, "articles")
    for folder in (args.handover, feeds_dir, articles_dir):
        os.makedirs(folder, exist_ok=True)

    listed = SOURCES[args.track]
    sources = [s for s in listed if args.include_blocked or not s[3]]
    report = [{"source": s[0], "status": "skipped: blocked on this machine"}
              for s in listed if s not in sources]

    with ThreadPoolExecutor(max_workers=len(sources)) as pool:
        fetched = list(pool.map(lambda s: fetch_feeds.fetch(s[1], s[2], feeds_dir), sources))

    per_source, stats = [], {}
    for (name, key, _url, _blocked), (_k, code, _size, _xml, ok, note) in zip(sources, fetched):
        if not ok:
            report.append({"source": name, "status": f"failed: http={code} {note}".strip()})
            continue
        raw = load_feed(os.path.join(feeds_dir, key + ".xml"))
        win = in_window(raw, since)
        per_source.append((name, win))
        stats[name] = {"kept": 0, "link_failed": 0, "no_text": 0}
        report.append({"source": name, "status": "ok", "feed_items": len(raw), "in_window": len(win)})

    ordered = [dict(item, source=name, depth=depth, cand=i)
               for i, (depth, name, item) in enumerate(interleave(per_source), start=1)]
    first = [r for r in ordered if r["depth"] < PER_SOURCE]
    rest = ordered[len(first):]

    kept = []
    evaluate(first, kept, stats, articles_dir)
    widened = len(kept) < MIN_ITEMS and bool(rest)
    if widened:
        evaluate(rest, kept, stats, articles_dir)

    items = [{
        "id": n,
        "track": TRACK_LABEL[args.track],
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
    out = {"track": TRACK_LABEL[args.track], "since": since.strftime("%Y-%m-%dT%H:%M:%SZ"),
           "widened": widened, "sources": report, "items": items}
    path = os.path.join(args.handover, "items.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    for row in report:
        line = f"  {row['source']:<20} {row['status']}"
        if "feed_items" in row:
            line += (f"  feed_items={row['feed_items']} in_window={row['in_window']} kept={row['kept']}"
                     f" link_failed={row['link_failed']} no_text={row['no_text']}")
        print(line)
    fetched_pages = sum(s["kept"] + s["link_failed"] + s["no_text"] for s in stats.values())
    print(f"{TRACK_LABEL[args.track]}: {len(items)} items, widened={widened}, "
          f"article pages fetched={fetched_pages} -> {path}")
    sys.exit(0 if len(items) >= MIN_ITEMS else 1)


if __name__ == "__main__":
    main()
