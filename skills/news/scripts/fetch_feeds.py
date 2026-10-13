#!/usr/bin/env python3
"""Fetch RSS or Atom feeds through the local proxy, in parallel, and confirm each body is XML.

Usage: python fetch_feeds.py OUT_DIR NAME=URL [NAME=URL ...]

Writes OUT_DIR/NAME.xml for each feed. A 200 response that is not XML (an error page, a
block page) counts as a failure. Exit 1 if any feed fails.
"""
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

PROXY = "http://127.0.0.1:7890"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
XML_START = (b"<?xml", b"<rss", b"<feed", b"<rdf:RDF")


def fetch(name, url, out_dir):
    path = os.path.join(out_dir, name + ".xml")
    r = subprocess.run(
        ["curl", "-sS", "-L", "-x", PROXY, "--max-time", "60", "-A", UA,
         "-o", path, "-w", "%{http_code}", url],
        capture_output=True, text=True,
    )
    code = r.stdout.strip() if r.returncode == 0 else f"curl-exit-{r.returncode}"
    size = os.path.getsize(path) if os.path.exists(path) else 0
    head = b""
    if size:
        with open(path, "rb") as f:
            head = f.read(300).lstrip(b"\xef\xbb\xbf \r\n\t")
    is_xml = head.startswith(XML_START)
    ok = code == "200" and is_xml
    note = "" if ok else (r.stderr.strip() or "body is not XML")
    return name, code, size, is_xml, ok, note


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    feeds = [arg.partition("=") for arg in sys.argv[2:]]
    feeds = [(name, url) for name, _, url in feeds if url]

    with ThreadPoolExecutor(max_workers=10) as pool:
        results = list(pool.map(lambda f: fetch(f[0], f[1], out_dir), feeds))

    failed = 0
    for name, code, size, is_xml, ok, note in results:
        status = "OK  " if ok else "FAIL"
        print(f"{status} {name:<22} http={code:<14} bytes={size:<8} xml={is_xml} {note}")
        failed += not ok
    print(f"{len(results) - failed}/{len(results)} feeds OK")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
