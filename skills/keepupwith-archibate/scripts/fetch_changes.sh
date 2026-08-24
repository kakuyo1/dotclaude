#!/usr/bin/env bash
# keepupwith-archibate: 拉取 archibate 某仓库最近 N 天的提交与文件 diff（只读，不 clone）。
# usage: fetch_changes.sh <repo: agent-skills|dotfiles-claude> [days]
# output: JSON {repo, branch, window_days, commits[], diff{files[]}}；无提交时打印 NO_COMMITS
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"   # 定位 gh + 代理分流 + 登录校验（失败 exit 2/3）

REPO="${1:?repo required: agent-skills|dotfiles-claude}"
DAYS="${2:-3}"

BRANCH="master"
[ "$REPO" = "dotfiles-claude" ] && BRANCH="main"
API="repos/archibate/$REPO"

SINCE=$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

gh api "$API/commits?since=$SINCE&per_page=100" \
  --jq '[.[] | {sha: .sha, date: .commit.author.date, msg: (.commit.message | split("\n")[0])}]' \
  > "$TMP/commits.json"

if ! jq -e 'length > 0' "$TMP/commits.json" >/dev/null; then
  echo "NO_COMMITS"
  exit 0
fi

OLDEST=$(jq -r '.[-1].sha' "$TMP/commits.json")
# base = 窗口起点之前的那个提交；取不到就退回窗口内最早提交
BASE=$(gh api "$API/commits?until=$SINCE&per_page=1" --jq '.[0].sha' 2>/dev/null || echo "$OLDEST")

gh api "$API/compare/$BASE...$BRANCH" \
  --jq '{total_commits, files: [.files[] | {filename, status, additions, deletions, patch}]}' \
  > "$TMP/diff.json"

jq -n --slurpfile c "$TMP/commits.json" --slurpfile d "$TMP/diff.json" \
     --arg repo "$REPO" --arg branch "$BRANCH" --arg days "$DAYS" \
  '{repo: $repo, branch: $branch, window_days: $days, commits: $c[0], diff: $d[0]}' | tr -d '\r'
