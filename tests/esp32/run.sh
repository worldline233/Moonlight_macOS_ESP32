#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
task_build=$(mktemp -d "${TMPDIR:-/tmp}/moonlight-esp32-tests.XXXXXX")
trap 'rm -rf "$task_build"' EXIT
"${CXX:-c++}" -std=c++14 -Wall -Wextra -Werror -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$root/Limelight/Input/ESP32" "$root/tests/esp32/routing.cpp" \
  -o "$task_build/routing"
# LeakSanitizer cannot enumerate threads inside some WSL/ptrace sandboxes.
# These state tests use ASan/UBSan for bounds and lifetime checks.
ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}" "$task_build/routing"
