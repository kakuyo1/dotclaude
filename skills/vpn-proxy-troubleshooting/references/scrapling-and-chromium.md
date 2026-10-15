# scrapling, curl_cffi, and Chromium

## scrapling and curl_cffi

scrapling sits on curl_cffi, whose proxy behaviour differs from curl.exe.

1. The CLI writes text only. `scrapling extract get` accepts `.md`, `.html`, and `.txt`, and raises
   `ValueError: Unknown file type` on binaries. Download images and files through the Python API:
   ```python
   from scrapling.fetchers import FetcherSession
   with FetcherSession(impersonate='chrome', proxy='http://127.0.0.1:7890', timeout=60) as s:
       page = s.get(url, headers={'Accept': 'image/png,image/*;q=0.8'})
       open('out.png', 'wb').write(page.body)   # page.body is raw bytes
   ```
2. curl_cffi ignores the `HTTPS_PROXY` env var. Pass `proxy=` to the session explicitly.
3. `Fetcher.get(url, proxy=...)` silently drops the kwarg (the log shows `Proxy 'None'`). Use
   `FetcherSession(proxy=...)`.
4. `Failed to connect ... over proxy ... after 0 ms` is transient or host-specific. Retry once, or fetch the
   target's direct link. When en.wikipedia.org works but upload.wikimedia.org does not, fetch the direct
   link first.
5. 403 means anti-scraping: add `impersonate='chrome'`. Wikimedia returns WebP under an image `Accept`
   header even when the filename ends in `.png`. Force `Accept: image/png` to get a real PNG.
6. Wikimedia direct links: `action=query&prop=imageinfo&iiprop=url&iiurlwidth=1200` returns a thumburl.
   Requesting that beats following the `Special:FilePath` redirect.

venv: `~/.claude/skills/scrapling/.venv/Scripts/python.exe` (scrapling[all] bundles playwright).

## Chromium without downloading a browser

`playwright install chromium` is itself a blocked download. Use the system Chrome:

```python
browser = p.chromium.launch(channel='chrome')   # system Chrome, no chromium download
page = browser.new_page(device_scale_factor=2)  # 2x sharpness
page.goto(f"file://{pathlib.Path(src).resolve()}")
page.wait_for_load_state("networkidle")         # wait for webfonts and other assets
page.locator("svg").first.screenshot(path=out, omit_background=True)
```
