# Source baseline

- Native client: https://github.com/skyhua0224/moonlight-macos-enhanced
- Baseline: `c4dd84daa6440468f4e9a2e48f8c482f24bec965` (1.3.9 RC7).
- Upstream remote: `upstream`; development branch: `esp32/macos`.
- ESP32 protocol/state machines: `/mnt/e/project/Moonlight_Vplus_esp32`, commit `69aac9adfc3c54b6b5f2cf2d1ee317816c4210a4`.
- License: inherited GPLv3; upstream notices and acknowledgements retained.
- No origin/publication configured. Cloud builds require a repository under the user's account.

The imported RC7 Xcode target omitted explicit native source membership while listing those files as synchronized-folder exceptions. `scripts/prepare_macos_project.py` materializes the native source/resource list, including the main storyboard and Core Data model, for command-line builds. Native implementation code is retained.
