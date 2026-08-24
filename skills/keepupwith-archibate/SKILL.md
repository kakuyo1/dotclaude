---
name: keepupwith-archibate
description: 检查 archibate 的两个上游仓库（agent-skills、dotfiles-claude）最近 N 天的提交，把改动与本地 .claude 逐项比对，报告完整更新内容，并给出带编号的「建议同步」清单；用户选定后直接把所选文件同步到本地。
disable-model-invocation: true
user-invocable: true
---
# keepupwith-archibate

让本地 `.claude` 跟上 archibate 的两个上游仓库。本技能只做两件事：**报告**上游近 N 天改了什么、本地落后多少；以及在你**选定后**把选中项同步到本地。报告阶段只读，同步阶段只动你明确选择的那几项。

上游与本地的关系：本地 `.claude` 是 archibate 配置的**部分选装 + 本地定制**，两个 repo 的根都映射到本地 `.claude` 根。路径是一一对应的：

- `skills/<name>/...` → 本地 `skills/<name>/...`
- `hooks/<file>`、`CLAUDE.md`、`settings.json`、`statusline.sh` → 同名本地路径
- 其余（`installer/`、`tests/`、`.github/`、`README.md`、`LICENSE*`、`integration*`、`setup.sh`、`providers/`、`memory/`、`agents/`、`workflows/`、`bin/`、`breakdown.md`、`bypass.md`、`examples.md`）在报告里列出但默认标注「一般无需同步」——除非它们恰好在本地也有对应文件。

## 参数

- **DAYS**：窗口天数，默认 3。用户可说"最近 7 天 / 一周"。
- **REPO**：默认两个仓库都查；用户限定则只查一个（`agent-skills` 分支 `master`，`dotfiles-claude` 分支 `main`）。

## 本机环境与踩坑

- **gh 安装**：`winget install --id GitHub.cli -e`。装到 `C:\Program Files\GitHub CLI\`，但**当前 bash 会话的 PATH 看不到它**（Claude Code 子进程继承的是启动时的旧 PATH）——lib.sh 会自动定位（PATH → Program Files → LOCALAPPDATA），无需手工补 PATH。
- **gh 登录**：`gh auth login` 是交互式，需用户亲自跑。`github.com` 被墙，登录前先走代理（见下）；可直接跑 `! export https_proxy=http://127.0.0.1:7890; gh auth login`。
- **代理分流**：`github.com` 被墙 → 走 Clash 代理（`127.0.0.1:7890`）；`api.github.com` 可直连 → 设 `NO_PROXY=api.github.com`。lib.sh 自动探测常见代理端口并分流，fetch/compare 无需手工 export。
- **瞬时故障**：gh 授权流程里 token 交换可能中途 EOF——**浏览器授权"完成" ≠ 登录成功**。失败后用 `gh auth status` 验证，没存上就重跑登录，不要假设成功。
- **Windows CRLF 陷阱**：jq.exe 的 `-r` 输出是 `\r\n` 行尾，直接 `while read` 会让文件名带 `\r`、路径全错（曾导致所有文件误判「上游删除」）。凡是 `jq -r` 读出的值，用 `read -r F; F="${F%$'\r'}"` 剥掉 `\r`。`compare.sh` 已内置此处理；你自己手写 jq 循环时也要记得。

## 阶段 0：前置检查

先跑一次 `scripts/precheck.sh`（自动定位 gh、探测代理、校验登录，任一步失败会直接给修复指引）。它解析出的 gh 路径与代理配置由 fetch 脚本通过 `scripts/lib.sh` 自动复用，无需手工 export。

- gh 未装 → 提示 `winget install --id GitHub.cli -e` 安装后重跑。
- gh 未登录 → 提示 `gh auth login`。
- 网络失败 → 用 `vpn-proxy-troubleshooting` 技能排查代理，别把失败当「无更新」。

**本机路由实测**：`github.com` 被墙需走 Clash 代理（`127.0.0.1:7890`），`api.github.com` 可直连。lib.sh 自动分流——探测到代理端口就设 `https_proxy` 并把 `api.github.com` 加进 `NO_PROXY` 走直连。

## 阶段 1：采集上游变更（只读）

对每个目标 repo 运行：

```bash
bash "$HOME/.claude/skills/keepupwith-archibate/scripts/fetch_changes.sh" <repo> <days>
```

脚本自带 gh 定位/代理/登录校验，无需在命令里补 PATH 或 proxy。输出是 JSON（`commits[]` + `diff.files[]`，含每个文件的 status/additions/deletions/patch），或 `NO_COMMITS`。拿到后：

- `NO_COMMITS` → 该 repo 窗口内无提交，报告里一句带过。
- 否则把 `commits` 按时间倒序列进报告；把 `files` 作为后续比对的输入。

## 阶段 2：与本地比对（只读）

对每个目标 repo 运行 `scripts/compare.sh`（内部先 fetch_changes 再浅克隆上游 HEAD 到 `/tmp/up-<repo>` 批量比对，克隆已存在则复用，比逐文件 fetch_file 快一个量级）：

```bash
bash "$HOME/.claude/skills/keepupwith-archibate/scripts/compare.sh" <repo> <days>
```

输出每行 `状态|文件`，判定：

- **已同步**：本地内容 == 上游 HEAD。
- **落后**：本地存在但内容不同。
- **未采纳**：本地不存在（对你来说是"新增/可选采纳"）。
- **上游删除**：上游删了本地还留着的文件（`上游删除(本地也无)` 表示两边都没了，忽略）。

把 `skills/<name>/...` 下的文件**按技能名分组**（一个技能是一次同步单位），`hooks/` 按文件名分组，其余按文件本身分组。每组汇总：改了哪些文件（+N/-M）、关键 diff、本地状态。

**分组与 diff 的要点**：`diff.files[].patch` 是窗口内完整改动，直接提炼出最能说明问题的 hunk 作为「关键 diff」（文件大时截取核心几行，不要整段堆给用户）。commit message 也是摘要的重要来源。

## 阶段 3：报告（用户可见）

严格用下面的中文模板输出：

```
# archibate 更新报告（近 N 天）

## agent-skills (master)
- `sha` 日期 提交信息
...

### 技能: <name>
- `<path>` 修改/新增/删除 (+N/-M) — <一句摘要>
  关键 diff: `<最有用的一两段>`
  → 本地：落后 / 已同步 / 未采纳

### 配置: <file>
...

## dotfiles-claude (main)
...

## 建议同步清单
1. 更新 `<name>` 技能（本地落后 <n> 处）
2. 采纳 `<name>` 技能（本地缺失，可选）
3. 跳过 `installer/*`（无需）
...

回复编号即可，我会直接同步选中的项。
```

清单要点：**已同步的项不要进清单**；每项一句话说明理由；「建议跳过」也列出，让用户知道权衡。全部列完后，明确提示"回复编号，我会直接同步"，然后停下等用户选择。

## 阶段 4：用户选择 → 应用同步

只处理用户明确选中的编号，**绝不擅自动其他文件**。对每个选中项：

- 技能项：把该技能名下窗口内变更的所有文件，逐个用 `fetch_file.sh` 取上游 HEAD 内容并写回本地对应路径。
- 配置项：单文件同理。
- 上游删除：若本地有对应文件，删除前先问用户确认。

写回用 bash（这是外部数据抓取，Edit 无法胜任）。两种取源等价：`fetch_file.sh`（每次一个 API 调用，适合少量文件）或直接从阶段 2 的克隆 `cp -p`（快，适合整技能覆盖）；脚本文件 `cp` 后记得 `chmod +x` 保留可执行位。路径里的技能名注意别带 `\r`（见「本机环境与踩坑」）。

```bash
bash "$HOME/.claude/skills/keepupwith-archibate/scripts/fetch_file.sh" <repo> <path> > "$HOME/.claude/<本地路径>"
# 或用克隆：cp -p "/tmp/up-<repo>/<path>" "$HOME/.claude/<本地路径>"
```

同步完成后报告每个文件的写入结果。本地 `.claude` 是一个 git 仓库，改完会显示 modified——**提示用户可提交，但不要自动 commit**。若改动面大（如整技能覆盖），建议用户先看一眼 `git diff` 再提交。

## 边界

- 报告阶段永远只读，不产生任何本地改动。
- 本地定制过的文件（如本地 `settings.json`、`CLAUDE.md`）与上游不同是常态，报告如实标注「落后/已定制」即可，是否覆盖由用户决定——你无权自行覆盖。
- 网络失败先走 vpn-proxy 排查，别把失败当"无更新"。
