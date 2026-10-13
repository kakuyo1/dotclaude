#!/usr/bin/env python3
"""Mechanical check of a CANDIDATES.md file from a crawl job.

Usage: python check_candidates.py FILE.md [--min 25] [--max 30]

Checks: block count within --min..--max, numbering 1..N with no gaps, every block has
Track, Source, Title, Published, Link, Image and Summary, Track is International or Tech,
summaries are at most 60 words, the file is ASCII, and there are no em or en dashes.
Prints one line per failed check. Exit 1 if any check fails.
"""
import argparse
import re
import sys

REQUIRED = ("Track", "Source", "Title", "Published", "Link", "Image", "Summary")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--min", type=int, default=25)
    ap.add_argument("--max", type=int, default=30)
    args = ap.parse_args()

    with open(args.file, "rb") as f:
        raw = f.read()
    problems = []
    if any(b > 127 for b in raw):
        problems.append("file is not ASCII")
    text = raw.decode("utf-8", "replace").replace("\r\n", "\n")
    if "—" in text or "–" in text:
        problems.append("contains an em or en dash")

    parts = re.split(r"(?m)^## (\d+)\s*$", text)[1:]
    numbers = [int(n) for n in parts[0::2]]
    blocks = [body for body in parts[1::2]]
    count = len(blocks)
    if not args.min <= count <= args.max:
        problems.append(f"block count {count} outside {args.min}..{args.max}")
    if numbers != list(range(1, count + 1)):
        problems.append(f"numbering is not 1..{count}: {numbers[:5]}...")

    for n, body in zip(numbers, blocks):
        fields = dict(re.findall(r"(?m)^([A-Za-z]+): (.*)$", body))
        missing = [f for f in REQUIRED if f not in fields]
        if missing:
            problems.append(f"block {n} missing {', '.join(missing)}")
        if fields.get("Track") not in ("International", "Tech"):
            problems.append(f"block {n} Track is {fields.get('Track')!r}")
        words = len(fields.get("Summary", "").split())
        if words > 60:
            problems.append(f"block {n} summary is {words} words")

    print(f"blocks: {count}")
    for p in problems:
        print(f"FAIL {p}")
    if not problems:
        print("OK all checks passed")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
