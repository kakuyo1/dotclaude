#!/usr/bin/env bash
# keepupwith-archibate 阶段 0：环境自检（gh 定位、代理探测、登录校验）。一次跑完，失败带修复指引。
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"   # gh 缺失/未登录时 exit 2/3 并给指引

echo "✓ gh: $GH"
echo "✓ 登录用户: $(gh api user --jq .login)"
echo "✓ 代理: ${https_proxy:-无（直连）}"
echo "环境就绪，可运行 fetch_changes.sh / fetch_file.sh"
