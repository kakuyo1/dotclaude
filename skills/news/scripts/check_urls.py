#!/usr/bin/env python3
"""Check that every Link and Image in a CANDIDATES.md or SELECTED.md answers 200 through the proxy.

Usage: python check_urls.py FILE.md [--workers 10] [--out results.json]

Every Link is checked. Every Image that is a URL is checked. Image values "none" and
"unverified" are skipped. Each failing URL is retried once. The script prints each failure
and a summary, and exits 1 if any Link fails or any Image fails without being marked
unverified in the file.
"""
import argparse
import json
import os
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor

PROXY = "http://127.0.0.1:7890"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"


def http_code(url):
    r = subprocess.run(
        ["curl", "-sS", "-L", "-x", PROXY, "--max-time", "45", "-A", UA,
         "-o", os.devnull, "-w", "%{http_code}", url],
        capture_output=True, text=True,
    )
    return r.stdout.strip() if r.returncode == 0 else f"curl-exit-{r.returncode}"


def check(url):
    code = http_code(url)
    if code != "200":
        time.sleep(2)
        code = http_code(url)
    return code


def fields(path):
    block = 0
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^## (\d+)\s*$", line)
            if m:
                block = int(m.group(1))
                continue
            m = re.match(r"^(Link|Image): (.+?)\s*$", line)
            if m:
                value = re.sub(r"\s*\|\s*none$", "", m.group(2)).strip()
                out.append((block, m.group(1), value))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--out")
    args = ap.parse_args()

    rows = [(b, kind, v) for b, kind, v in fields(args.file)
            if v not in ("none", "unverified", "")]
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        codes = list(pool.map(lambda r: check(r[2]), rows))

    results = [{"block": b, "kind": k, "url": v, "http": c}
               for (b, k, v), c in zip(rows, codes)]
    bad_links = [r for r in results if r["kind"] == "Link" and r["http"] != "200"]
    bad_images = [r for r in results if r["kind"] == "Image" and r["http"] != "200"]

    for r in bad_links + bad_images:
        print(f"FAIL block {r['block']:>2} {r['kind']:<5} http={r['http']} {r['url']}")
    links = sum(r["kind"] == "Link" for r in results)
    images = sum(r["kind"] == "Image" for r in results)
    print(f"links 200: {links - len(bad_links)}/{links}   images 200: {images - len(bad_images)}/{images}")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=1)
    raise SystemExit(1 if bad_links or bad_images else 0)


if __name__ == "__main__":
    main()
