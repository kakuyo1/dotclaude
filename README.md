

## 新机器初始化

clone 后运行一次：

```sh
bash setup.sh
```

它只改**本仓库**的本地 git config，把 `core.hooksPath` 指向仓库内的 `.githooks/`，启用提交前的 gitleaks 密钥扫描。

`git clone` 不会带上 `core.hooksPath`，所以这一步必须手动做一次——**在那之前新克隆没有本地闸门**，由 GitHub Actions 兜底。

如果没装 gitleaks（免管理员权限）：

```sh
winget install --id Gitleaks.Gitleaks --exact --accept-package-agreements --accept-source-agreements
```

应急跳过本地闸门：`git commit --no-verify`。***CI 仍会扫全历史***。
