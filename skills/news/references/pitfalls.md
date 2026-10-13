# Pitfalls from the runs

Each entry is a problem a run hit, what it cost, and what the scripts or the orchestrator now do
about it. Read it before changing a script or a feed list.

## Feeds and fetching

- **Dead items reached the summaries.** The first 2026-10-13 run picked 30 candidates in feed order
  and checked Links only after the implementer had summarised them. Thirteen Techmeme permalinks
  returned 403, so the list fell to 12 blocks. The implementer then asked for help, which cost about
  four minutes. `crawl_track.py` now keeps an item only when its Link answers 200 and it has 25 words of
  text, and it tries further candidates to fill the list.
- **Techmeme permalinks.** The Link is `techmeme.com/...`, which answered 403 through the proxy during
  that run. The Techmeme feed itself fetches fine. Techmeme items drop out at the crawl, and their
  summaries come from the digest text when they do pass.
- **Hacker News items need their article pages.** The feed has no description, so the crawl reads the
  page. Some pages return 403, a TLS error, or a JavaScript shell with no paragraphs. Those items drop.
- **A short `<article>` can wrap no body.** On bbc.com, the `<article>` block was 2241 characters with
  no paragraphs, so text came out empty. `fetch_articles.body_text` now tries the `<article>` body, then
  the page's own description, then every paragraph on the page.
- **Navigation text as body.** An arXiv abstract page gave navigation text ("Focus to learn more",
  "Submission history") when every paragraph was read. The page's description holds the abstract, and
  it is now tried before the whole-page scan.
- **arXiv feeds are often empty.** A valid channel with zero items is normal. `parse_feeds.py` reports
  `feed_items=0`, and the track fills from other sources.
- **Simon Willison is Atom.** Read `<entry>`, not `<item>`. `parse_feeds.py` handles both.
- **Reuters through Google News.** The Google News links resolve to a DataDome 401 page. Reuters is off
  by default. Do not spend time on the resolver again unless Reuters has a new access path.
- **Ars Technica article pages** return 405 or 403 behind an AWS WAF challenge. Ars is off by default.
- **Feed images are often blocked from the proxy.** `images.ft.com` returned curl code 000, and
  `npr.brightspotcdn.com` returned 403. Those images are marked `unverified`. Do not rewrite the URL.
- **A feed thumbnail can 401 while the article's `og:image` returns 200.** `build_candidates.py` falls
  back to the `og:image`.
- **Relative `og:image` values** are dropped, because building an absolute URL counts as constructing one.
- **An error page can come back as 200.** `fetch_feeds.py` checks the body starts with an XML declaration
  or a feed root before it counts a feed as OK.

## Screenshots

- **Chrome path is not stored in the scripts.** `shoot_page.mjs` takes `--chrome`, else the
  `CHROME_PATH` environment variable, else the first `chrome`, `chromium`, or `msedge` on `PATH`. An
  earlier version named a Playwright path on one machine, which failed at spawn with ENOENT.
- **Headless Chrome needs the proxy passed explicitly.** A fresh profile does not inherit the system
  proxy, so `shoot_page.mjs` passes `--proxy-server`. The first screenshot run showed 15 of 16 images
  failing without it.
- **Full-page capture wedges the renderer.** `shoot_page.mjs` captures viewport-height tiles and stitches
  them.
- **The window width clamps on Windows.** Set the 390px width through `Emulation.setDeviceMetricsOverride`
  rather than `--window-size`.
- **Dependencies.** `pngjs` is the only npm dependency. Run `npm install` once in `scripts/`.

## Team workflow

- **Waiting for a report.** The watcher cannot wake the orchestrator. A reviewer who checks only at long
  intervals can sit idle for minutes after the report lands. Start the background wait in SKILL.md.
- **No review or report for crawl jobs.** The implementer writes only `CANDIDATES.md`. The orchestrator
  does not rerun checks and does not write `REVIEW.md`. An earlier run read both reports and reviewed
  them anyway, which cost time for nothing.
- **A short crawl stopped the implementer.** The plan told the implementer to stop on exit 1, so a track
  with 24 usable items never produced `CANDIDATES.md`. The plan now continues, and the shortfall goes in
  the report.
- **Permission dialogs for handover folders.** A few `Access external directory` dialogs did not clear
  after one Enter. Check the pane when the log says `approval did not clear the prompt`.
- **One run, one watcher.** Two watchers on the same worktrees race on `state.json`. Use a separate jobs
  file for each run.

## Shell

- **Text-mode writes add CRLF.** Python on Windows writes `\r\n` in text mode, so a `Track: International\r`
  line fails an exact-match check. The scripts write with `newline="\n"` and read with CRLF normalised.
  Any new script that writes handover files must do the same.
- **Paths are per-runtime.** Git Bash `/tmp` is not the Windows temp folder. Scratch files go under
  `$TEMP`, and absolute paths in scripts are written for that folder.
- **Stopping a background launch leaves children running.** Find the process by its command line and stop
  it by id. `watcher.ps1` writes its own log, so check it first.
- **Interpreter choice.** Use the Python the scripts were generated with (`write_crawl_job.py` writes its
  `sys.executable` into the plan). A bare `python3` can be a stub that exits without running.
