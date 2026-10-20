# win-gui：WSL2 操作 Windows GUI

> pi 版本：1.3.0 ｜ 状态：✅ 已落地 ｜ 最后核验：2026-10-20
> 源码：`extensions/wsl-win-gui.ts`（工具面）+ `scripts/win-gui/bridge.ps1`（Windows 侧执行层）

## 结论速览

| 问题 | 结论 |
| --- | --- |
| 做 skill 还是 MCP？ | **工具侧（extension tool）承担能力，skill 只承载知识**。纯 skill 拿不到坐标/状态，纯 MCP 多一层协议且要独立进程管理，pi 已有 `registerTool` 就没必要 |
| Windows 侧用什么技术栈 | **PowerShell 7 + .NET（UIAutomationClient / System.Drawing / P/Invoke）**。Windows 侧 Python 3.14 没装 PIL/uiautomation/comtypes，先装再跑得不偿失；PS 零安装零编译 |
| 进程模型 | **常驻 pwsh + stdio 行式 JSON**。冷启动 `-File` 每次 450~900ms，常驻后 7~130ms |
| 脚本放哪 | `pi-dotfiles/scripts/win-gui/bridge.ps1`，pi 侧通过 **UNC 路径**（`\\wsl.localhost\<distro>\...`）直接加载，**不需要往 Windows 侧拷贝** |
| 中文输入 | 默认**剪贴板 Ctrl+V**（自动还原用户剪贴板）。`SendKeys` 乱码；`SendInput UNICODE` 在新版 Notepad 会串字 |
| 截图能否不抢前台 | 能。`PrintWindow(hwnd, hdc, 2)`；空白时用像素多样性检测并自动回退"置前+CopyFromScreen" |

## 环境适配要点

### 多显示器（本机 3 屏实测）

```
#0 [主屏] 1920x1200 @(0,0)     DPI 120 (1.25x)
#1        2560x1440 @(4480,0)  DPI 120 (1.25x)
#2        2560x1440 @(1920,0)  DPI 120 (1.25x)
虚拟桌面 7040x1440
```

- 坐标一律**物理像素 + 带符号 int**，不要假设原点为 0 或单屏；屏序与 `DISPLAYn` 编号无关（`EnumDisplayMonitors` 顺序）。
- 扩展侧先让模型调 `win_env` 拿到布局（含每屏 DPI/缩放/工作区），再决定目标屏。
- `win_env` / `win_windows` 输出里带 `屏N`，跨屏窗口会显示其中心所在屏。
- 截图 `target=monitor` + `monitor=N` 可单屏抓取；返回 `origin` 用于换算全局坐标。

### DPI 必须最早设置

`SetProcessDpiAwarenessContext(-4)`（PER_MONITOR_AWARE_V2）要在**任何 UIA / Graphics 调用之前**执行，否则：
- `SystemInformation.VirtualScreen` 报 `7040x1440`（看着对，是 DPI 虚拟化后的）
- 但 `Screen.AllScreens[0].Bounds` 报 `1536x960`（逻辑像素）
- `GetWindowRect` 与实际物理像素不符

### 单显示器/无 WSL 环境

扩展在 `detectWsl()` 阶段检查 `WSL_DISTRO_NAME` + `/proc/sys/fs/binfmt_misc/WSLInterop`，不满足则全部工具报"当前不是 WSL2"。原生 Windows pi 用内置 `powershell` 工具即可，无需本扩展。

## 实现结构

```
extensions/wsl-win-gui.ts
  ├─ detectWsl()            pwsh 路径探测（优先 7，回退 5.1）+ UNC 前缀
  ├─ WinGuiBridge           spawn / JSON 行协议 / 请求超时 / 重连 / stderr 过滤
  ├─ /win-gui 命令          status | start | stop | monitors
  └─ 12 个工具              见下表
scripts/win-gui/bridge.ps1  Windows 常驻侧（纯 ASCII）
```

### 工具面

| 工具 | 用途 |
| --- | --- |
| `win_env` | 显示器布局 / DPI / 光标；`includeWindows` 附带窗口清单 |
| `win_windows` | 可见窗口（句柄/进程/标题/rect/屏号/前台） |
| `win_focus` | 置前 + 取消最小化 |
| `win_snapshot` | **定位首选**：UIA 元素树 → `uid`（比截图省 token） |
| `win_read` | ValuePattern / TextPattern 读文本（校验输入结果） |
| `win_screenshot` | 窗口/单屏/区域/全桌面截图，直接返回图片 |
| `win_click` | uid 点击 / 窗口相对坐标 / 全局坐标；`uia-invoke` 不动鼠标 |
| `win_type` | 中文/emoji/Unicode 输入（默认 paste） |
| `win_key` | `Ctrl+S` / `Alt+F4` / `F5` 等 |
| `win_drag` / `win_scroll` | 拖拽 / 滚轮 |
| `win_clipboard` | 读写剪贴板 |
| `win_wait` | 等元素出现（轮询） |

### 降级策略（写进工具语义，模型不必猜）

```
网页 → chrome-devtools (CDP)         首选，语义最准
原生窗口 / 网页不可达 → win_snapshot  次选，能拿到 uid 直接点
UIA 残废（canvas / 老控件）→ 截图 + 像素坐标点击
```

## 踩坑记录（都改进了，勿回退）

| 坑 | 现象 | 处理 |
| --- | --- | --- |
| PS 自动变量冲突 | 局部 `$matches` / `$Args` / `$Spec`（与局部 `$spec` 大小写冲突）导致"window-not-found" | 全部改名 `$hits` / `$Params` / `$WindowSpec` / `$filter` |
| `$Params.all` 当开关 | `-IncludeHidden:([bool]$Params.all)` 在 PS5 下 OK，注意别用 `$Args` | — |
| UIA 慢路径 | `TreeWalker` 逐节点 300ms+ | 改 `FindAll` 批量 + `CacheRequest`（91ms+84ms → 95ms+1ms） |
| `-Infinity` 尺寸 | 虚拟化元素 `BoundingRectangle` 为 -∞，`[int]` 转换抛异常 | `ConvertTo-SafeInt` / `ConvertTo-RectObject` 兜底 0 |
| `RuntimeId` 贵 | 每元素 ~0.3ms | 用 缓存属性指纹 生成 uid，不请求 RuntimeId |
| crop 错位 | PrintWindow 总是渲染整窗，按裁剪尺寸建 bitmap 只能取到左上角 | 先按 source rect 渲染，再对位图 `DrawImage` 裁剪 |
| 输入串字 | 新版 Notepad `abc def` → `abc fff` | 默认 paste；保留 `unicode` 作为可选 |
| 读回滞后 | 300 字符 +500ms 只读到 96 | `Wait-ElementTextLength` 轮询至期望长度 |
| `-File` 走 UNC | 冷启动慢（PS5 首次 JIT 可达 5s） | 常驻进程，只冷启动一次 |

## 验证过的真实场景

- 抓取 Pixso 画布（Chrome，后台窗口）→ UIA 命中"申请编辑"按钮 `911,118,98,41`，裁剪截图与位置精确对齐
- 单屏截图（3 屏各自 `target=monitor`）→ origin / scale 换算正确
- WinForms harness：真实鼠标点击按钮、`uia-invoke` 点击、粘贴中文、读回、滚动全部正确
- 新版 Notepad：粘贴 200 字中文 + emoji 精确、剪贴板自动还原

## 修改点速查

| 想改什么 | 改哪里 |
| --- | --- |
| 加新 op | `bridge.ps1` 的 `Invoke-Op` switch + 扩展 `pi.registerTool` |
| 加新工具 | `extensions/wsl-win-gui.ts` |
| 调输入默认方式 | `bridge.ps1` `'type'` 分支的 `$method` 默认值 |
| 调截图默认缩放 | `win_screenshot` 的 `maxDim`（默认 1600） |
| 换 PowerShell 路径 | `detectWsl()` 的 `pwsh7Paths` |

## 注意事项

- `uid` 只在**当前 bridge 进程内**有效（内存映射到 AutomationElement），进程重启后失效，需重新 snapshot。
- 桥脚本必须保持 **ASCII**：`bridge.ps1` 若写入中文字面量，PS 5.1 可能按 ANSI 解析而报错；中文只走 JSON 数据。
- 截图落在 `/tmp/pi-win-gui/`（`tmpdir()`），pi 用 `read` 可读；不长期保留。
- 首次调用会等 0.5~1s 冷启动；`session_start` 已做后台预热。失败后用 `/win-gui start` 看具体报错（stderr 会收集进 diagnostics）。
