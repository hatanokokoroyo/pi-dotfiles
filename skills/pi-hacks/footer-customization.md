# pi footer 自定义（费用人民币/美元 + tok/s 输出速率）改造记录

> pi 版本: 0.84.1（2026-08 记录）
> 状态: 已落地，可继续演进

## 结论速览

- pi 的 footer 自定义入口是 `ctx.ui.setFooter()`，语义是**整体替换**（Replace the footer）——不是局部覆盖，默认 footer 的所有信息（工作目录/CH/context%/推理级别）都要自己渲染。
- 没有"货币单位"配置项；费用显示来自模型目录 `cost` 定价（每百万 token 美元价），footer 写死 `$` 渲染。**要换人民币只能整体复刻默认 footer + 改费用部分**。
- 默认 footer 的渲染源码在 `dist/modes/interactive/components/footer.js`，复刻它即可 1:1 对齐（含 k/M 数字格式、context 着色、对齐逻辑）。
- 扩展数据源经核实：`ExtensionContext` 几乎覆盖默认 footer 全部数据（cwd / getContextUsage / thinkingLevel / sessionManager.getEntries）；唯一拿不到的是 `autoCompactionEnabled`（(auto) 指示器），通过读 settings.json 的 `compaction.enabled` 推断（默认 true）。
- **tok/s 实时输出速率 + avg 平均速度 + 状态持久化**（v0.84.1 后续演进，2026-08）：基于 `message_update` 事件（流式逐 chunk 触发，payload 带 `assistantMessageEvent.delta`）统计流式内容，用 js-tiktoken 的 o200k_base（与 DeepSeek-V3 tokenizer 同族）换算近似 token；流式中 2s 滑动窗口显示瞬时 tok/s，回复结束后 3s 内显示 avg；`session_start` 自动应用（启动/会话切换/reload），`mode`+`tokEnabled` 持久化到 footer-state.json。**完全在扩展能力范围内，无需改 pi 内核**。

## 背景

用户使用 deepseek（API 按人民币计价），pi 默认 footer 以 `$` 显示费用，需要人民币显示。评估后放弃"MCP/改模型定价"等方案，选择扩展自定义 footer（pi 官方 Pattern 6）。

第一版做了"精简 footer"（只显示 ↑↓RW 和费用），对比发现丢失工作目录/CH/context%/推理级别等关键信息——**footer 自定义必须是完整复刻，否则信息损失不可接受**。

## 实现

### 扩展文件

`~/.pi/agent/extensions/footer-custom.ts`（全局，所有项目生效；也可放项目 `.pi/extensions/`）

- 命令 `/footer`：切换 人民币/美元/恢复默认 footer（`/footer cny|usd|off`），tok 速率开关（`/footer tok [on|off]`）
- 汇率：`PI_CNY_RATE` 环境变量覆盖，默认 7.15
- 默认模式：cny（人民币）

### tok/s 实时输出速率（新增）

在默认 footer 复刻基础上，AI 流式输出期间显示 `N tok/s`（位于 ↓output 之后）。

**实现**（`~/.pi/agent/extensions/footer-custom.ts`，`/footer tok on|off` 开关，默认开启）：

1. **事件源**：`pi.on("message_update")`（在扩展加载时注册一次，与 footer 模式无关）——流式过程中逐 chunk 触发，`event.assistantMessageEvent.delta` 携带 text/thinking/toolcall 的增量文本（text_delta / thinking_delta / toolcall_delta 均计入）。回复边界用 `message_start` / `message_end`（仅 assistant role）界定：开始记录起点，结束结算本次平均速率。
2. **token 换算**：优先 `js-tiktoken` 的 `o200k_base` BPE 编码（与 DeepSeek-V3 官方 tokenizer 同族、128k vocab，普通文本误差 <1%）；依赖缺失时回退字符估算 `chars/4`（`PI_TOK_CHARS_PER_TOKEN` 可覆盖）。增量编码逐 delta 独立计数累加，跨 chunk 边界合并误差对速率显示可忽略。
3. **速率计算**：维护 `(performance.now, 累计token)` 采样序列（保留 10s / 上限 200），render() 时按 2s 滑动窗口 `(Δtoken)/(Δt)` 计算，四舍五入取整显示。不足两个采样或速率 ≤0 时不显示；流停止后窗口自然过期（约 2s）消失，无需 agent_start/end 边界管理。
4. **avg 平均速度（变体）**：流式中显示瞬时 tok/s；`message_end` 结算本次回复 `(结束token-起始token)/(结束时间-起始时间)`，结束后立即切换为 `avg N tok/s` 展示 3s（TOK_AVG_TTL_MS）后消失；无 delta 的回复不显示；新回复 `message_start` 清除旧 avg。瞬时与 avg 无缝衔接不重叠。
5. **触发重绘**：`message_update` 时调 `tui.requestRender()`（TUI 合并+节流，安全）；流式期间 TUI 本身每 chunk 也重绘，此为双保险。`tui` 从 setFooter factory 参数存入模块级变量。
**依赖**：`~/.pi/agent/extensions/package.json` + `node_modules/js-tiktoken`（文档约定：扩展目录 `npm install` 后 import 自动解析）。

### 初始化与状态持久化（方案 B）

- **自动应用**：扩展订阅 `session_start` 事件（启动 / 会话切换 resume/fork/new / `/reload` 均触发），调用 `setMode(ctx, mode, { silent: true })` **静默**应用自定义 footer——无需手动执行命令（此前 `setMode` 只在命令 handler 里调用，导致启动/reload 后 footer 一直是 pi 默认美元）。
- **持久化**：`mode`（cny/usd/off）与 `tokEnabled` 存 `~/.pi/agent/footer-state.json`（`PI_FOOTER_STATE` 环境变量可覆盖路径，测试/自定义用）；扩展加载时读取、命令修改时写入。reload/重启后恢复上次设置（含 `/footer off` 状态）。
- **依据源码**：`agent-session.js` 1761 行确认 session_start 在扩展 runner 绑定之后 emit（扩展已加载、订阅已注册）；2072 行确认 `/reload` 也 emit `session_start(reason: "reload")`；`interactive-mode.js` 655 行注释确认 UI 先于扩展初始化，session_start handler 可用交互能力。

### 关键实现点

1. **复刻默认 footer**：渲染逻辑逐行移植自 `dist/modes/interactive/components/footer.js`（v0.84.1），数据源替换为扩展 ctx 对应 API。在此基础上叠加自定义要素：费用单位（`¥(cost×汇率)` / `$`）与 tok/s 速率。
2. **usage 累加范围**：必须用 `ctx.sessionManager.getEntries()` 遍历（含 toolResult / branch_summary / compaction 条目），与默认 footer 一致；`getBranch()` 只算当前分支消息，会漏数。
3. **CH（缓存命中率）**：取**最新一条** assistant 消息的 `cacheRead / (input + cacheRead + cacheWrite) × 100`。
4. **context 使用率**：`ctx.getContextUsage()` 返回 `{ tokens, contextWindow, percent }`；compaction 后 tokens 可能为 null（显示 `?`）。
5. **(auto) 指示器**：读 settings.json 的 `compaction.enabled`（项目 `.pi/settings.json` 优先，全局其次，默认 true）；扩展加载时读一次，改设置需 reload。
6. **数字格式**：移植内置 `formatTokens`（<1k 原样 / <10k 一位小数 k / <1M 取整 k / <10M 一位小数 M / 其余取整 M），保证 `R4.9M` 而非 `R4873k` 这类差异。
7. **dim 着色分段**：`theme.fg("dim", ...)` 不能包住带颜色的 context% 段（颜色 reset 会清掉外层的 dim），按默认逻辑分段处理。
8. **右侧模型名**：`ctx.model.id` + `ctx.thinkingLevel`（reasoning 模型显示 `• high` 等）；多 provider 时 footerData.getAvailableProviderCount() > 1 加 `(provider)` 前缀。

### 数据源对照表

| 默认 footer 信息 | 扩展数据源 |
| --- | --- |
| 工作目录（~缩写） | `ctx.cwd` + `formatCwdForFooter`（移植） |
| git 分支 | `footerData.getGitBranch()` |
| 会话名 | `ctx.sessionManager.getSessionName()` |
| ↑↓RW tokens | `ctx.sessionManager.getEntries()` 遍历累加 |
| CH 缓存命中率 | 最新 assistant 消息 usage 计算 |
| $费用 | `usage.cost.total` 累加（改为 ¥ = ×汇率） |
| context% / 窗口 | `ctx.getContextUsage()` + `ctx.model.contextWindow` |
| (auto) | 读 settings.json `compaction.enabled`（无直接 API） |
| 模型名 / 推理级别 | `ctx.model.id` / `ctx.thinkingLevel` |
| (provider) 前缀 | `footerData.getAvailableProviderCount()` |
| 扩展状态行 | `footerData.getExtensionStatuses()` |
| 重渲染触发 | `footerData.onBranchChange(() => tui.requestRender())` |
| tok/s 实时速率 | `pi.on("message_update")` 的 `assistantMessageEvent.delta` → js-tiktoken o200k_base → 2s 滑动窗口 |
| avg 本次平均速度 | `message_start`/`message_end`（assistant）界定回复，结束时结算 |
| 初始化/持久化 | `session_start` 自动应用；`mode`+`tokEnabled` 存 footer-state.json |

### 关键源码位置（排查/升级时用）

- 默认 footer 实现: `dist/modes/interactive/components/footer.js`（FooterComponent）
- footerData API: `dist/core/footer-data-provider.d.ts`
- ExtensionContext 定义: `dist/core/extensions/types.d.ts`（209 行起）
- setFooter 签名: `types.d.ts` 107 行（factory: (tui, theme, footerData) => Component & { dispose? }）
- theme API: `dist/modes/interactive/theme/theme.d.ts`（fg/bold 等）
- 扩展加载机制: pi 用 jiti 加载 TS 扩展

## 验证

用 jiti + mock 环境模拟完整 render（不启动真实会话）：

```bash
# 在 pi 安装目录执行（NODE_PATH 指向其 node_modules 以解析 @earendil-works/* 依赖）
cd <pi安装目录>/node_modules/@earendil-works/pi-coding-agent
NODE_PATH=$PWD/node_modules node -e "
const { createJiti } = require('jiti');
const jiti = createJiti(process.cwd() + '/', { interopDefault: true });
const mod = jiti('~/.pi/agent/extensions/footer-custom.ts');
// 构造 mockPi(mock registerCommand) → 触发 handler 拿到 setFooter 的 factory
// 构造 mock ctx (cwd/sessionManager/model/thinkingLevel/getContextUsage) + mock theme/footerData
// 调 factory() 拿 component，再 component.render(width) 断言输出
"
```

验证要点：两行结构（pwd 行 + 统计行）、k/M 格式、CH%、¥ 金额、context%/窗口、(auto)、模型名 • 推理级别、窄屏截断。

新增功能的验证方式（mock 事件流，均不启动真实会话）：

- **tok/s 瞬时**：mock `message_start` → 若干 `message_update`（text_delta 增量，间隔 ~120ms）→ render 断言 `/\d+ tok\/s/`；停止 2.2s 后断言消失。
- **avg**：`message_end` 后 render 断言 `/avg \d+ tok\/s/`；3.1s 后断言消失；无 delta 的空回复不显示；新 `message_start` 清除旧 avg。
- **状态持久化**（`PI_FOOTER_STATE` 指向临时文件，避免污染真实状态）：
  1. 无状态文件 → `session_start` 后默认 cny+tok on 自动应用（静默无 notify），状态文件自动创建；
  2. `/footer usd` + `/footer tok off` → 状态文件写入 `{mode:"usd",tokEnabled:false}`；
  3. 预写状态文件 → 重新加载（新进程避开 jiti 缓存）→ `session_start(reason:"reload")` 恢复上次设置。

## 常见自定义场景的修改点

| 想改什么 | 改哪里 |
| --- | --- |
| 费用单位/精度 | render() 里 costStr 一行（`¥(cost×RATE).toFixed(2)`） |
| 加/减统计项 | statsParts.push 处 |
| 换显示颜色 | `theme.fg("error"/"warning"/"dim", ...)` |
| 加自定义数据（如网络延迟） | 扩展里自行 fetch，render 里追加 |
| 改右侧模型显示 | rightSide 构建处 |
| 换触发命令名 | registerCommand 的 name |
| 改状态文件路径/内容 | STATE_FILE 常量（默认 ~/.pi/agent/footer-state.json） |
| 加 tok/s 速率显示 | statsParts.push 处（render 内 ↓output 后），tok 状态/采样/计算在扩展顶层 |

## 注意事项

- **pi 升级后检查**：`components/footer.js` 渲染逻辑若变，复刻版要同步；先 diff 新旧 footer.js 再决定。文档开头记录了版本号 0.84.1。
- setFooter(undefined) 可恢复默认 footer（`/footer off`）。
- 不要用 `getBranch()` 代替 `getEntries()` 统计费用（会漏数，与默认 footer 不一致）。
- 扩展是全局的，修改后 `/reload` 生效。
- **初始化时机**：自定义 footer 在 `session_start`（启动/会话切换/reload）时自动应用，无需手动命令；`setMode(ctx, mode, { silent: true })` 静默，不弹通知。
- **状态文件**：`~/.pi/agent/footer-state.json`（mode + tokEnabled）属用户偏好，无敏感信息、不入库；`PI_FOOTER_STATE` 可覆盖路径（测试/多机同步）。
- tok/s 为近似口径：依赖 js-tiktoken 的 o200k_base 近似 DeepSeek-V3 tokenizer（中文/混合内容与官方 usage 可能有少量偏差）；若需严格对齐 API 计费，可换官方 `tokenizer.json`（`@huggingface/tokenizers` WASM 加载，7.8MB 资产）。
- 本记录属于"pi 元改造"知识，新增同类改造（主题/快捷键/扩展开发）在 `skills/pi-hacks/SKILL.md` 索引中登记，详细文档放本目录。
