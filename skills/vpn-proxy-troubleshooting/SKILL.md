---
name: vpn-proxy-troubleshooting
description: >
  Diagnose and fix proxy/VPN/network failures on this machine (China network, GFW-blocked sites):
  locating the local proxy port, routing tools through it, and the per-tool traps that ignore it —
  curl_cffi, scrapling, SSH, Chromium.
  Use on any failed network call — curl exit 35 (SSL connect error) / 28 (timeout) / 7 (can't
  connect), connection resets, 403 on foreign sites, or failed downloads, git clone/push, ssh, pip,
  playwright, scrapling — or when the user says 代理 / VPN / 翻墙 / 被墙 / 上不了网 / 下载失败 / 网络不通.
---
# VPN / proxy troubleshooting

## Triage: is there a proxy at all?

Establish whether this machine has a working proxy before concluding anything — ask the user, or run
`scripts/probe_proxy.sh`.

**No proxy** → the target is GFW-blocked and there is nothing to route through. That is the answer,
not a tool bug. Skip port probing — there is no port to probe.

- GitHub target: try the `ghfast.top` mirror first.
  ```bash
  git clone https://ghfast.top/https://github.com/user/repo.git
  curl -L -o file.zip https://ghfast.top/https://github.com/user/repo/releases/download/v1.0/file.zip
  ```
- Mirror also fails, or the target is elsewhere (Wikipedia, Google, foreign downloads): say plainly
  that GFW blocks it, no proxy is available, and it cannot be worked around. Options that remain:
  retry intermittently with a fast-fail timeout so commands don't hang, or move the network work to a
  machine that has a VPN.

**Proxy present** → start at §1 for the port, then §2–§5 as needed.

## Symptom → meaning

| Symptom | Meaning |
| --- | --- |
| curl exit 35 (SSL connect error) | target blocked / connection reset — proxy not taking effect |
| curl exit 28 (timeout) | the same, timeout flavour |
| exit 7 (`Could not connect to server ... after 0 ms`) | proxy port isn't open, or the proxy refused this target instantly |
| 403 / other 4xx | network is fine; the target is blocking the client (switch impersonate / UA / direct link) |
| `git push` → `Please make sure you have the correct access rights...` | usually a dropped SSH connection, not a key problem — test SSH (§3) before touching keys |
| `ssh -T git@github.com` → `Connection closed by ... port 22/443` | GFW reset the SSH handshake (§3) |

Probe the proxy before suspecting the code.

## Diagnostic order

Direct attempt fails → `probe_proxy.sh` for port and liveness → retry through the proxy → check the
tool's own proxy option (curl_cffi and requests differ; don't assume env vars apply) → retry once or
switch to a direct link (transient failures are common) → if the user says the VPN is up but nothing
listens, ask whether their client runs in system-proxy or TUN mode.

Exception: git push / ssh failures skip this loop. SSH takes no HTTP proxy env — go to §3. A curl
verdict from `probe_proxy.sh` says nothing about SSH.

## 1. Locate the local proxy

```bash
bash scripts/probe_proxy.sh
```

It runs all three checks and prints the ready-to-use `export https_proxy=...` line for the port that
works: the Windows system proxy registry key, the listening common ports, and a live request through
each port.

`ProxyEnable=1` plus a `ProxyServer` value in that registry key means a system proxy is configured:

```bash
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" | grep -iE "proxy|enable"
```

## 2. Route a tool through the proxy

- General env vars, enough for curl / git / pip:
  ```bash
  export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
  ```
- One call: `curl -x http://127.0.0.1:7890 <url>`
- Chrome / Playwright: nothing to configure — Chromium inherits the Windows system proxy (§5).
- Each Bash call is a fresh shell, so env vars do not persist: export and use within the same command.

## 3. SSH / git — the HTTP proxy does not apply

SSH ignores `https_proxy`. GFW interference on GitHub is selective and intermittent: at the same
moment a plain HTTPS download can succeed while the SSH handshake is reset, on port 22 and 443 alike.
A reachable TCP port does not mean the handshake passes — the block sits at the protocol layer.

Route SSH through Clash's SOCKS port (7890 is a mixed port, SOCKS5 works) via `connect.exe`, which
ships with Git for Windows:

```bash
# 1. locate it (portable across drives from bash)
command -v connect || cygpath -w /mingw64/bin/connect.exe

# 2. smoke-test the tunnel: an SSH banner means it works
timeout 12 /mingw64/bin/connect.exe -S 127.0.0.1:7890 ssh.github.com 443 </dev/null
# success prints: SSH-2.0-...

# 3. one-off push, no permanent config change
GIT_SSH_COMMAND='ssh -o ProxyCommand="/mingw64/bin/connect.exe -S 127.0.0.1:7890 %h %p"' git push origin master
```

To make it permanent, add a github.com block to `~/.ssh/config`. ssh config is read by cmd, so it
needs a Windows absolute path — take the real one from `cygpath -w /mingw64/bin/connect.exe`:

```ini
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    ProxyCommand <absolute path to connect.exe> -S 127.0.0.1:7890 %h %p
```

With Clash closed this ProxyCommand makes SSH fail outright. Accepted trade-off: direct SSH is
intermittent anyway, and the proxy route is steadier.

## 4. scrapling / curl_cffi traps

scrapling sits on curl_cffi, whose proxy behaviour differs from curl.exe:

1. The CLI writes text only — `scrapling extract get` accepts `.md` / `.html` / `.txt` and raises
   `ValueError: Unknown file type` on binaries. Download images and files through the Python API:
   ```python
   from scrapling.fetchers import FetcherSession
   with FetcherSession(impersonate='chrome', proxy='http://127.0.0.1:7890', timeout=60) as s:
       page = s.get(url, headers={'Accept': 'image/png,image/*;q=0.8'})
       open('out.png', 'wb').write(page.body)   # page.body is raw bytes
   ```
2. curl_cffi ignores the `HTTPS_PROXY` env var — pass `proxy=` to the session explicitly.
3. `Fetcher.get(url, proxy=...)` silently drops the kwarg (the log shows `Proxy 'None'`) — use
   `FetcherSession(proxy=...)`.
4. `Failed to connect ... over proxy ... after 0 ms` is a transient or host-specific failure. Retry
   once, or switch to the target's API for a direct link; when en.wikipedia.org works but
   upload.wikimedia.org does not, fetch the direct link first.
5. 403 means anti-scraping: add `impersonate='chrome'`. When downloading images Wikimedia hands back
   WebP under an image `Accept` header even though the filename ends in `.png` — force
   `Accept: image/png` to get a real PNG.
6. Direct links (Wikimedia family): `action=query&prop=imageinfo&iiprop=url&iiurlwidth=1200` returns a
   thumburl; requesting that beats following the `Special:FilePath` redirect.

venv: `~/.claude/skills/scrapling/.venv/Scripts/python.exe` (scrapling[all] bundles playwright).

## 5. Chromium without downloading a browser

`playwright install chromium` is itself a blocked download. Use the system Chrome instead:

```python
browser = p.chromium.launch(channel='chrome')   # system Chrome, no chromium download
page = browser.new_page(device_scale_factor=2)  # 2x sharpness
page.goto(f"file://{pathlib.Path(src).resolve()}")
page.wait_for_load_state("networkidle")         # wait for webfonts and other assets
page.locator("svg").first.screenshot(path=out, omit_background=True)
```
