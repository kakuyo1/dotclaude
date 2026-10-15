#!/usr/bin/env python3
"""Offline check for fetch_feeds.fetch: a failed feed gets one more try, and a good one does not.

Usage: python test_fetch_feeds.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fetch_feeds  # noqa: E402


def scripted(outcomes):
    """A stand-in for fetch_once that succeeds or fails in the order given, and records each call."""
    calls = []

    def once(name, url, out_dir):
        ok = outcomes[len(calls)]
        calls.append(name)
        return name, "200" if ok else "curl-exit-35", 10, ok, ok, ""

    return once, calls


def main():
    once, calls = scripted([False, True])
    fetch_feeds.fetch_once = once
    assert fetch_feeds.fetch("feed", "url", "unused")[4] is True and len(calls) == 2, calls

    once, calls = scripted([True])
    fetch_feeds.fetch_once = once
    assert fetch_feeds.fetch("feed", "url", "unused")[4] is True and len(calls) == 1, calls

    once, calls = scripted([False, False])
    fetch_feeds.fetch_once = once
    assert fetch_feeds.fetch("feed", "url", "unused")[4] is False and len(calls) == 2, calls
    print("fetch checks passed")


if __name__ == "__main__":
    main()
