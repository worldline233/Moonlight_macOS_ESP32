#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -x .venv/bin/python3 ]]; then
  task_python=.venv/bin/python3
else
  task_python=python3
fi
if ! "$task_python" -c 'import esptool, serial' 2>/dev/null; then
  echo '首次使用请在此目录运行：'
  echo 'python3 -m venv .venv'
  echo '.venv/bin/python3 -m pip install "esptool>=5.6,<6"'
  read -r -p '按回车退出。'
  exit 1
fi
"$task_python" -B esp32-usb-update.py "$@"
read -r -p '按回车退出。'
