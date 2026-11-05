# Moonlight macOS ESP32

基于 [Moonlight macOS Enhanced](https://github.com/skyhua0224/moonlight-macos-enhanced) 1.3.9 RC7 的独立 macOS 开发项目，为原生客户端加入 ESP32 USB 键盘和鼠标按钮接管。

- 保留上游 CoreHID 鼠标移动、滚轮、解码和渲染实现。
- 兼容现有协议 2 / NKRO16 固件，沿用 ESP32 的 USB 主机连接方式。
- 原生设置：选择具体主机配置 → 键盘与鼠标 → ESP32 USB 输入；保存后重新串流。
- 独立应用 `MoonlightESP32.app`，可与上游增强版和 Qt 版本并排安装。
- 详细使用、测试和验收：[docs/ESP32.md](docs/ESP32.md)。

当前状态：首版源码接入已完成，WSL 输入状态机、工程引用及设置搜索索引检查已通过。已提供 macOS 原生配置和 WebSocket 模拟联机测试；这些测试及完整 Xcode 构建尚未执行，真机 ESP32 联调和鼠标手感仍待验证。不能将源码检查视为构建成功。

本项目使用 Xcode 原生工程。GitHub Actions 提供手动触发的 Apple Silicon 构建；尚未配置本项目的 GitHub 发布仓库。开发包停用上游自动更新。

上游说明保存在 [README.upstream.md](README.upstream.md) 和 [README.en.md](README.en.md)，作者与依赖致谢见 [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md)。GPLv3 授权沿用 [LICENSE.txt](LICENSE.txt)。
