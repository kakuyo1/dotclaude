#!/usr/bin/env bash
# keepupwith-archibate: 输出 archibate 某仓库指定文件在 HEAD 的完整内容（二进制安全）。
# usage: fetch_file.sh <repo: agent-skills|dotfiles-claude> <repo-relative-path>
# 调用方负责重定向：fetch_file.sh scrapling skills/scrapling/SKILL.md > 本地路径
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"   # 定位 gh + 代理分流 + 登录校验（失败 exit 2/3）

REPO="${1:?repo required: agent-skills|dotfiles-claude}"
P="${2:?path required}"

BRANCH="master"
[ "$REPO" = "dotfiles-claude" ] && BRANCH="main"

gh api "repos/archibate/$REPO/contents/$P?ref=$BRANCH" --jq '.content' | base64 -d
