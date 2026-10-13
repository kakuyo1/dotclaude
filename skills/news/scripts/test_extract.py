#!/usr/bin/env python3
"""Offline check for body_text: a short <article> wrapper must fall back to the page body.

Usage: python test_extract.py [ITEMS.json]

With ITEMS.json, also checks that every item kept by crawl_track.py has article_http 200 and at
least MIN_WORDS words of text.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fetch_articles as fa  # noqa: E402

LONG = "<p>" + " ".join(["Word"] * 40) + "</p>"


def main():
    wrapper = "<html><body><article><p>Comments</p></article>" + LONG + LONG + "</body></html>"
    assert len(fa.body_text(wrapper).split()) >= fa.MIN_WORDS, "short <article> did not fall back to the page"
    body = "<html><body><article>" + LONG + "</article></body></html>"
    assert len(fa.body_text(body).split()) == 40, "<article> body not extracted"
    nav = "<p>" + " ".join(["Focus"] * 30) + "</p>"
    arxiv = ('<html><head><meta property="og:description" content="' + " ".join(["Abstract"] * 30)
             + '"></head><body>' + nav + "</body></html>")
    assert fa.body_text(arxiv).startswith("Abstract"), "navigation text used instead of the description"
    if len(sys.argv) > 1:
        with open(sys.argv[1], encoding="utf-8") as f:
            items = json.load(f)["items"]
        for item in items:
            assert item["article_http"] == "200", f"item {item['id']} kept with http {item['article_http']}"
            assert len(item["text"].split()) >= fa.MIN_WORDS, f"item {item['id']} kept with too little text"
        print(f"items ok: {len(items)}")
    print("body_text checks passed")


if __name__ == "__main__":
    main()
