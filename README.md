我自己在用的 CLAUDE CODE 配置

## 新机器初始化

克隆后运行一次：

```sh
bash setup.sh
```

它只改**本仓库**的本地 git config，把 `core.hooksPath` 指向仓库内的 `.githooks/`，启用提交前的 gitleaks 密钥扫描（含「拒绝提交被 .gitignore 排除的文件」这道守卫，防 `git add -f`）。

`git clone` 不会带上 `core.hooksPath`，所以这一步必须手动做一次——**在那之前新克隆没有本地闸门**，由 GitHub Actions 兜底。

没装 gitleaks（免管理员权限）：

```sh
winget install --id Gitleaks.Gitleaks --exact --accept-package-agreements --accept-source-agreements
```

应急跳过本地闸门：`git commit --no-verify`。CI 仍会扫全历史，所以绕过不会真的漏过去。
