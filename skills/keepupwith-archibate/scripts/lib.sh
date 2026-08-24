#!/usr/bin/env bash
# keepupwith-archibate 公共环境：定位 gh、探测代理、校验登录。被 fetch_*.sh / precheck.sh 源入。
# 约束：此文件被源入期间不得向 stdout 输出任何内容（调用方 stdout 是数据通道）。
# 踩坑记录（2026-08-24）：
#  - gh 经 winget 装到 Windows 后，当前 bash 会话 PATH 没有它 → 这里补常见安装路径。
#  - github.com 被墙走 Clash 代理（127.0.0.1:7890），api.github.com 可直连 → 分流设置。
set -euo pipefail

find_gh() {
  if command -v gh >/dev/null 2>&1; then
    echo "gh"
    return
  fi
  for d in "/c/Program Files/GitHub CLI" "$LOCALAPPDATA/Programs/GitHub CLI"; do
    if [ -x "$d/gh.exe" ]; then echo "$d/gh.exe"; return; fi
  done
  return 1
}

GH="$(find_gh || true)"
if [ -z "$GH" ]; then
  echo "[keepupwith] 错误：未找到 gh。安装：winget install --id GitHub.cli -e" >&2
  exit 2
fi
export GH
case "$GH" in
  */*) export PATH="$(dirname "$GH"):$PATH" ;;   # gh 不在 PATH 时补上，保证后续 `gh` 可解析
esac

# 探测本机代理，分流：github.com 被墙走代理、api.github.com 可直连
for p in 7890 7897 10809 1080 8118 8888; do
  if timeout 2 bash -c "echo >/dev/tcp/127.0.0.1/$p" >/dev/null 2>&1; then
    export https_proxy="http://127.0.0.1:$p"
    export http_proxy="http://127.0.0.1:$p"
    export NO_PROXY="api.github.com"
    break
  fi
done

if ! gh api user >/dev/null 2>&1; then
  echo "[keepupwith] 错误：gh 未登录。请运行：gh auth login（本机 github.com 被墙，先 export https_proxy=http://127.0.0.1:7890；api.github.com 可直连）" >&2
  exit 3
fi
