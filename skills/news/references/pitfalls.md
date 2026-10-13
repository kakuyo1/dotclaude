# Pitfalls from the runs

Each entry is a problem a run hit, what it cost, and what the scripts or the orchestrator now do
about it. Read it before changing a script or a feed list.

## Feeds and fetching

- **Parallel fetch.** The first run fetched feeds one by one inside each agent, and the agents
  spent most of their time waiting on the proxy. `scripts/fetch_feeds.py` and
  `scripts/fetch_articles.py` run ten to twelve requests at once. Sixteen article pages took
  about 10 seconds.
- **An error page comes back as 200.** `fetch_feeds.py` checks the body starts with an XML
  declaration or a feed root before it counts a feed as OK.
- **curl.exe versus curl.** The agents called `curl.exe` from PowerShell. The scripts call
  `curl`, which works under Git Bash, PowerShell, and Python on this machine.
- **Proxy.** Every request goes to `http://127.0.0.1:7890`. The proxy is set by hand in Windows,
  so check it first if every fetch fails at once.
- **Reuters through Google News.** The three Reuters links resolved from the Google News feed
  all returned 401: a DataDome interstitial, not an article. Reuters is off by default in
  `crawl_track.py`. Do not spend time on the Google News resolver again unless Reuters has a new
  access path. The resolver used in the run (`gnresolve.ps1`, batchexecute endpoint `Fbv4je`) is
  not kept in `scripts/`; it is not part of the normal path.
- **Ars Technica article pages.** Every article page returned 405 or 403 with an AWS WAF
  challenge, through curl, a browser user agent, and Scrapling. Ars is off by default in
  `crawl_track.py`. Expect the same until the WAF rule changes. The feed itself is fine.
- **Intel D270 in Hacker News.** Its page returns 403 from Akamai. `build_candidates.py` drops the
  item when its Link fails, so this needs no manual step.
- **arXiv feeds are often empty.** A valid channel with zero items is normal on weekends and
  some weekdays. `parse_feeds.py` reports `feed_items=0`; the track fills from the other sources.
- **Simon Willison is Atom.** Read `<entry>`, not `<item>`. `parse_feeds.py` handles both.
- **Hacker News descriptions are empty.** The feed description is a bare "Comments" link, so
  every Hacker News item needs its article page. `parse_feeds.py` flags these `needs_article`.
- **Techmeme links are its own permalinks.** The Link is `techmeme.com/...`, not the publisher.
  Its summaries come from the Techmeme digest text, which the plan allows.

## Images

- **Feed images are often blocked from the proxy.** `images.ft.com` returned a connection failure
  (curl code 000), and `npr.brightspotcdn.com` returned 403. Mark those `unverified`. Do not
  try to rewrite the URL.
- **A feed thumbnail can 401 while the article's `og:image` returns 200.** The international run
  hit this on one Guardian item (block 15). The plan allows swapping in the `og:image` of the
  same story.
- **Relative `og:image` values.** arXiv gives a relative path. `fetch_articles.py` drops it,
  because building an absolute URL counts as constructing one.
- **Headless Chrome needs the proxy passed explicitly.** A fresh profile does not inherit the
  Windows proxy, and the first screenshot run showed 15 of 16 images failing. `shoot_page.mjs`
  passes `--proxy-server`.
- **Full-page capture wedges the renderer.** One `Page.captureScreenshot` on the full height
  hangs once images are decoded. `shoot_page.mjs` captures viewport-height tiles and stitches
  them.

## Headless browser on this machine

- **Chromium path.** The Playwright build is at
  `C:/Users/admin/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe`. The
  `--window-size` flag clamps below about 500px on Windows, so set the width through
  `Emulation.setDeviceMetricsOverride` instead.
- **Dependencies.** `pngjs` is the only npm dependency. Run `npm install` once in
  `scripts/`. The version is `^7.0.0`; `^7.0.2` does not exist on the registry.

## Shell and PowerShell

- **Text-mode writes add CRLF.** Python on this machine writes `\r\n` in text mode, so a
  `Track: International\r` line fails an exact-match check. The scripts write with `newline="\n"`
  and read with CRLF normalised. Any new script that writes handover files must do the same.

- **No `grep` in Windows PowerShell.** The plan's `grep` test commands fail there. The Python
  scripts do the same checks, so use them. Git Bash has `grep` at
  `C:/Program Files/Git/bin/bash.exe` when a raw grep is needed.
- **Paths are per-runtime.** Git Bash `/tmp` is not the Windows temp folder. Scratch files go
  under `$TEMP`, and absolute paths in scripts are written for that folder.
- **Stopping a background launch leaves children running.** Find the process with
  `Get-CimInstance Win32_Process` and stop it by id. `watcher.ps1` writes its own log, so it is
  the place to look first.

## Team workflow

- **Waiting for a report.** The watcher cannot wake the orchestrator. A reviewer who checks only at
  long intervals can sit idle for minutes after the report lands. In the page run the report
  landed at 16:27 and the review at 16:33, a gap that added time to the run.
- **Read the report that matters.** The crawl reports were long and restated the plan. The
  orchestrator only needs `CANDIDATES.md` plus the mechanical checks. Stage 1 skips the
  IMPLEMENTATION.md review; the review is `check_candidates.py` and `check_urls.py`.
- **Permission dialogs for handover folders.** A few `Access external directory` dialogs did not
  clear after one Enter. Check the pane when the log says `approval did not clear the prompt`.
- **One run, one watcher.** Two watchers on the same worktrees race on `state.json`. The page job
  ran with its own `jobs-html.json` for this reason.
