#!/usr/bin/env bash
# codegraph 查询辅助脚本（pi 项目级 skill）
# 功能：定位 codegraph 可执行文件、自动补全查询类命令的 -p 项目路径、检查索引存在性，然后原样调用 codegraph CLI。
# 用法：./codegraph.sh <子命令> [选项...]   （等价于 codegraph，查询类命令可省略 -p，默认取当前目录或最近的含 .codegraph 的祖先目录）
set -euo pipefail

# --- 定位 codegraph 可执行文件 ---
CG="${CODEGRAPH_BIN:-}"
if [ -z "$CG" ]; then
  CG="$(command -v codegraph 2>/dev/null || true)"
fi
if [ -z "$CG" ] || [ ! -x "$CG" ]; then
  CG="$HOME/.local/bin/codegraph"
fi
if [ ! -x "$CG" ]; then
  echo "[ERROR] 未找到 codegraph，请安装后重试（预期路径: ~/.local/bin/codegraph）" >&2
  exit 1
fi

CMD="${1:-}"
if [ -z "$CMD" ]; then
  echo "[ERROR] 缺少子命令：explore/query/node/files/callers/callees/impact/affected/init/index/sync/status/serve" >&2
  exit 1
fi
shift

# --- 解析参数，识别显式 -p/--path ---
PROJECT_PATH=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--path)
      if [ $# -ge 2 ]; then
        PROJECT_PATH="$2"; shift 2
      else
        echo "[ERROR] $1 缺少路径参数" >&2; exit 1
      fi
      ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# --- 从当前目录向上查找最近的含 .codegraph 的目录（用于默认项目路径） ---
resolve_project() {
  local d
  d="$(cd "${1:-$PWD}" 2>/dev/null && pwd || echo "$1")"
  while :; do
    if [ -d "$d/.codegraph" ]; then echo "$d"; return; fi
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  echo "$1"
}

# --- 查询类命令自动补全 -p（未显式指定时） ---
FLAG_PATH_CMDS="explore node query files callers callees impact affected serve"
case " $FLAG_PATH_CMDS " in
  *" $CMD "*)
    if [ -z "$PROJECT_PATH" ]; then
      PROJECT_PATH="$(resolve_project "$PWD")"
    fi
    if [ ! -d "$PROJECT_PATH/.codegraph" ]; then
      echo "[WARN] $PROJECT_PATH 下未发现 .codegraph 索引，查询可能无结果；请先执行: codegraph init $PROJECT_PATH" >&2
    fi
    ARGS=("-p" "$PROJECT_PATH" "${ARGS[@]}")
    ;;
esac

exec "$CG" "$CMD" "${ARGS[@]}"
