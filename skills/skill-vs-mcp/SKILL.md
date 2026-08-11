---
name: skill-vs-mcp
description: 用 skill + CLI 脚本替换 MCP 服务的元模式：判断何时替换、两种实现模式、最小工具集设计原则、SKILL.md 模板、实施与验证步骤。使用场景：pi 无内置 MCP 支持，遇到想给 pi 用的 MCP server（chrome-devtools-mcp、codegraph MCP 等）或想把某 MCP 能力本地化/瘦身时，先读本 skill 决定接 MCP 还是改造成 skill，并按其步骤落地。
compatibility: 不限；适用于任何能执行 Bash/代码的 agent（pi、Claude Code 等）
---

# 用 Skill 替换 MCP（skill-vs-mcp）

## 结论速览

- MCP server 通病：工具多、描述长、上下文贵（Playwright MCP 21 工具 13.7k tokens；Chrome DevTools MCP 26 工具 18k tokens ≈ 9% 上下文）；难扩展（要改源码）；不可组合（输出必须绕经 agent 上下文）。
- 替代方案：**极简 CLI 工具集 + SKILL.md**。SKILL.md 是渐进式披露文档（用时才读、不进系统提示，如 chrome-devtools 全套仅 337 行、速查表 225 tokens 量级），靠模型"本来就会写代码/用 Bash"的既有知识省上下文。
- 本机两个 skill（由 pi-dotfiles package 统一管理：工作副本 `~/pi-dotfiles/skills/`，安装后位于 `~/.pi/agent/git/github.com/hatanokokoroyo/pi-dotfiles/skills/`）是本文案的两个落地变体，作为参考样板：
  - `codegraph`：**模式 A（已有 CLI → 薄封装）**，`scripts/codegraph.sh` 自动找索引目录、省 `-p`。
  - `chrome-devtools`：**模式 B（无 CLI → 零依赖脚本）**，Node 22 内置 fetch/WebSocket 直连 CDP，`lib/cdp.mjs` 公共封装，4 个单职责脚本。
- 理论来源：<https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/>（"What if you don't need MCP at all?"）。

## 何时替换、何时保留（判断清单）

**适合替换为 skill 的 MCP**（同时满足多数）：
- 能力可用 CLI 命令或短脚本表达：查询、抓取、执行、截图、状态检查等"一问一答"式操作。
- 核心操作只有少数几个（3~6 个），全量工具大部分场景用不到。
- 输出体量适中、可纯文本/JSON 化；模型需要的就是"可读结果"，而非持续推送。
- 所在 agent 能执行 Bash/代码（pi、Claude Code 等）。

**不适合替换，保留 MCP/服务**：
- 需要常驻服务与多客户端共享状态：订阅推送、实时流式数据、长连接会话。
- 输出极大或持续流式，经 CLI/文件往返反而更贵。
- agent 环境无代码执行能力（纯聊天）。
- 已有成熟 CLI 缺失、重写成本高，且必须与 MCP 生态互操作。

## 两种实现模式

### 模式 A：已有 CLI → 薄封装（样板：codegraph）

1. 列出 MCP 工具对应的 CLI 命令（`codegraph explore` ≈ `codegraph_explore`）。
2. 辅助脚本只做**便利化**：自动找项目/索引目录、省高频参数、前置检查、统一输出，不做重复逻辑。
3. SKILL.md 里放一张 **MCP 工具 ≈ CLI 命令** 映射表，让 agent 一眼对上。

### 模式 B：无 CLI → 写零依赖脚本（样板：chrome-devtools）

1. 用运行时自带能力写：Node ≥ 22 内置 `fetch`/`WebSocket`（CDP、HTTP API 都够用）、Python 标准库等，**不引外部依赖**（省安装、省环境坑）。
2. 公共封装进 `scripts/lib/`（连接、target 选择、参数解析、输出格式化、状态持久化）；每个工具一个脚本，职责单一。
3. 工具名遵循"动词-对象"（`browser-nav`、`browser-eval`），支持 `--out`/`--target` 等少量稳定 flag。

## 实施步骤

1. **列用例 → 定最小工具集**：从真实使用场景出发，只保留核心操作；宁可少，后续按需加（文章案例就是从 4 个工具按需扩出 pick、cookies）。
2. **选模式**：有可用 CLI 走 A，没有走 B；评估 CLI 输出是否 token 高效，不高效则用辅助脚本格式化。
3. **写脚本**：单职责、位置参数为主、输出格式稳定（纯文本/JSON）、错误信息带 `[ERROR]` 前缀且可读、失败要给出排查线索。
4. **写 SKILL.md**（模板见下）：概述 → 前置条件 → 快速开始 → 命令速查表 → 推荐工作流 → 扩展指南 → 注意事项。
5. **验证**：逐工具在真实环境跑通；按"推荐工作流"完整走一遍；检查幂等与副作用（测试产生的文件/标签页可清理）。

## 工具集设计原则

- **上下文经济**：SKILL.md 只写必要信息，不重复模型已懂的知识（怎么写 JS、怎么用 Bash）；描述简洁，不堆长参数说明。
- **可组合**：输出可落盘（`--out`）、可管道、可链式——一条 Bash 命令串多个工具；结果可直接存文件供后续处理，不必全过上下文。
- **易扩展**：新工具 = 新脚本 + SKILL.md 加一节；扩展指南写进 skill（参照 chrome-devtools 的"扩展指南"节）。
- **输出可控**：某工具输出费 token 就改输出格式，成本极低（这是相对 MCP 的核心优势之一）。
- **渐进式披露**：SKILL.md 默认不被注入上下文，agent 需要时按 description 触发再读全文。

## SKILL.md 模板（骨架）

```markdown
---
name: <工具名>
description: <一句话能力 + 典型使用场景 + 关键前置条件，用于精准触发>
compatibility: <运行时/环境依赖，如 Node>=22、WSL2 镜像模式>
---

# <名称>（<一句话定位>）

## 概述        # 能做什么、与哪个 MCP 等价、实现方式（CLI/脚本）
## 前置条件    # 依赖检查命令、环境前提
## 快速开始    # 3~5 条最常用命令，可直接复制
## 命令速查    # 工具/命令表：用途 + 常用参数；MCP 等价物映射
## 推荐工作流  # 1~4 个典型场景的完整命令序列
## 扩展指南    # 如何加新工具（新脚本怎么写、公共封装在哪）
## 注意事项    # 环境坑、副作用、清理要求
```

## 验证清单

- [ ] 每个脚本通过语法检查（`bash -n` / `node --check`）。
- [ ] 每个工具在真实环境跑通，输出与速查表描述一致。
- [ ] 输出对 agent 友好：可 JSON 序列化 / 纯文本；DOM 等对象先转文本再返回。
- [ ] 异常路径有明确报错：无连接、无目标、超时、权限。
- [ ] 幂等/无副作用：重复执行不破坏数据；测试产物可清理或明确告知。

## 注意事项

- pi 无内置 MCP 支持：**不要**尝试把 MCP 配置接入 pi，一律走本模式（skill 内明确写出这一点，避免 agent 走弯路）。
- 环境依赖写进 `compatibility` 字段与前置条件节（如 WSL2 镜像模式、Chrome 调试端口、目标服务器可达性、代理要求）。
- 中国境内环境：脚本涉及境外地址时注明代理处理方式（见项目 AGENTS.md 网络章节）。
- 归属：本机全局 skill 统一由 pi-dotfiles package 管理（仓库 `skills/` 目录，push 后各终端 `pi update --extensions` 同步，遵循 pi-hacks 的登记流程）；项目相关的 skill 才放项目仓库 `.agents/skills/`。
