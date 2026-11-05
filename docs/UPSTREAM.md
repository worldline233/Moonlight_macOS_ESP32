# Source baseline

- Native client: https://github.com/skyhua0224/moonlight-macos-enhanced
- Baseline: `c4dd84daa6440468f4e9a2e48f8c482f24bec965` (1.3.9 RC7).
- Upstream remote: `upstream`; development branch: `main`.
- ESP32 protocol/state machines: `/mnt/e/project/Moonlight_Vplus_esp32`, commit `69aac9adfc3c54b6b5f2cf2d1ee317816c4210a4`.
- License: inherited GPLv3; upstream notices and acknowledgements retained.
- Development repository: https://github.com/worldline233/Moonlight_macOS_ESP32; `origin/main` is the published development branch.

The native Xcode target uses explicit source/resource membership, including the main storyboard and Core Data model. `scripts/prepare_macos_project.py` converts synchronized folders to ordinary groups as part of materialization, avoiding duplicate model-code-generation tasks. Native input and renderer implementations are retained.
