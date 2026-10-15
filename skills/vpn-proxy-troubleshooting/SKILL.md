---
name: vpn-proxy-troubleshooting
description: >
  Use when a network call fails and the target may be blocked: curl exit 35, 28, or 7, connection
  reset, 403 on a foreign site, failed git clone/push, ssh, pip, playwright, or scrapling download; or
  when the user says 代理 / VPN / 翻墙 / 被墙 / 上不了网 / 下载失败 / 网络不通. Finds the local proxy
  port, routes a tool through it, and covers the tools that ignore the proxy (SSH, curl_cffi and
  scrapling, Chromium, git over schannel).
---

# VPN / proxy troubleshooting

Check the route before suspecting the code.

## 1. Find the proxy

Run `bash scripts/probe_proxy.sh [url]`. It reads the Windows system proxy, checks the common local ports,
makes a live request through each one, and prints the `export` line for the first port that answers. The
default target is Wikipedia, so pass your real target as the argument.

- A port that answers Wikipedia but fails your target does not prove the proxy is dead. Test the target:
  `curl -x http://127.0.0.1:7890 -o "$TEMP/probe.out" -w "%{http_code}\n" <url>`
- No port answers: ask whether the VPN client runs in system-proxy or TUN mode.
- No proxy at all: the target is blocked, and nothing here routes around it. For GitHub, try the mirror
  `https://ghfast.top/https://github.com/...`. For other targets, say so plainly and offer what is left: a
  retry with a short timeout, or running the network step on a machine with a VPN.

## 2. Route a tool through it

- curl, git, and pip read the environment: `export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890`.
  Each Bash call is a fresh shell, so export in the same command.
- One call: `curl -x http://127.0.0.1:7890 <url>`.
- Chromium inherits the Windows system proxy.
- SSH ignores the environment. See `references/ssh-and-git.md`.
- curl_cffi and scrapling need an explicit `proxy=`. See `references/scrapling-and-chromium.md`.

## 3. Read the symptom

| Symptom | Meaning | Go to |
| --- | --- | --- |
| Direct request exits 28 after about 20 s, but the same URL works through the proxy | The direct route is blocked. The proxy is doing its job. | Route a tool through it |
| curl exit 7, `Could not connect to server ... after 0 ms` | The proxy port is closed, or the proxy refused this target at once. | Find the proxy |
| curl exit 35 with `CRYPT_E_REVOCATION_OFFLINE` | Schannel could not reach the revocation server. Usually transient. | `references/schannel.md` |
| curl exit 35 with `failed to receive handshake` or `UNEXPECTED_EOF` | The TLS handshake is cut on this route. Test which layer fails. | `references/schannel.md` |
| 403 or another 4xx | The network works; the server is refusing the client. | `references/scrapling-and-chromium.md` |
| `git push` → `Please make sure you have the correct access rights` | Usually a dropped SSH connection, not a key problem. | `references/ssh-and-git.md` |
| `ssh -T git@github.com` → `Connection closed ... port 22/443` | The SSH handshake was reset. | `references/ssh-and-git.md` |
| scrapling `Failed to connect ... over proxy ... after 0 ms` | Transient or host-specific. | `references/scrapling-and-chromium.md` |

## 4. Diagnose in this order

1. Reproduce the failure through the proxy against the exact URL. If it does not reproduce, treat it as
   transient and retry once.
2. Separate the route from the client. Run the same URL through a second TLS stack (Python's OpenSSL, see
   `references/schannel.md`). Both stacks failing points at the route, but a host that flaps needs several
   tries before you call it blocked. If it fails consistently, change the Clash node or rule, not the code.
   If only curl or git fails, the problem is its TLS backend.
3. For a tool that ignores the proxy environment, use its own proxy option. Do not assume the environment applies.
4. Only then look at code.

Retry at most once. If a feed fails twice, skip it and report it.

Do not turn off TLS checks (`--ssl-no-revoke`, `-k`) to make a request pass. Use one only when the user
accepts the risk for that host.
