---
name: chrome-devtools
description: 通过 CDP 协议驱动"本机可达"的 Chrome 实例（本地或经 ssh 隧道/内网穿透映射到 localhost 均可），做网页自动化与前端调试：导航/新开标签页、执行 JS、截图、列出页面。使用场景：验证部署的 Web 服务页面可用性、抓取页面标题/内容/链接、前端 bug 复现、截图存档。零依赖（Node >= 22 内置 fetch/WebSocket），等效于 chrome-devtools-mcp 的核心能力但工具更少、上下文占用更小。**选型注意**：抓取静态/SSR 页面文本时优先 curl+解析，本 skill 留给 SPA/交互/登录态/截图等场景（见注意事项"与 curl 的分层选型"）。
compatibility: Node >= 22；本机 localhost:<CDP_PORT>（默认 9222）可达一个带 --remote-debugging-port 的 Chrome 实例——可以是本机任意系统的 Chrome，也可以是远端 Chrome 经 ssh 反向隧道/内网穿透映射到本机端口
---

# Chrome DevTools（CDP 驱动本机可达的 Chrome）

## 概述

本 skill 通过 **CDP**（HTTP + WebSocket）驱动 Chrome 做网页自动化与前端调试。脚本只认一个事实：**本机 `localhost:<CDP_PORT>`（默认 9222）上存在可达的调试端点**。端点背后的 Chrome 实际运行在哪不重要：

- 本机任意系统的 Chrome（Windows / macOS / Linux 桌面）本地启动即可；
- 远端机器（如另一台电脑）上的 Chrome，经 **ssh 反向隧道**（`ssh -R`）、**内网穿透**或局域网直连，把其调试端口映射到本机 localhost；
- 本机是无桌面环境（Linux 服务器 / WSL2）时，同样适用——Chrome 可以在 Windows / mac 主机上。

**使用前先确认端点可达**：`curl http://localhost:9222/json/version` 返回 JSON 即可用；不可达时向用户汇报并询问处理方案（见"前置条件"），不要反复重试或自作主张。

本 skill 不依赖 chrome-devtools-mcp 服务本身（pi 无内置 MCP 支持），而是用 4 个零依赖 Node 脚本实现其核心能力：导航、执行 JS、截图、列页面。**不要**在本机尝试启动 chrome-devtools-mcp 或盲目拉起浏览器进程（无桌面环境会卡死）；一切浏览器操作走已可达的 CDP 端点。

## 前置条件

1. Node >= 22（内置 `fetch` 与 `WebSocket`）。
2. 本机存在可达的 CDP 端点：任意系统的 Chrome 以 `--remote-debugging-port=9222` 启动，或远端 Chrome 经隧道/穿透把 9222 映射到本机 localhost。**不关心 Chrome 是否真的是本机的**。
3. 验证连接：`curl http://localhost:9222/json/version` 能返回 JSON，或直接跑 `browser-pages`。

### 端点不可达时的处理

不要反复重试、不要自行猜测。向用户汇报以下事实，并给出可选项询问：

- 本地是否可启动带调试端口的 Chrome（macOS / Linux / Windows 桌面均可）；
- 是否可建立 ssh 隧道 / 内网穿透，把目标机器 Chrome 的 9222 映射到本机；
- 本任务是否根本不需要浏览器（静态/SSR 页面可直接 curl，见"与 curl 的分层选型"），可降级处理。

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

- **不要**在本机运行 chrome-devtools-mcp / 盲目启动浏览器进程（无桌面环境会卡死）；一切浏览器操作走已确认可达的 CDP 端点。
- 导航后脚本已等待 `document.readyState === 'complete'`，但单页应用（SPA）可能仍在渲染，必要时用 `browser-eval` 轮询目标元素。
- `chrome://` 内部页面（如新标签页）无法执行敏感 JS 操作，先导航到真实页面。
- `browser-eval` 的结果必须可 JSON 序列化（returnByValue）；DOM 元素需先转成文本/属性再返回。
- 截图保存到 `/tmp` 或 `--out` 指定路径，然后用 `read` 工具查看图片；**先确认当前模型支持读图**，不支持时截图无意义。
- 脚本会操作真实浏览器（真实登录态），测试产生的标签页记得用 `browser-pages` 确认并清理。
- 端口可达性由环境保证（本机直连 / ssh 隧道 / 内网穿透 / 端口转发），脚本只认 localhost 端点，不关心拓扑。

### 与 curl 的分层选型（经验复盘）

抓取网页信息时**先走最廉价手段，按需升级**，不要把浏览器重武器当默认：

| 任务特征 | 首选 | 说明 |
| --- | --- | --- |
| 静态/SSR 页面，只要文本/链接/元数据 | **bash curl + 本地解析** | 1 次请求 1 秒级完成、上下文占用小、零副作用；用 python/grep 精准提取 |
| 页面是 SPA 空壳（JS 渲染） | 本 skill | curl 拿不到内容 |
| 需要点击/填表/滚动加载/登录态 | 本 skill | curl 无法交互 |
| 需要截图做视觉验证 | 本 skill | 先确认模型支持读图 |
| 验证内网部署服务（dashboard 等）真实可用性 | 本 skill | 真实浏览器最可信 |

**探路流程**：先 `curl -s <url> | head -c 2000` 看是否空壳（1 秒成本）；是空壳或需要交互/截图再启用本 skill。经验教训：pi.dev 这类 SSR 页面 curl 一次即可拿全 README；误用 CDP 会多出 5+ 次工具调用、更多上下文，还会在真实浏览器开标签页。
