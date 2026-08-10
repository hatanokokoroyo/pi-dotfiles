#!/usr/bin/env bash
# 同步 pi-dotfiles 仓库的非 package 文件到 ~/.pi/agent/
# 用法: ./sync.sh  （从 ~/pi-dotfiles 目录内执行）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.pi/agent"

for f in AGENTS.md settings.json; do
  cp "${SCRIPT_DIR}/agent/${f}" "${DEST}/${f}"
  echo "[OK] 已同步 agent/${f} -> ${DEST}/${f}"
done
