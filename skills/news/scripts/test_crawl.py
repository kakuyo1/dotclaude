#!/usr/bin/env python3
"""Offline check for the per-source cap in crawl_track.evaluate: no fetch beyond a source's room.

Usage: python test_crawl.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import crawl_track as ct  # noqa: E402


def run(rows, cap, fail=lambda row: False):
    calls = []

    def fake_checked(row, articles_dir):
        calls.append((row["source"], row["cand"]))
        if fail(row):
            return {"http": "403", "og_image": "", "og_description": "", "text": ""}, ""
        text = " ".join(["word"] * 30)
        return {"http": "200", "og_image": "", "og_description": "", "text": text}, text

    ct.fetch_checked = fake_checked
    stats = {r["source"]: {"kept": 0, "link_failed": 0, "no_text": 0, "capped": 0} for r in rows}
    kept = []
    ct.evaluate(rows, kept, stats, "unused", cap)
    return kept, stats, calls


def source(name, n):
    return [{"source": name, "cand": i} for i in range(1, n + 1)]


def main():
    kept, stats, calls = run(source("A", 40), 15)
    assert len(kept) == 15 and len(calls) == 15, "cap: fetched beyond the source's room"
    assert stats["A"]["capped"] == 25, stats["A"]

    kept, _, _ = run(source("A", 40), None)
    assert len(kept) == 30, "no cap: should stop at MAX_ITEMS"

    rows = source("A", 40) + source("B", 40)
    kept, stats, _ = run(rows, 15, fail=lambda r: r["source"] == "A" and r["cand"] <= 5)
    kept_by = {s: sum(k["source"] == s for k in kept) for s in ("A", "B")}
    assert kept_by == {"A": 15, "B": 15}, kept_by
    assert stats["A"]["link_failed"] == 5, stats["A"]
    print("cap checks passed")


if __name__ == "__main__":
    main()
