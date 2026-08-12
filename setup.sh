#!/usr/bin/env bash
# 新终端安装 pi-dotfiles package（local path 方式，工作副本即包源）
# 用法:
#   git clone git@github.com:hatanokokoroyo/pi-dotfiles.git ~/.pi/pi-dotfiles
#   ~/.pi/pi-dotfiles/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

npm install --prefix "${SCRIPT_DIR}"
pi install "${SCRIPT_DIR}"

echo "[OK] pi-dotfiles 已安装（local:${SCRIPT_DIR}），/reload 或重启 pi 生效"
