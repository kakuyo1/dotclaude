#!/usr/bin/env python3
"""Offline checks for crawl_track: the per-source cap in evaluate, the earlier-digest drop in drop_reported,
and the Techmeme article link.

Usage: python test_crawl.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import crawl_track as ct  # noqa: E402

REAL_FETCH_CHECKED = ct.fetch_checked  # run() swaps in a fake, so keep the real one


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


def check_drop():
    class Known:
        def repeat(self, link):
            return "news-2026-10-13-1633.html" if link == "https://x.test/old" else None

    win = [{"link": "https://x.test/old", "article": "https://x.test/old", "title": "old"},
           {"link": "https://x.test/new", "article": "https://x.test/new", "title": "new"},
           {"link": "https://www.techmeme.com/261025/p1#a", "article": "https://x.test/old", "title": "tm"}]
    fresh, dropped = ct.drop_reported(win, Known())
    assert [i["title"] for i in fresh] == ["new"], fresh
    assert [(page, i["title"]) for page, i in dropped] == [("news-2026-10-13-1633.html", "old"),
                                                           ("news-2026-10-13-1633.html", "tm")], dropped


def check_article_link():
    tm = "https://www.techmeme.com/261025/p13#a261025p13"
    pub = "https://www.ifixit.com/News/119895/iphone-duo-teardown"
    assert ct.article_link({"link": tm, "outlinks": ["https://www.techmeme.com/x", pub]}) == pub
    assert ct.article_link({"link": tm, "outlinks": ["https://www.techmeme.com/x"]}) == ""
    hn = "https://news.ycombinator.com/item?id=1"
    assert ct.article_link({"link": hn, "outlinks": ["https://other.test/a"]}) == hn
    gift = "https://www.bloomberg.com/news/x?id=3&accessToken=abc&sharetype=gift"
    assert ct.article_link({"link": tm, "outlinks": [gift]}) == "https://www.bloomberg.com/news/x?id=3", gift
    page, text = REAL_FETCH_CHECKED({"cand": 1, "article": "", "description": "headline"}, "unused")
    assert page["http"] != "200" and text == "", (page, text)


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
    check_drop()
    check_article_link()
    print("crawl checks passed")


if __name__ == "__main__":
    main()
