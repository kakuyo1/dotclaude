#!/usr/bin/env python3
"""List candidates compactly, and build SELECTED.md from a pick list.

Usage:
  python select.py list CANDIDATES.md [CANDIDATES.md ...]
  python select.py build --out SELECTED.md --pick FILE:N[,N...] [--pick ...] [--also FILE:N=Source URL]

list prints one line per candidate, its summary cut to 140 characters, and each pair of candidates
whose titles share at least 30 percent of their words. build writes SELECTED.md: the --pick entries
in rank order (the first is rank 1), each block copied from its candidate, plus Rank, Section, and
Also covered by. FILE is a CANDIDATES.md path, and N is a block number in it.
"""
import argparse
import os
import re
import sys
from collections import Counter

BLOCK = re.compile(r"(?m)^## (\d+)\s*$")
FIELD = re.compile(r"(?m)^([A-Za-z ]+): (.*)$")
FIELDS_OUT = ("Track", "Source", "Title", "Published", "Link", "Image", "Summary", "Discussion")
SECTION = {"International": "International", "Tech": "Technology"}
STOP = {"with", "from", "that", "this", "into", "over", "after", "says", "will", "their", "about",
        "have", "been", "your", "just", "what", "when", "than", "more", "show"}


def blocks(path):
    with open(path, encoding="utf-8") as f:
        text = f.read().replace("\r\n", "\n")
    parts = BLOCK.split(text)[1:]
    out = {}
    for n, body in zip(parts[0::2], parts[1::2]):
        fields = {}
        for key, value in FIELD.findall(body):
            fields.setdefault(key, value)
        out[int(n)] = fields
    return out


def words(title):
    return {w for w in re.findall(r"[a-z0-9]{4,}", title.lower()) if w not in STOP}


def cmd_list(paths):
    rows = []
    for path in paths:
        folder = os.path.basename(os.path.dirname(os.path.abspath(path)))
        for n, f in blocks(path).items():
            rows.append((f"{folder}#{n}", f))
    for ref, f in rows:
        print(f"[{ref}] {f.get('Source', '?')} | {f.get('Published', '?')} | {f.get('Title', '?')}")
        print(f"    {f.get('Summary', '')[:140]}")
    print("similar titles:")
    found = False
    for i, (ra, a) in enumerate(rows):
        for rb, b in rows[i + 1:]:
            wa, wb = words(a.get("Title", "")), words(b.get("Title", ""))
            if wa and wb and len(wa & wb) / len(wa | wb) >= 0.3:
                print(f"  {ra} <-> {rb}")
                found = True
    if not found:
        print("  none")


def cmd_build(args):
    cache = {}

    def block(path, n):
        if path not in cache:
            cache[path] = blocks(path)
        return cache[path][n]

    picks = []
    for spec in args.pick:
        path, nums = spec.rsplit(":", 1)
        picks += [(path, int(n)) for n in nums.split(",")]
    if len(set(picks)) != len(picks):
        sys.exit("a candidate is picked twice")

    also = {}
    for spec in args.also:
        key, value = spec.split("=", 1)
        path, n = key.rsplit(":", 1)
        if not re.match(r"^.+\s+https?://\S+$", value):
            sys.exit(f"--also needs 'Source URL', got {value!r}")
        also[(path, int(n))] = value

    out, sections = [], Counter()
    for rank, (path, n) in enumerate(picks, start=1):
        f = block(path, n)
        section = SECTION[f["Track"]]
        sections[section] += 1
        lines = [f"## {rank}"] + [f"{key}: {f[key]}" for key in FIELDS_OUT if key in f]
        lines += [f"Rank: {rank}", f"Section: {section}"]
        if (path, n) in also:
            lines.append(f"Also covered by: {also[(path, n)]}")
        out.append("\n".join(lines))

    with open(args.out, "w", encoding="ascii", newline="\n") as f:
        f.write("\n\n".join(out) + "\n")
    counts = ", ".join(f"{s} {sections[s]}" for s in SECTION.values())
    print(f"wrote {args.out}: {len(picks)} stories ({counts})")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list")
    ls.add_argument("files", nargs="+")
    bd = sub.add_parser("build")
    bd.add_argument("--out", required=True)
    bd.add_argument("--pick", action="append", required=True)
    bd.add_argument("--also", action="append", default=[])
    args = ap.parse_args()
    if args.cmd == "list":
        cmd_list(args.files)
    else:
        cmd_build(args)


if __name__ == "__main__":
    main()
