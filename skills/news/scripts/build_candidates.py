#!/usr/bin/env python3
"""Build CANDIDATES.md from items.json (crawl_track.py) and summaries.json (the implementer).

Usage: python build_candidates.py HANDOVER

summaries.json maps each item id (a string) to its summary: 1 to 3 sentences, at most 60 words.
An item without a summary is left out. Blocks follow items.json order and are numbered 1..N.

Link: must answer 200 through the proxy (one retry). An item whose Link still fails is dropped and
listed. Image: the feed image if it answers 200, else the og:image if that does, else "none" when
no image URL exists, or "unverified" when URLs exist but none answer. Titles and summaries are
ASCII: dashes become hyphens, other non-ASCII characters become numeric entities.
"""
import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from check_urls import check  # noqa: E402

MAX_WORDS = 60


def ascii_text(s):
    s = " ".join(s.split()).replace("—", "-").replace("–", "-")
    return "".join(ch if ord(ch) < 128 else f"&#{ord(ch)};" for ch in s)


def check_item(item):
    if check(item["link"]) != "200":
        return {"link_ok": False, "image": None}
    urls = [u for u in (item.get("feed_image"), item.get("og_image")) if u]
    image = "none"
    if urls:
        image = "unverified"
        for url in urls:
            if check(url) == "200":
                image = url
                break
    return {"link_ok": True, "image": image}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("handover")
    args = ap.parse_args()
    with open(os.path.join(args.handover, "items.json"), encoding="utf-8") as f:
        items = json.load(f)["items"]
    with open(os.path.join(args.handover, "summaries.json"), encoding="utf-8") as f:
        summaries = json.load(f)

    problems = []
    for item in items:
        s = summaries.get(str(item["id"]))
        if s is not None and len(s.split()) > MAX_WORDS:
            problems.append(f"id {item['id']}: summary is {len(s.split())} words")
    if problems:
        print("\n".join(f"FAIL {p}" for p in problems))
        sys.exit(1)

    chosen = [it for it in items if summaries.get(str(it["id"]), "").strip()]
    no_summary = [it["id"] for it in items if not summaries.get(str(it["id"]), "").strip()]

    with ThreadPoolExecutor(max_workers=10) as pool:
        checked = list(pool.map(check_item, chosen))

    blocks, dropped, unverified = [], [], []
    for item, c in zip(chosen, checked):
        if not c["link_ok"]:
            dropped.append(item)
            continue
        if c["image"] == "unverified":
            unverified.append(item)
        n = len(blocks) + 1
        lines = [
            f"## {n}",
            f"Track: {item['track']}",
            f"Source: {item['source']}",
            f"Title: {ascii_text(item['title'])}",
            f"Published: {ascii_text(item['published'])}",
            f"Link: {item['link']}",
            f"Image: {c['image']}",
            f"Summary: {ascii_text(summaries[str(item['id'])])}",
        ]
        if item.get("discussion"):
            lines.append(f"Discussion: {item['discussion']}")
        blocks.append("\n".join(lines))

    out = os.path.join(args.handover, "CANDIDATES.md")
    # newline="\n": on Windows, text mode would write CRLF, and the checks then read a stray \r.
    with open(out, "w", encoding="ascii", newline="\n") as f:
        f.write("\n\n".join(blocks) + "\n")

    print(f"wrote {out}: {len(blocks)} blocks")
    if no_summary:
        print(f"left out, no summary: ids {no_summary}")
    for item in dropped:
        print(f"DROPPED, Link failed: id {item['id']} {item['source']} {item['link']}")
    for item in unverified:
        print(f"unverified image: id {item['id']} {item['source']}")


if __name__ == "__main__":
    main()
