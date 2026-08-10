#!/usr/bin/env bash
# 同步 pi-dotfiles 仓库的非 package 文件到 ~/.pi/agent/
# 用法: ./sync.sh  （从 ~/pi-dotfiles 目录内执行）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.pi/agent"

# AGENTS.md 直接覆盖
cp "${SCRIPT_DIR}/agent/AGENTS.md" "${DEST}/AGENTS.md"
echo "[OK] 已同步 agent/AGENTS.md -> ${DEST}/AGENTS.md"

# settings.json 合并：仓库值优先（theme/defaultProvider 等），保留目标端已有字段
# （如 packages 列表，避免覆盖掉 pi install / pi update 写入的包引用）
if [ -f "${DEST}/settings.json" ]; then
  node -e '
    const fs = require("fs");
    const [repo, dest] = process.argv.slice(1);
    const a = JSON.parse(fs.readFileSync(repo, "utf8"));
    const b = JSON.parse(fs.readFileSync(dest, "utf8"));
    const merged = { ...b, ...a };
    fs.writeFileSync(dest, JSON.stringify(merged, null, 2) + "\n");
    console.log("[OK] 已合并 agent/settings.json -> " + dest + "（仓库值优先，保留 packages 等本地字段）");
  ' "${SCRIPT_DIR}/agent/settings.json" "${DEST}/settings.json"
else
  cp "${SCRIPT_DIR}/agent/settings.json" "${DEST}/settings.json"
  echo "[OK] 已同步 agent/settings.json -> ${DEST}/settings.json"
fi
