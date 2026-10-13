#!/usr/bin/env python3
"""Crawl one news track and write items.json for the implementer to summarise.

Usage: python crawl_track.py --track international|tech --handover DIR [--since ISO]
           [--work DIR] [--include-blocked]

Fetches the track's feeds in parallel and keeps items published on or after --since (default:
48 hours ago). Takes up to 8 items per source, in feed order. Sources are interleaved round-robin
(rank 1 of each source, then rank 2, and so on), so no source fills the list, and the list stops
at 30. If fewer than 25 items remain, it widens to every in-window item of each feed and records
that. The article page is fetched for each item whose feed description is too short to summarise
from. Writes HANDOVER/items.json.

Sources marked blocked in SOURCES are skipped unless --include-blocked is given. They fail through
the proxy on this machine (see references/pitfalls.md).

Exit 1 when fewer than 25 items remain after widening.
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
from parse_feeds import ATOM, atom_items, parse_date, rss_items  # noqa: E402

TRACK_LABEL = {"international": "International", "tech": "Tech"}
MIN_ITEMS, MAX_ITEMS, PER_SOURCE = 25, 30, 8
SHORT_WORDS = 35
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


def interleave(per_source, depth):
    """Round-robin across sources, rank by rank, up to depth items per source, at most MAX_ITEMS."""
    picked = []
    for rank in range(depth):
        for source, items in per_source:
            if rank < len(items):
                picked.append((source, items[rank]))
    return picked[:MAX_ITEMS]


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

    per_source = []
    for (name, key, _url, _blocked), (_k, code, _size, _xml, ok, note) in zip(sources, fetched):
        if not ok:
            report.append({"source": name, "status": f"failed: http={code} {note}".strip()})
            continue
        raw = load_feed(os.path.join(feeds_dir, key + ".xml"))
        win = in_window(raw, since)
        per_source.append((name, win))
        report.append({"source": name, "status": "ok", "feed_items": len(raw), "in_window": len(win)})

    picked = interleave(per_source, PER_SOURCE)
    widened = False
    if len(picked) < MIN_ITEMS:
        picked = interleave(per_source, max((len(w) for _, w in per_source), default=0))
        widened = True

    rows = [dict(item, source=name, id=i) for i, (name, item) in enumerate(picked, start=1)]
    need = [r for r in rows if len(r["description"].split()) < SHORT_WORDS]
    with ThreadPoolExecutor(max_workers=8) as pool:
        pages = list(pool.map(lambda r: fetch_articles.work(r["id"], r, articles_dir), need))
    by_id = {p["index"]: p for p in pages}

    items = []
    for r in rows:
        page = by_id.get(r["id"])
        text = page["text"] if page and page["text"] else r["description"]
        items.append({
            "id": r["id"],
            "track": TRACK_LABEL[args.track],
            "source": r["source"],
            "title": r["title"],
            "published": r["published"],
            "published_utc": r["published_utc"],
            "link": r["link"],
            "discussion": r["discussion"],
            "feed_image": r["image"],
            "og_image": page["og_image"] if page else "",
            "text": text,
            "article_http": page["http"] if page else None,
        })

    out = {"track": TRACK_LABEL[args.track], "since": since.strftime("%Y-%m-%dT%H:%M:%SZ"),
           "widened": widened, "sources": report, "items": items}
    with open(os.path.join(args.handover, "items.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)

    for row in report:
        print(f"  {row['source']:<20} {row['status']}"
              + (f"  feed_items={row['feed_items']} in_window={row['in_window']}" if "feed_items" in row else ""))
    print(f"{TRACK_LABEL[args.track]}: {len(items)} items, widened={widened}, "
          f"article pages fetched={len(need)} -> {os.path.join(args.handover, 'items.json')}")
    sys.exit(0 if len(items) >= MIN_ITEMS else 1)


if __name__ == "__main__":
    main()
