#!/usr/bin/env bash
# keepupwith-archibate 阶段 2：把上游变更与本地 .claude 逐项比对（只读，不写本地）。
# usage: compare.sh <repo: agent-skills|dotfiles-claude> [days]
# 输出：每行一条 `状态|文件`，状态为 已同步/落后/未采纳/上游删除；无提交时输出 NO_COMMITS。
# 方法：浅克隆上游 HEAD 到 /tmp 一次性批量比对（比逐文件 fetch_file.sh 快一个量级），克隆已存在则复用。
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"   # 定位 gh + 代理分流 + 登录校验

REPO="${1:?repo required: agent-skills|dotfiles-claude}"
DAYS="${2:-3}"
LC="$HOME/.claude"

JSON="$("$DIR/fetch_changes.sh" "$REPO" "$DAYS")"
[ "$JSON" = "NO_COMMITS" ] && { echo "NO_COMMITS"; exit 0; }

CLONE="/tmp/up-$REPO"
if [ ! -d "$CLONE/.git" ]; then
  git clone --depth 1 -q "https://github.com/archibate/$REPO" "$CLONE"
fi

printf '%s\n' "$JSON" | jq -r '.diff.files[]?.filename' | while read -r F; do
  [ -z "$F" ] && continue
  F="${F%$'\r'}"          # Windows 下 jq.exe 的 -r 输出是 \r\n 行尾，剥掉 \r（否则路径全错）
  up="$CLONE/$F"
  if [ ! -f "$up" ]; then
    [ -f "$LC/$F" ] && echo "上游删除|$F" || echo "上游删除(本地也无)|$F"
    continue
  fi
  if [ ! -f "$LC/$F" ]; then echo "未采纳|$F"; continue; fi
  if cmp -s "$up" "$LC/$F"; then echo "已同步|$F"; else echo "落后|$F"; fi
done
