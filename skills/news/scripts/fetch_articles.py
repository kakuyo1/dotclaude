#!/usr/bin/env python3
"""Fetch article pages through the proxy, in parallel, and extract body text and og:image.

Usage: python fetch_articles.py OUT_DIR ITEMS.json [ITEMS.json ...] [--out articles.json] [--workers 8]

Each ITEMS.json is parse_feeds.py output, or a plain JSON list of items with a "link" field.
Items from all files are fetched together. Each page is saved as OUT_DIR/<index>.html. The
result is a list in the same order as the items, with the index also recorded in each row:

  {index, link, http, og_image, og_description, text}

og_image is kept only when it is an absolute http(s) URL; a relative value is dropped, since
constructing an image URL is not allowed. text is up to 1400 characters of paragraph text, taken
from the <article> element when present; a longer body keeps its opening, middle, and closing.
Writing a summary from text is the agent's job, not this script's.
"""
import argparse
import html
import json
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor

PROXY = "http://127.0.0.1:7890"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
TEXT_LIMIT = 1400
SAMPLE_CAP = 6 * TEXT_LIMIT
MIN_WORDS = 25
MARKERS = ("[Opening excerpt]\n", "\n[Middle excerpt]\n", "\n[Closing excerpt]\n")


def get(url, out_path):
    r = subprocess.run(
        ["curl", "-sS", "-L", "-x", PROXY, "--max-time", "45", "-A", UA,
         "-o", out_path, "-w", "%{http_code}", url],
        capture_output=True, text=True,
    )
    return r.stdout.strip() if r.returncode == 0 else f"curl-exit-{r.returncode}"


def meta(page, prop):
    for pat in (
        r'<meta[^>]+(?:property|name)=["\']%s["\'][^>]+content=["\']([^"\']*)' % prop,
        r'<meta[^>]+content=["\']([^"\']*)["\'][^>]+(?:property|name)=["\']%s["\']' % prop,
    ):
        m = re.search(pat, page, re.I)
        if m:
            return html.unescape(m.group(1)).strip()
    return ""


def sample(text, limit):
    """A text over the limit keeps its opening, middle, and closing, in that order.

    A plain prefix loses what a long analysis concludes, and the closing is where a piece says
    what it found. The markers tell the reader the middle was cut.
    """
    if len(text) <= limit:
        return text
    room = limit - sum(len(m) for m in MARKERS)
    head, middle = int(room * 0.4), int(room * 0.3)
    tail = room - head - middle
    start = max(0, len(text) // 2 - middle // 2)
    return (MARKERS[0] + text[:head].rstrip()
            + MARKERS[1] + text[start:start + middle].strip()
            + MARKERS[2] + text[-tail:].lstrip())


def paragraphs(seg):
    seg = re.sub(r"(?is)<(script|style|nav|header|footer|aside|form)[^>]*>.*?</\1>", " ", seg)
    paras = []
    total = 0
    for p in re.findall(r"(?is)<p[^>]*>(.*?)</p>", seg):
        t = html.unescape(re.sub(r"<[^>]+>", "", p))
        t = re.sub(r"\s+", " ", t).strip()
        if len(t) < 40:
            continue
        paras.append(t)
        total += len(t) + 1
        if total > SAMPLE_CAP:
            break
    return sample(" ".join(paras), TEXT_LIMIT)


def body_text(page):
    # <article>, then the page's own description, then every paragraph on the page. A whole-page
    # scan is the last resort: on some pages (arXiv) it picks up navigation text instead.
    m = re.search(r"(?is)<article[^>]*>.*?</article>", page)
    candidates = [paragraphs(m.group(0))] if m else []
    candidates.append(meta(page, "og:description") or meta(page, "description"))
    candidates.append(paragraphs(page))
    for text in candidates:
        if len(text.split()) >= MIN_WORDS:
            return text
    return candidates[-1]


def work(index, item, out_dir):
    path = os.path.join(out_dir, f"{index}.html")
    code = get(item["link"], path)
    page = ""
    if code == "200" and os.path.exists(path):
        with open(path, "rb") as f:
            page = f.read().decode("utf-8", "replace")
    og = meta(page, "og:image")
    return {
        "index": index,
        "link": item["link"],
        "http": code,
        "og_image": og if og.startswith(("http://", "https://")) else "",
        "og_description": meta(page, "og:description") or meta(page, "description"),
        "text": body_text(page),
    }


def load_items(path):
    with open(path, encoding="utf-8-sig") as f:
        data = json.load(f)
    return data["items"] if isinstance(data, dict) else data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("items", nargs="+")
    ap.add_argument("--out")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    items = [item for path in args.items for item in load_items(path)]
    os.makedirs(args.out_dir, exist_ok=True)

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(lambda pair: work(pair[0], pair[1], args.out_dir),
                                enumerate(items, start=1)))

    text = json.dumps(results, ensure_ascii=False, indent=1)
    out = args.out or os.path.join(args.out_dir, "articles.json")
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    ok = sum(r["http"] == "200" for r in results)
    print(f"{ok}/{len(results)} pages fetched with http 200 -> {out}")


if __name__ == "__main__":
    main()
