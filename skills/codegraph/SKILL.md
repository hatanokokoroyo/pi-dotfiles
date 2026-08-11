---
name: codegraph
description: 通过 codegraph（v1.5.0，本机已安装，另以 MCP 服务形式配置）查询代码图谱：符号定义与源码、调用者/被调用者、变更影响面、受影响的测试文件、项目文件结构。使用场景：理解代码库架构、定位函数/符号、编辑前评估影响、排查 bug、寻找相关测试。pi 不内置 MCP 支持，本 skill 以 CLI 方式调用与 MCP 工具（codegraph_explore/codegraph_node）输出等价的命令。
compatibility: codegraph CLI >= 1.5.0（预期路径 ~/.local/bin/codegraph）；目标项目需先执行 codegraph init 建立索引
---

# CodeGraph 代码图谱查询

## 概述

codegraph 是本机已安装的代码智能/知识图谱工具（二进制 `~/.local/bin/codegraph`，v1.5.0，另以 MCP 服务形式配置于 `~/.cache/reasonix/mcp/codegraph.json`）。它为项目建立符号索引（项目根目录 `.codegraph/`），可回答：某个符号在哪定义、源码是什么、谁调用它、它调用了谁、修改它会影响哪些代码、哪些测试文件受影响。

pi 不内置 MCP 支持，因此本 skill 通过 codegraph **CLI** 调用，与 MCP 工具输出等价：`codegraph explore` ≈ `codegraph_explore`，`codegraph node` ≈ `codegraph_node`。

## 前置条件

1. codegraph 已安装：`~/.local/bin/codegraph`（`codegraph --version` 应为 1.5.0）。
2. 目标项目已初始化索引（生成 `.codegraph/` 目录）：
   ```bash
   codegraph init /path/to/project
   ```

## 快速开始

```bash
# 1. 为项目建立索引（首次，之后代码变动用 sync 增量更新）
codegraph init /path/to/project

# 2. 查看索引状态（注意：status 用位置参数，无 -p）
codegraph status /path/to/project

# 3. 直接探索（推荐首选，等价 MCP 的 codegraph_explore）
codegraph explore -p /path/to/project "AuthService loginUser"
```

## 命令速查

| 命令 | 用途 | path 形式 |
| --- | --- | --- |
| `explore` | 【首选】相关符号源码 + 调用路径 + 影响面一次给出 | `-p <path>` |
| `node` | 单个符号源码 + caller/callee 轨迹；或按行读文件 | `-p <path>` |
| `query` | 符号搜索（`-k` 过滤类型，`-l` 限制条数，`-j` JSON） | `-p <path>` |
| `files` | 项目文件结构（tree/flat/grouped，`--filter`/`--max-depth`） | `-p <path>` |
| `callers` | 谁调用了某符号 | `-p <path>` |
| `callees` | 某符号调用了谁 | `-p <path>` |
| `impact` | 修改某符号影响哪些代码（`-d` 控制深度） | `-p <path>` |
| `affected` | 变更文件影响的测试文件（`--stdin` 从 stdin 读列表） | `-p <path>` |
| `init` | 初始化项目并建立索引 | 位置参数 |
| `index` | 全量重建索引 | 位置参数 |
| `sync` | 增量同步（代码变动后推荐先跑） | 位置参数 |
| `status` | 索引状态与统计 | 位置参数 |
| `serve` | 以 MCP server 模式运行（stdio，`--mcp`） | `-p <path>` |

也可用辅助脚本 `scripts/codegraph.sh` 调用：查询类命令可省略 `-p`（自动取当前目录或最近的含 `.codegraph` 的祖先目录），并会检查索引是否存在。例如：

```bash
bash scripts/codegraph.sh explore "AuthService loginUser"
bash scripts/codegraph.sh callers someFunction
```

## 推荐工作流

### 1. 理解代码 / 排查 bug（探索优先）

```bash
codegraph explore -p <项目> "功能关键词或符号名"
```

输出已包含相关符号源码、调用路径与影响面（blast radius），一次调用通常就够——**输出中展示的源码视为已读取，不要重复 read 同一文件**。

### 2. 编辑前评估影响

```bash
codegraph callers -p <项目> <符号>          # 谁调用了它
codegraph impact -p <项目> <符号>           # 改它会波及什么
codegraph affected -p <项目> <改动文件>      # 哪些测试文件受影响
```

### 3. 定位符号与阅读文件

```bash
codegraph query -p <项目> <关键词> -l 10       # 符号搜索
codegraph node -p <项目> <符号>                 # 符号详情 + 调用轨迹
codegraph node -p <项目> -f <文件> --offset 1 --limit 100   # 按行读文件
codegraph files -p <项目> --filter <子目录> --max-depth 3   # 文件结构
```

### 4. 索引维护

```bash
codegraph sync <项目>      # 代码变动后增量同步
codegraph status <项目>    # 健康检查；提示 interrupted run 时先跑 sync 修复
codegraph index <项目>     # 索引异常/过期时全量重建
```

## 注意事项

- pi 无内置 MCP：本 skill 全部走 CLI，不要尝试把 MCP 配置（`codegraph.json`）接入 pi。
- `status`/`init`/`index`/`sync` 的 path 是**位置参数**；其余命令用 `-p <path>`。
- `.codegraph/` 是索引产物，不应入库；若项目初始化 git，记得加入 `.gitignore`。
- 索引过期症状：查询缺结果或报错 → 先 `codegraph sync`，必要时 `codegraph index`。
- 尚未建索引的项目首次使用先执行 `codegraph init`；`exec/` 等嵌套 git 仓库会被一并覆盖索引，属预期。
- `codegraph install` 支持 Claude Code / Cursor / Codex / opencode / Hermes，**不支持 pi**——pi 环境请使用本 skill。
- 本机已索引目录示例：`~/project/DeepSeek-Reasonix`（1,034 文件）；`~/zsh_script`（索引为空，需 `index` 重建）。
