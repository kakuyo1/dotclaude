#!/usr/bin/env bash
# Probe for a local proxy: Windows registry + listening ports + live connectivity.
# Usage: bash probe_proxy.sh [test URL]   (default https://en.wikipedia.org)
set -u
TARGET="${1:-https://en.wikipedia.org}"

echo "=== 1. Windows system proxy settings ==="
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" 2>/dev/null | grep -iE "ProxyEnable|ProxyServer" || echo "(no system proxy configured)"

echo "=== 2. Listening common proxy ports ==="
FOUND=$(netstat -an 2>/dev/null | grep LISTENING | grep -oE "127.0.0.1:(7890|7897|1080|10809|8888|8118|2080|9910)" | sort -u)
echo "${FOUND:-(no common port listening — VPN off, or not in local HTTP proxy mode)}"

echo "=== 3. Per-port connectivity (target: $TARGET) ==="
PORTS="$(echo "$FOUND" | grep -oE '[0-9]+$')"
[ -z "$PORTS" ] && PORTS="7890 7897 10809 1080 8118 8888"
for p in $PORTS; do
  CODE=$(timeout 4 curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$p" "$TARGET" 2>/dev/null)
  if [ "${CODE:-000}" != "000" ]; then
    echo "port $p -> HTTP $CODE  OK"
    echo "export https_proxy=http://127.0.0.1:$p http_proxy=http://127.0.0.1:$p"
    exit 0
  fi
  echo "port $p -> unreachable"
done
echo "=== No usable proxy port. If the user says a VPN is up, ask whether the client runs in system-proxy or TUN mode. ==="
exit 1
