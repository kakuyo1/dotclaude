#!/usr/bin/env python3
"""Offline check for reported.py: digest parsing, link matching, and the title flag.

Usage: python test_reported.py
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reported  # noqa: E402

NAME = "news-2026-10-13-1633.html"
PAGE = """<!DOCTYPE html>
<html><body>
<article class="card lead">
<p class="eyebrow">BBC News</p>
<h3 class="headline"><a href="https://www.bbc.co.uk/news/articles/ck1?at_medium=RSS&amp;at_campaign=rss">Pope diagnosed with lung cancer but had successful surgery</a></h3>
<p class="also">Also covered by: <a href="https://www.npr.org/2026/10/13/g-s1-147968/pope-leo?traffic_source=rss">NPR</a></p>
</article>
<article class="card">
<h3 class="headline"><a href="https://news.ycombinator.com/item?id=1">Ask HN: Pulse Local</a></h3>
</article>
</body></html>
"""
HN_HEADLINE = '<h3 class="headline"><a href="https://news.ycombinator.com/item?id=1">Ask HN: Pulse Local</a></h3>'


def load_text(text):
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, NAME), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        return reported.load(d)


def main():
    history = load_text(PAGE)
    # &amp; in the page, and tracking parameters or a fragment in the feed link, must not change the match
    assert history.repeat("https://www.bbc.co.uk/news/articles/ck1") == NAME
    assert history.repeat("https://www.bbc.co.uk/news/articles/ck1/?at_medium=RSS&at_campaign=rss#top") == NAME
    # an Also covered link counts as reported too
    assert history.repeat("https://www.npr.org/2026/10/13/g-s1-147968/pope-leo") == NAME
    # HN item links differ only in their query, so the query must keep them apart
    assert history.repeat("https://news.ycombinator.com/item?id=1") == NAME
    assert history.repeat("https://news.ycombinator.com/item?id=2") is None
    assert history.similar("Pope diagnosed with lung cancer after successful surgery")[0] == NAME
    assert history.similar("Russia detains Japanese journalist") is None
    # a page whose stories do not all parse must fail, not shorten the history
    try:
        load_text(PAGE.replace(HN_HEADLINE, ""))
    except ValueError:
        pass
    else:
        raise AssertionError("a page with a missing headline was accepted")
    print("reported checks passed")


if __name__ == "__main__":
    main()
