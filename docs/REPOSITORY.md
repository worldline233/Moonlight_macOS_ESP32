# 创建 GitHub 仓库与首次推送

本地目录：`E:\project\Moonlight_macOS_ESP32`（WSL：`/mnt/e/project/Moonlight_macOS_ESP32`）。本地已包含上游完整历史及 ESP32 开发提交。现有 `upstream` 指向原作者；尚未配置 `origin`。

## 1. 创建空仓库

登录自己的 GitHub 账号，打开：

https://github.com/new?name=Moonlight_macOS_ESP32&owner=worldline233

名称使用 `Moonlight_macOS_ESP32`，选择所需的公开或私有可见性。README、`.gitignore` 和 License 初始化选项均留空，本地已有这些文件。

如果使用其他账号或仓库名，替换下方 URL。

## 2. 首次推送

在 Windows PowerShell 执行：

```powershell
cd E:\project\Moonlight_macOS_ESP32
git branch -m main
git remote add origin https://github.com/worldline233/Moonlight_macOS_ESP32.git
git push -u origin main
```

这里把当前开发分支改名为 `main`，以便与新 GitHub 仓库默认分支一致。若当前分支已是 `main`，跳过改名；若 `origin` 已存在，先检查 `git remote -v`。

如果遇到之前的 GitHub 连接问题，并且本机代理仍监听 `127.0.0.1:7897`，把最后一行替换为：

```powershell
git -c http.proxy=http://127.0.0.1:7897 push -u origin main
```

认证由已有 Git Credential Manager 处理。无需把 GitHub 令牌写进源码、命令或仓库。

## 3. 手动构建 Mac arm64

首次推送后，确认 GitHub 默认分支是 `main`。进入仓库的 Actions → Build macOS ESP32 → Run workflow，选择 `main` 并启动。

工作流先运行路由、工程检查及 macOS 原生按钮队列与 WebSocket 测试，再构建 Apple Silicon 应用。构建成功后，在该次运行的 Artifacts 下载 `MoonlightESP32-macOS-arm64`。产物保留七天，工作流不自动发布 Release。

当前代码使用独立应用名称 `MoonlightESP32.app`，可与原增强版并排测试。原生编译、队列回归及硬件验收必须以实际运行结果为准。

## 参考

- [GitHub：创建仓库](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository)
- [GitHub：手动运行工作流](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
