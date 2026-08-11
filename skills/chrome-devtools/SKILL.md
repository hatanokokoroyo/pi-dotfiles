---
name: chrome-devtools
description: 通过 CDP 协议直连 Windows Chrome（WSL2 镜像模式下 localhost:9222 互通），驱动浏览器做网页自动化与前端调试：导航/新开标签页、执行 JS、截图、列出页面。使用场景：验证部署的 Web 服务（RocketMQ dashboard、代码服务等）页面可用性、抓取页面标题/内容/链接、前端 bug 复现、截图存档。零依赖（Node >= 22 内置 fetch/WebSocket），等效于 chrome-devtools-mcp 的核心能力但工具更少、上下文占用更小。
compatibility: Node >= 22；WSL2 镜像模式（localhost 与 Windows 互通）；Windows Chrome 已通过任务栏快捷方式启动且带 --remote-debugging-port=9222
---

# Chrome DevTools（CDP 直连 Windows Chrome）

## 概述

本环境为 WSL2 Ubuntu 22（镜像模式），本机**没有 Linux 侧 Chrome**；Windows 侧任务栏固定快捷方式启动的 Chrome 带远程调试端口（9222），镜像模式下 `localhost` 双向互通，因此直接通过 **CDP**（HTTP + WebSocket）驱动 Windows Chrome。

本 skill 不依赖 chrome-devtools-mcp 服务本身（pi 无内置 MCP 支持），而是用 4 个零依赖 Node 脚本实现其核心能力：导航、执行 JS、截图、列页面。**不要**尝试在 WSL2 内启动 chrome-devtools-mcp（无 Chrome 会卡死）。

## 前置条件

1. Node >= 22（本机 v22.22.0，内置 `fetch` 与 `WebSocket`）。
2. Windows Chrome 已启动：任务栏固定快捷方式（含 `--remote-debugging-port=9222`）。
3. 验证连接：`curl http://localhost:9222/json/version` 能返回 JSON，或直接跑 `browser-pages`。

## 快速开始

以下命令在脚本目录下执行（本 skill 由 pi-dotfiles package 管理：安装路径 `~/.pi/agent/git/github.com/hatanokokoroyo/pi-dotfiles/skills/chrome-devtools/scripts`，工作副本 `~/pi-dotfiles/skills/chrome-devtools/scripts`）：

```bash
cd ~/.pi/agent/git/github.com/hatanokokoroyo/pi-dotfiles/skills/chrome-devtools/scripts

# 1. 确认连接与当前页面
node browser-pages.mjs

# 2. 导航（当前 tab）或新开标签页（--new）
node browser-nav.mjs "http://<服务器>:<端口>/"          # 当前 tab 导航
node browser-nav.mjs "http://<服务器>:<端口>/" --new    # 新开标签页

# 3. 执行 JS（读取/操作页面）
node browser-eval.mjs 'document.title'
node browser-eval.mjs 'document.querySelectorAll("a").length'

# 4. 截图（保存到文件，用 read 工具查看）
node browser-shot.mjs                       # 保存到 /tmp
node browser-shot.mjs --full                # 全页截图
node browser-shot.mjs --out /tmp/dash.png   # 指定路径
```

## 工具速查

| 脚本 | 功能 | 常用参数 |
| --- | --- | --- |
| `browser-pages.mjs` | 列出所有打开的页面（含 target id），验证连接 | 无 |
| `browser-nav.mjs <url>` | 导航当前 tab 或新开标签页，并等待加载完成 | `--new` 新开标签页 |
| `browser-eval.mjs '<js>'` | 在当前页面执行 JS（支持 async/await，结果按值返回） | `--target <id>` 指定页面 |
| `browser-shot.mjs` | 截图当前页面，输出文件路径 | `--full` 全页、`--out <path>`、`--target <id>` |

- 端口默认 `9222`，可用环境变量 `CDP_PORT` 覆盖。
- 公共封装在 `lib/cdp.mjs`（连接、target 选择、CDP 调用、状态持久化）。
- `browser-nav` / `browser-eval` / `browser-shot` 默认操作"上次操作过的页面"，无记录时取第一个非 chrome:// 页面；用 `browser-pages` 查 id 后以 `--target <id>` 指定。

## 典型工作流

### 1. 验证部署的 Web 服务页面（如 RocketMQ dashboard）

```bash
node browser-nav.mjs "http://localhost:8082/" --new   # 导航目标页面
node browser-eval.mjs 'document.title'                 # 标题（服务是否响应）
node browser-eval.mjs 'document.body.innerText.slice(0, 2000)'  # 正文内容
node browser-shot.mjs --out /tmp/dashboard.png         # 截图存档
```

### 2. 抓取页面信息

```bash
node browser-eval.mjs 'Array.from(document.querySelectorAll("a")).map(a => a.href).join("\n")'
node browser-eval.mjs 'document.querySelector("table")?.innerText'
```

### 3. 前端调试（console / 状态检查）

```bash
node browser-eval.mjs 'performance.getEntriesByType("navigation")[0]?.toJSON()'
node browser-eval.mjs 'document.readyState + " | " + document.visibilityState'
```

## 扩展指南（加新工具）

想加新能力（如点击、填表、读 console），按 `lib/cdp.mjs` 的封装模式写一个 `browser-xxx.mjs`：

```js
import { selectTarget, cdp, parseArgs } from './lib/cdp.mjs';
// 例如：点击页面上第一个匹配 CSS 选择器的元素
const { positional } = parseArgs(process.argv.slice(2));
const target = await selectTarget();
await cdp(target.webSocketDebuggerUrl, 'Runtime.evaluate', {
  expression: `document.querySelector(${JSON.stringify(positional[0])})?.click(); 'clicked'`,
  returnByValue: true,
});
```

CDP 方法与参数见 Chrome DevTools Protocol 文档（`Page.*`、`Runtime.*`、`DOM.*` 等）。

## 注意事项

- **不要**在 WSL2 内运行 chrome-devtools-mcp / 启动 Linux Chrome——本环境没有，且会卡死；一切浏览器操作走 CDP 连接 Windows Chrome。
- 导航后脚本已等待 `document.readyState === 'complete'`，但单页应用（SPA）可能仍在渲染，必要时用 `browser-eval` 轮询目标元素。
- `chrome://` 内部页面（如新标签页）无法执行敏感 JS 操作，先导航到真实页面。
- `browser-eval` 的结果必须可 JSON 序列化（returnByValue）；DOM 元素需先转成文本/属性再返回。
- 截图保存到 `/tmp` 或 `--out` 指定路径，然后用 `read` 工具查看图片。
- 脚本会操作 Windows Chrome（真实浏览器、真实登录态），测试产生的标签页记得用 `browser-pages` 确认并清理。
- 端口映射依赖 WSL2 镜像模式；若改为 NAT 模式需重新配置端口转发。
