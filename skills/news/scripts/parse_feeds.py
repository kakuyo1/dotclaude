#!/usr/bin/env python3
"""Parse one RSS or Atom file into candidate items for one source.

Usage: python parse_feeds.py FEED.xml --source "BBC News" --since 2026-10-11T00:00:00Z
           [--cap 8] [--out items.json]

Items keep feed order: rank 1 is the first item in the feed. Items published before --since
are dropped. Items with no parsable date are kept and marked undated. The first --cap items
that survive the filter are kept. Image is taken from the feed only (media:thumbnail,
media:content, enclosure); it is never constructed. needs_article is true when the feed
description is too short to summarise from (under 35 words), so fetch_articles.py should
fetch the page for that item.

Prints a summary line per source. The JSON goes to --out, or stdout when --out is omitted.
"""
import argparse
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

MEDIA = "{http://search.yahoo.com/mrss/}"
DC = "{http://purl.org/dc/elements/1.1/}"
ATOM = "{http://www.w3.org/2005/Atom}"


def parse_date(text):
    if not text:
        return None
    text = text.strip()
    try:
        d = parsedate_to_datetime(text)
    except (TypeError, ValueError):
        try:
            d = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.astimezone(timezone.utc)


def clean(text):
    text = re.sub(r"<[^>]+>", " ", text or "")
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def feed_image(node):
    for el in node.iter():
        tag = el.tag
        if tag in (MEDIA + "thumbnail", MEDIA + "content", "enclosure") and el.get("url"):
            return el.get("url")
    return ""


def rss_items(root):
    for it in root.iter("item"):
        yield {
            "title": (it.findtext("title") or "").strip(),
            "link": (it.findtext("link") or "").strip(),
            "published": (it.findtext("pubDate") or it.findtext(DC + "date") or "").strip(),
            "description": clean(it.findtext("description")),
            "discussion": (it.findtext("comments") or "").strip(),
            "image": feed_image(it),
        }


def atom_items(root):
    for it in root.findall(ATOM + "entry"):
        link = ""
        for el in it.findall(ATOM + "link"):
            if el.get("rel", "alternate") == "alternate":
                link = el.get("href", "")
                break
        yield {
            "title": clean(it.findtext(ATOM + "title")),
            "link": link,
            "published": (it.findtext(ATOM + "published") or it.findtext(ATOM + "updated") or "").strip(),
            "description": clean(it.findtext(ATOM + "summary") or it.findtext(ATOM + "content")),
            "discussion": "",
            "image": feed_image(it),
        }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("feed")
    ap.add_argument("--source", required=True)
    ap.add_argument("--since", help="ISO 8601 UTC cut-off, e.g. 2026-10-11T00:00:00Z")
    ap.add_argument("--cap", type=int, default=8)
    ap.add_argument("--out")
    args = ap.parse_args()

    root = ET.parse(args.feed).getroot()
    raw = list(atom_items(root) if root.tag == ATOM + "feed" else rss_items(root))
    since = parse_date(args.since) if args.since else None

    kept = []
    for rank, item in enumerate(raw, start=1):
        d = parse_date(item["published"])
        if since and d and d < since:
            continue
        if d is None and since:
            item["undated"] = True
        item["rank"] = rank
        item["published_utc"] = d.strftime("%Y-%m-%dT%H:%M:%SZ") if d else None
        item["source"] = args.source
        item["needs_article"] = len(item["description"].split()) < 35
        kept.append(item)
    kept = kept[: args.cap]

    result = {"source": args.source, "feed_items": len(raw), "items": kept}
    text = json.dumps(result, ensure_ascii=False, indent=1)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text + "\n")
    print(
        f"{args.source}: feed_items={len(raw)} kept={len(kept)} "
        f"needs_article={sum(i['needs_article'] for i in kept)}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
