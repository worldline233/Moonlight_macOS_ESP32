# Moonlight macOS ESP32

基于 [Moonlight macOS Enhanced](https://github.com/skyhua0224/moonlight-macos-enhanced) 1.3.9 RC7 的独立 macOS 开发项目，为原生客户端加入 ESP32 USB 键盘和鼠标按钮接管。

- 保留上游 CoreHID 鼠标移动、滚轮、解码和渲染实现。
- 新增可设置按键的抢占宏：3–5 次、默认按住/松开各 2 ms，ESP 结束后恢复最新状态；附 Mac USB 升级工具。
- 兼容现有协议 2 / NKRO16 固件，沿用 ESP32 的 USB 主机连接方式。
- 原生设置：选择具体主机配置 → 键盘与鼠标 → ESP32 USB 输入；保存后重新串流。
- 顶部独立英文 ESP32 状态条，仅显示连接和输入状态，可单独开关。
- 独立应用 `MoonlightESP32.app`，可与上游增强版和 Qt 版本并排安装。
- GitHub 仓库创建、首次推送与云端构建：[docs/REPOSITORY.md](docs/REPOSITORY.md)。
- 详细使用、测试和验收：[docs/ESP32.md](docs/ESP32.md)。

当前状态：[Mac ARM64 云端构建已通过](https://github.com/worldline233/Moonlight_macOS_ESP32/actions/runs/42012464637)（源码 `baf381a`）。输入状态机、按钮队列生产代码回归、macOS 原生配置、WebSocket 模拟联机及连续退出重连测试，以及完整应用编译、开发签名校验和打包上传均通过。可在该次运行的 Artifacts 下载 `MoonlightESP32-macOS-arm64`，保留七天。ESP32 硬件联调和鼠标手感待真机验收。

本项目使用 Xcode 原生工程。GitHub Actions 提供手动触发的 Apple Silicon 构建；项目仓库为 [worldline233/Moonlight_macOS_ESP32](https://github.com/worldline233/Moonlight_macOS_ESP32)。开发包停用上游自动更新。

上游说明保存在 [README.upstream.md](README.upstream.md) 和 [README.en.md](README.en.md)，作者与依赖致谢见 [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md)。GPLv3 授权沿用 [LICENSE.txt](LICENSE.txt)。
