---
name: vpn-proxy-troubleshooting
description: >
  Diagnose and fix proxy/VPN/network issues on this Windows machine (China network, GFW-blocked sites).
  Use whenever any network call fails — curl exit 35 (SSL connect error) / 28 (timeout) / 7 (can't connect),
  connection resets, or 403 on foreign sites like Wikipedia/GitHub/Google — or whenever downloads, git
  clone, pip, playwright, or scrapling fail, or the user mentions 代理 / VPN / 翻墙 / 被墙 / 上不了网 /
  下载失败 / 网络不通. Covers: locating the local Clash/V2Ray proxy (Windows registry + netstat + port
  probing), routing tools through it (env vars vs per-tool flags), and tool-specific pitfalls: scrapling
  CLI cannot download binaries (use FetcherSession with an explicit proxy), curl_cffi ignores env proxy
  vars, scrapling's Fetcher.get swallows the proxy kwarg, and Playwright/Chrome inherits the Windows
  system proxy automatically.
---

# VPN / 代理排障

本机环境：Windows 10 + Clash 系统代理（127.0.0.1:7890，用户手动开关）。国内网络直连 Wikipedia、Google 等境外站点会失败。以下内容来自本机实战踩坑，先跑 `scripts/probe_proxy.sh` 一步定位，再按需看各节。

## 0. 症状 → 判断

| 症状 | 含义 |
|---|---|
| curl exit 35（SSL connect error） | 目标被墙 / 连接被重置，代理没生效 |
| curl exit 28（timeout） | 同上（超时版） |
| exit 7（Could not connect to server ... after 0 ms） | 代理端口没开，或该目标走代理被秒拒 |
| 403 / 4xx | 网络通，但被目标反爬（换 impersonate / UA / 直链） |

**第一反应永远是先探测代理，不要直接怀疑代码。**

## 1. 找到本机代理

```bash
# Windows 系统代理设置（ProxyEnable=1 且 ProxyServer 有值 = 有代理）
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" | grep -iE "proxy|enable"

# 监听中的常见代理端口
netstat -an | grep LISTENING | grep -E "127.0.0.1:(7890|7897|1080|10809|8888|8118|2080|9910)"

# 逐个验证哪个端口真能连到境外（curl 走代理测试）
for p in 7890 7897 10809 1080 8118 8888; do
  timeout 3 curl -s -o /dev/null -w "port $p: %{http_code}\n" -x "http://127.0.0.1:$p" "https://en.wikipedia.org" 2>/dev/null && break
done
```

或直接跑 `scripts/probe_proxy.sh`，它把上面三步合并输出结论。

## 2. 让工具走代理

- **通用环境变量**（curl / git / pip 大部分场景）：
  ```bash
  export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
  ```
- **单次**：`curl -x http://127.0.0.1:7890 <url>`
- **Chrome / Playwright**：不用配置——Windows 系统代理被 Chromium 自动继承（见 §4）
- 注意：每条 Bash 命令是独立 shell，env 不持久；需要时在同一命令里 export + 使用

## 3. scrapling 的坑（重要）

scrapling 底层是 curl_cffi，代理行为与 curl.exe 不同：

1. **CLI 只支持文本**：`scrapling extract get` 输出只接受 `.md` / `.html` / `.txt` 扩展名，下二进制会报 `ValueError: Unknown file type`。**下载图片/文件必须用 Python API**：
   ```python
   from scrapling.fetchers import FetcherSession
   with FetcherSession(impersonate='chrome', proxy='http://127.0.0.1:7890', timeout=60) as s:
       page = s.get(url, headers={'Accept': 'image/png,image/*;q=0.8'})
       open('out.png', 'wb').write(page.body)   # page.body 是原始字节
   ```
2. **curl_cffi 不读环境变量 HTTPS_PROXY**：设了 env 也没用，必须给 session 显式传 `proxy=`。
3. **`Fetcher.get(url, proxy=...)` 会静默吞掉 proxy 参数**（日志显示 `Proxy 'None'`）——必须用 `FetcherSession(proxy=...)`。
4. **"Failed to connect ... over proxy ... after 0 ms"**：瞬时或主机特定故障。对策：重试一次；或改用目标服务的 API 拿直链（见下条）；en.wikipedia.org 通而 upload.wikimedia.org 断时，先取直链再请求。
5. **403 = 反爬**：加 `impersonate='chrome'`；下载图片时 Wikimedia 会按 Accept 头给 WebP（文件名还是 .png），强制 `Accept: image/png` 拿真 PNG。
6. **拿直链**（Wikimedia 系）：`action=query&prop=imageinfo&iiprop=url&iiurlwidth=1200` 返回 thumburl，直接请求直链比跟 Special:FilePath 重定向稳。

venv 位置：`~/.claude/skills/scrapling/.venv/Scripts/python.exe`（scrapling[all] 里自带 playwright）。

## 4. Playwright 截图导出（本机免下载浏览器）

```python
from playwright.sync_api import sync_playwright
browser = p.chromium.launch(channel='chrome')   # 用系统 Chrome，免 playwright install chromium
page = browser.new_page(device_scale_factor=2)  # 2x 清晰度
page.goto(f"file://{pathlib.Path(src).resolve()}")
page.wait_for_load_state("networkidle")         # 等 Google Fonts 等资源加载完
page.locator("svg").first.screenshot(path=out, omit_background=True)
```

## 5. 诊断顺序（默认流程）

1. 直连失败 → 2. `probe_proxy.sh` 确认代理在不在、哪个端口 → 3. 带上代理重试 → 4. 还不行检查**该工具自己的代理参数**（curl_cffi/requests 各自不同，别假设 env 生效）→ 5. 仍失败换直链或重试一次（瞬时故障不少见）→ 6. 用户说「开了 VPN」但探测不到端口时，让用户确认 VPN 客户端是「系统代理」还是「TUN」模式。
