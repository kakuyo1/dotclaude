#!/usr/bin/env bash
# 一键探测本机代理：Windows 注册表 + 监听端口 + 实际连通性验证
# 用法: bash probe_proxy.sh [测试目标URL]   (默认 https://en.wikipedia.org)
set -u
TARGET="${1:-https://en.wikipedia.org}"
echo "=== 1. Windows 系统代理设置 ==="
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" 2>/dev/null | grep -iE "ProxyEnable|ProxyServer" || echo "（未设置系统代理）"

echo "=== 2. 监听中的常见代理端口 ==="
FOUND=$(netstat -an 2>/dev/null | grep LISTENING | grep -oE "127.0.0.1:(7890|7897|1080|10809|8888|8118|2080|9910)" | sort -u)
echo "${FOUND:-（常见端口无监听——VPN 可能没开或不在本机 HTTP 代理模式）}"

echo "=== 3. 逐端口连通性验证 (target: $TARGET) ==="
PORTS="$(echo "$FOUND" | grep -oE '[0-9]+$')"
if [ -z "$PORTS" ]; then PORTS="7890 7897 10809 1080 8118 8888"; fi
for p in $PORTS; do
  CODE=$(timeout 4 curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$p" "$TARGET" 2>/dev/null)
  if [ "${CODE:-000}" != "000" ]; then
    echo "port $p -> HTTP $CODE  ✅ 可用"
    echo "export https_proxy=http://127.0.0.1:$p http_proxy=http://127.0.0.1:$p"
    exit 0
  fi
  echo "port $p -> 不通"
done
echo "=== 结论：没有可用代理端口；若用户声称开了 VPN，让其确认是系统代理模式还是 TUN 模式 ==="
exit 1
