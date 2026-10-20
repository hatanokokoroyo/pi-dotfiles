# win-gui：WSL2 → Windows GUI 桥

pi 在 WSL2 里跑，但要读/点 Windows 侧的界面时用这套。

```
pi (WSL, 扩展 extensions/wsl-win-gui.ts)
   │  stdio 行式 JSON
   ▼
Windows 常驻 pwsh 7  ←  scripts/win-gui/bridge.ps1（经 UNC 路径直接加载，不复制）
```

## 为什么是常驻进程

| 方式 | 每次调用耗时 |
| --- | --- |
| `powershell.exe -File xxx.ps1`（冷启动） | 450 ~ 900 ms |
| 常驻 bridge，普通操作 | 7 ~ 130 ms |
| 常驻 bridge，UIA 全窗口枚举 | 100 ~ 390 ms |
| 常驻 bridge，窗口截屏 | 150 ~ 180 ms |

## 不变量（改代码前先读）

1. **DPI**：必须在任何 UIA / Graphics 调用前 `SetProcessDpiAwarenessContext(-4)`（PER_MONITOR_AWARE_V2）。否则 125% 缩放下 `SystemInformation.VirtualScreen` 报 `7040x1440` 而主屏报 `1536x960`（逻辑坐标），与实际物理像素不符。
2. **坐标系**：一律用物理像素、带符号 int。多屏可以是负坐标或大偏移。本机实测 3 屏：`0,0 1920x1200`（主，125%）｜`1920,0 2560x1440`｜`4480,0 2560x1440`，虚拟桌面 `7040x1440`。
3. **UIA rect == GetWindowRect 同一坐标系**，但 `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS=9)` 更贴近可见边框（少 9px 阴影），本脚本两者都返回（`rect` / `windowRect`）。
4. **PrintWindow(hwnd, hdc, 2)** 可以抓后台窗口，不用抢前台。个别 GPU 合成的窗口抓到纯色，需回退"置前 + CopyFromScreen"，脚本用像素多样性检测（采样 ≤3 色判为空白）自动回退。
5. **输入**：`SendKeys` 中文必乱码（实测出 GBK 串）。`SendInput KEYEVENTF_UNICODE` 在部分控件串字（新版 Notepad 把 `abc def` 输成 `abc fff`，chunk=1/32、逐字符 40ms 均可复现；WinForms TextBox 正常）。**默认走剪贴板 Ctrl+V**，并保存/还原用户原剪贴板。
6. **UIA 文本有滞后**：300 字符输入后 +500ms 只读到 96 字符，+2s 才完整。写后读必须轮询（`Wait-ElementTextLength`），不能固定 sleep。
7. **脚本必须 ASCII**：`bridge.ps1` 保持纯 ASCII，避免 PS 5.1/7 的编码差异；中文只走 JSON 数据，不写进脚本字面量。

## 协议

stdin 一行一请求，stdout 一行一响应：

```jsonc
{"id":1,"op":"snapshot","args":{"window":{"title":"Pixso"},"maxNodes":120}}
{"id":1,"op":"snapshot","ok":true,"result":{...}}
```

启动后先输出一帧 `{"ok":true,"event":"ready",...}`。

## op 一览

| op | 主要 args | 说明 |
| --- | --- | --- |
| `hello` | — | 版本 / DPI 感知 / 显示器布局 / 虚拟桌面 |
| `monitors` | — | 显示器布局 + 光标所在窗口 |
| `windows` | `title? process? all?` | 可见顶层窗口（hwnd/pid/进程/标题/rect/屏号/前台/最小化） |
| `focus` | `window` | 置前 + 取消最小化（AttachThreadInput 绕过前台锁） |
| `snapshot` | `window name? role? maxNodes? includeOffscreen? patterns?` | UIA 元素树，返回 `uid`（供后续 op 复用） |
| `element` | `uid` | 单个元素详情 |
| `read` | `uid? window? limit?` | ValuePattern / TextPattern 读文本 |
| `setValue` | `uid text` | UIA SetValue |
| `click` | `uid? \| x/y? \| window+rx/ry?` + `button count dx dy method` | 真实鼠标点击；`method=uia-invoke` 直接触发元素动作 |
| `type` | `text uid? window? method? replace? enter? keepClipboard?` | 默认 paste |
| `key` | `keys window? repeat?` | `Ctrl+S` / `Alt+F4` / `F5` |
| `drag` | `x1 y1 x2 y2 steps?` | 平滑拖拽 |
| `scroll` | `direction notches x? y?` | 滚轮 |
| `clipboard` | `set?` | 读写剪贴板 |
| `screenshot` | `target window? monitor? region? crop? maxDim? format? forceScreen?` | 窗口/单屏/区域/全桌面；`crop` 是全局坐标 |
| `wait` | `window name? role? timeout?` | 轮询等待元素出现 |
| `shutdown` | — | 退出 |

`window` 统一是 `{hwnd | title(正则) | process(正则) | pid}`，或直接给字符串（标题正则 / hwnd 字符串）。

## 截图坐标换算

返回里的 `origin` 是截图左上角的**屏幕物理坐标**，`scale` 是缩放比：

```
屏幕坐标 = origin + (图片像素坐标 / scale)
```

例：`origin=(871,78) scale=1` → 图内 (50,20) 对应屏幕 (921,98)。

## 手动调试

```bash
# 直接喂 JSON（Windows 侧脚本路径走 UNC 即可）
printf '%s\n' '{"id":1,"op":"hello","args":{}}' '{"id":2,"op":"shutdown","args":{}}' \
  | "/mnt/c/Program Files/PowerShell/7/pwsh.exe" -NoProfile -NonInteractive \
    -ExecutionPolicy Bypass -File "$(wslpath -w ~/.pi/pi-dotfiles/scripts/win-gui/bridge.ps1)"
```

pi 内用 `/win-gui status | start | stop | monitors` 管理进程。

## 工具暴露方式

13 个工具默认 `exposure: "codemode"`（不进常规 tool 列表，省 context），
且都声明了 `outputSchema`，codemode 脚本拿到 `structuredContent` 结构化字段：

```js
const { monitorCount, virtualScreen } = await tools.win_env({});
const shot = await tools.win_screenshot({ window: { title: "Pixso" } });
image(shot.image);
```

`PI_WIN_GUI_EXPOSURE` 可切到 `direct`（常规列表，调试用）/ `deferred`（仅 tool_search 可见）/ `model-only`。
