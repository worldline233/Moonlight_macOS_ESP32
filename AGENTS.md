# Development instructions

This is the native macOS ESP32 fork of skyhua0224/moonlight-macos-enhanced.
Preserve upstream CoreHID mouse movement and renderer paths when extending ESP32 keyboard/buttons.
Run `bash tests/esp32/run.sh` for routing tests; on macOS also compile/run the native bridge tests documented in docs/ESP32.md.
Native build and input latency need macOS validation; WSL tests alone do not establish either.

## 手机看图

以后生成的结果图和阅读 PDF，除保留项目原件外，统一复制到 `/home/worldline233/results/`：`latest/` 仅放最近一批结果，历史按 `history/YYYYMMDD-HHMMSS/` 保存，方便手机 SFTP 直接查看。
