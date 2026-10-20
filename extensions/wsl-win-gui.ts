/**
 * WSL -> Windows GUI 控制扩展（win-gui）
 *
 * 让 pi（跑在 WSL2 Linux 里）读取并操作 Windows 侧的图形界面：枚举窗口、抓取
 * 元素树、截图、点击、输入中文、拖拽、滚动。适用于"Windows 上开着的浏览器 /
 * 设计稿 / 客户端，让 pi 截图并点一点"这类需求。
 *
 * 架构
 *   WSL (pi 扩展, 本文件)  ⇄  stdio 行式 JSON  ⇄  Windows (常驻 pwsh bridge)
 *   bridge 脚本由 pi-dotfiles 同步：scripts/win-gui/bridge.ps1，通过 UNC 路径
 *   （\\wsl.localhost\<distro>\...) 直接加载，**不需要拷贝到 Windows 侧**。
 *
 * 为什么常驻：单次 `powershell.exe -File` 冷启动 450~900 ms；常驻进程每次
 * 请求 7~130 ms（实测 UIA 全窗口枚举 100~350 ms，截屏 150~180 ms）。
 *
 * 关键实测结论（写进实现，勿凭直觉改）
 *  - 必须 SetProcessDpiAwarenessContext(-4)（PER_MONITOR_AWARE_V2）且在任何
 *    UIA / Graphics 调用**之前**执行，否则 150% 缩放下拿到的是 1536x960 这类
 *    逻辑坐标而不是 1920x1200 物理像素。
 *  - UIA BoundingRectangle 与 GetWindowRect 同一物理像素坐标系；多显示器用
 *    负坐标/大偏移（本机 3 屏：0,0 1920x1200 | 1920,0 2560x1440 | 4480,0
 *    2560x1440，虚拟桌面 7040x1440），因此坐标一律用带符号 int，禁止假设
 *    原点为 0 或单屏。
 *  - PrintWindow(hwnd, hdc, 2) 可在**不抢前台**的情况下抓到浏览器等后台窗口；
 *    个别窗口抓到空白，需回退到"置前 + CopyFromScreen"，用像素多样性检测。
 *  - SendKeys 中文乱码（实测得到 GBK 乱码串），必须走 SendInput 或剪贴板。
 *  - SendInput KEYEVENTF_UNICODE 在部分控件里会串字：新版 Notepad 把
 *    "abc def" 输成 "abc fff"（chunk 1/32、逐字符 40ms 间隔均可复现），而
 *    WinForms TextBox 完全正常。剪贴板 Ctrl+V 在上述两种控件里都精确。
 *    故 win_type 默认 method=paste，并自动保存/恢复用户原剪贴板。
 *  - UIA 文本读回有滞后（实测 300 字符输入后 +500ms 只读到 96 字符，+2s 才
 *    完整），输入后必须轮询等待而不是固定 sleep。
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, readFileSync, mkdirSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------- 路径与常量

/**
 * pi-dotfiles 根目录。扩展被 `pi install` 以 local path 方式加载时，
 * 本文件位于 <pkg>/extensions/，据此上溯一级即可，不依赖 cwd。
 */
const PACKAGE_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const BRIDGE_SCRIPT = join(PACKAGE_ROOT, "scripts", "win-gui", "bridge.ps1");

/** 截图落到 WSL 侧临时目录，模型用 read 读回即可（read 支持图片）。 */
const SHOT_DIR = join(tmpdir(), "pi-win-gui");

const REQUEST_TIMEOUT_MS = 60_000;
const BOOT_TIMEOUT_MS = 30_000;

// ------------------------------------------------------------------- WSL 环境

interface WslInfo {
  distro: string;
  /** 可直接用 bash 执行的 Windows PowerShell 7（或 5.1）绝对路径 */
  pwsh: string;
  /** pwsh 7 是否存在（否则用 powershell.exe，UIA 功能等价但慢一点） */
  pwsh7: boolean;
  /** 本 WSL 发行版在 Windows 侧的 UNC 前缀，例如 \\wsl.localhost\Ubuntu-22.04 */
  uncRoot: string;
}

function detectWsl(): WslInfo | undefined {
  const distro = process.env.WSL_DISTRO_NAME;
  if (!distro) return undefined;
  if (!existsSync("/proc/sys/fs/binfmt_misc/WSLInterop")) return undefined;

  const pwsh7Paths = [
    "/mnt/c/Program Files/PowerShell/7/pwsh.exe",
    "/mnt/c/Program Files/PowerShell/7-preview/pwsh.exe",
  ];
  const pwsh7 = pwsh7Paths.find((p) => existsSync(p));
  const pwsh = pwsh7 ?? "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";

  return {
    distro,
    pwsh,
    pwsh7: Boolean(pwsh7),
    uncRoot: `\\\\wsl.localhost\\${distro}`,
  };
}

function toWindowsUncPath(wslPath: string): string {
  // \\wsl.localhost\<distro>\home\user\...
  const normalized = wslPath.replace(/^\/+/, "").replace(/\//g, "\\");
  return `\\\\wsl.localhost\\${process.env.WSL_DISTRO_NAME}\\${normalized}`;
}

// ------------------------------------------------------------ bridge 进程管理

interface BridgeResponse {
  id?: number;
  op?: string;
  ok: boolean;
  result?: Record<string, unknown>;
  error?: string;
}

interface Pending {
  resolve: (value: Record<string, unknown>) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

class WinGuiBridge {
  private child: ChildProcessWithoutNullStreams | undefined;
  private pending = new Map<number, Pending>();
  private buffer = "";
  private nextId = 1;
  private ready: Promise<void> | undefined;
  private lastError = "";
  private stderrTail: string[] = [];

  constructor(private readonly wsl: WslInfo) {}

  get info(): WslInfo | undefined {
    return this.wsl;
  }

  get running(): boolean {
    return Boolean(this.child && !this.child.killed);
  }

  get diagnostics(): string {
    return this.lastError || this.stderrTail.join("\n");
  }

  /** 确保 bridge 进程存活；重复调用返回同一个启动 Promise。 */
  async ensureStarted(ctx?: ExtensionContext): Promise<void> {
    if (!this.wsl) throw new Error("not-running-in-wsl");
    if (!existsSync(BRIDGE_SCRIPT)) throw new Error(`bridge-script-missing: ${BRIDGE_SCRIPT}`);
    if (this.ready) {
      await this.ready;
      return;
    }
    this.ready = this.start(ctx);
    try {
      await this.ready;
    } catch (error) {
      this.ready = undefined;
      throw error;
    }
  }

  private async start(ctx?: ExtensionContext): Promise<void> {
    const scriptUnc = toWindowsUncPath(BRIDGE_SCRIPT);
    const args = [
      "-NoProfile",
      "-NoLogo",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scriptUnc,
    ];

    ctx?.ui.notify(`win-gui: 启动 Windows bridge（${this.wsl!.pwsh7 ? "pwsh 7" : "powershell 5.1"}）…`, "info");

    const child = spawn(this.wsl!.pwsh, args, {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    }) as ChildProcessWithoutNullStreams;
    this.child = child;

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      // pwsh 会往 stderr 写 CLIXML 进度/警告噪声，只保留最后若干行用于诊断。
      for (const line of chunk.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith("<Objs")) continue;
        if (trimmed.includes("CLIXML")) continue;
        this.stderrTail.push(trimmed);
        if (this.stderrTail.length > 30) this.stderrTail.shift();
      }
    });

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.onStdout(chunk));

    child.on("exit", (code) => {
      const pending = [...this.pending.values()];
      this.pending.clear();
      for (const entry of pending) {
        clearTimeout(entry.timer);
        entry.reject(new Error(`win-gui bridge exited (code ${code}): ${this.lastError || "unknown"}`));
      }
      this.child = undefined;
      this.ready = undefined;
      if (code !== 0 && code !== null) {
        this.lastError = `bridge exited with code ${code}`;
      }
    });

    child.on("error", (error) => {
      this.lastError = error.message;
    });

    // 等 ready 帧
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`win-gui bridge 启动超时（${BOOT_TIMEOUT_MS} ms）：${this.stderrTail.join(" | ")}`));
      }, BOOT_TIMEOUT_MS);
      const onReady = (response: BridgeResponse & { event?: string }) => {
        if (response.event === "ready") {
          clearTimeout(timer);
          cleanup();
          resolve();
        }
      };
      const onFail = () => {
        clearTimeout(timer);
        cleanup();
        reject(new Error(`win-gui bridge 启动失败：${this.stderrTail.join(" | ") || this.lastError}`));
      };
      const cleanup = () => {
        this.readyListeners.delete(onReady);
        this.failListeners.delete(onFail);
      };
      this.readyListeners.add(onReady);
      this.failListeners.add(onFail);
    });

    if (!this.wsl!.pwsh7 && ctx) {
      ctx.ui.notify("win-gui: 未检测到 PowerShell 7，回退 5.1（功能相同，稍慢）", "warning");
    }
  }

  private readyListeners = new Set<(response: BridgeResponse) => void>();
  private failListeners = new Set<() => void>();

  private onStdout(chunk: string): void {
    this.buffer += chunk;
    let index = this.buffer.indexOf("\n");
    while (index >= 0) {
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      index = this.buffer.indexOf("\n");
      if (!line) continue;

      let parsed: BridgeResponse & { event?: string };
      try {
        parsed = JSON.parse(line);
      } catch {
        this.stderrTail.push(`non-json stdout: ${line.slice(0, 200)}`);
        continue;
      }

      if (parsed.event === "ready") {
        for (const listener of this.readyListeners) listener(parsed);
        continue;
      }
      if (typeof parsed.id === "number" && this.pending.has(parsed.id)) {
        const entry = this.pending.get(parsed.id)!;
        this.pending.delete(parsed.id);
        clearTimeout(entry.timer);
        if (parsed.ok) {
          entry.resolve((parsed.result as Record<string, unknown>) ?? {});
        } else {
          entry.reject(new Error(parsed.error ?? "unknown-bridge-error"));
        }
      }
    }
  }

  async call(op: string, args: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    await this.ensureStarted();
    const child = this.child;
    if (!child) throw new Error("bridge-not-running");
    const id = this.nextId++;

    return new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`win-gui '${op}' 超时（${REQUEST_TIMEOUT_MS} ms）`));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
      try {
        child.stdin.write(`${JSON.stringify({ id, op, args })}\n`);
      } catch (error) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  async stop(): Promise<void> {
    if (!this.child) return;
    try {
      await this.call("shutdown");
    } catch {
      /* 已经退出则忽略 */
    }
    this.child?.kill();
    this.child = undefined;
    this.ready = undefined;
  }
}

// ---------------------------------------------------------------- 结果渲染

/** 把 bridge 的 screenshot 结果读回成 pi 的 image content block。 */
function readImageBlock(path: string):
  | { type: "image"; data: string; mimeType: string }
  | undefined {
  try {
    const buffer = readFileSync(path);
    const mimeType = path.toLowerCase().endsWith(".jpg") || path.toLowerCase().endsWith(".jpeg")
      ? "image/jpeg"
      : "image/png";
    return { type: "image", data: buffer.toString("base64"), mimeType };
  } catch {
    return undefined;
  }
}

function describeMonitor(monitors: Array<Record<string, unknown>>, index: unknown): string {
  if (typeof index !== "number" || index < 0) return "屏幕?";
  const monitor = monitors[index];
  if (!monitor) return `屏幕${index}`;
  return `屏幕${index}${monitor.primary ? "(主)" : ""} ${monitor.w}x${monitor.h}@${monitor.scale}x`;
}

// ------------------------------------------------------------------- 扩展主体

export default function wslWinGuiExtension(pi: ExtensionAPI) {
  const wsl = detectWsl();
  const bridge = new WinGuiBridge(wsl as WslInfo);

  const unavailableReason = !wsl
    ? "当前不是 WSL2（或 Windows 互操作未启用），win-gui 工具不可用。"
    : !existsSync(BRIDGE_SCRIPT)
      ? `未找到 bridge 脚本：${BRIDGE_SCRIPT}`
      : undefined;

  /**
   * 工具暴露方式。默认 direct（开箱即用）；设 PI_WIN_GUI_EXPOSURE=codemode 后
   * 只在 codemode / tool_search 里可见，不再占用每次请求的 tool 列表
   * （13 个工具的声明约 600 tokens）。
   */
  const exposure: "direct" | "codemode" | "model-only" =
    process.env.PI_WIN_GUI_EXPOSURE === "codemode"
      ? "codemode"
      : process.env.PI_WIN_GUI_EXPOSURE === "model-only"
        ? "model-only"
        : "direct";

  const namespace = {
    name: "win_gui",
    aliases: ["win-gui", "windows"],
    description: "WSL2 → Windows GUI：截图 / UIA 元素树 / 点击 / 中文输入 / 键鼠",
    instructions:
      "定位控件优先用 win_snapshot 拿 uid（比截图省 token），再用 win_click(uid) / win_type(uid)。" +
      "多显示器先 win_env 看布局，所有坐标都是物理像素、可为负。截图坐标换算：屏幕 = origin + 图片像素/scale。" +
      "输入中文必须用 win_type（默认剪贴板粘贴），SendKeys 会乱码。写后读要用 win_read 复核（UIA 文本有滞后）。",
  };

  /** 统一入口：检查环境 + 调 bridge + 把错误转成模型可读文本。 */
  const invoke = async (
    op: string,
    args: Record<string, unknown>,
  ): Promise<Record<string, unknown>> => {
    if (unavailableReason) throw new Error(unavailableReason);
    return bridge.call(op, args);
  };

  // ---- 会话生命周期：启动时预热（后台，不阻塞），结束时关闭 ----
  pi.on("session_start", async (_event, ctx) => {
    if (unavailableReason) return;
    // 预热：让第一次真实调用不必等 800ms 冷启动
    bridge.ensureStarted(ctx).catch(() => {
      /* 预热失败留给真实调用报错 */
    });
  });

  pi.on("session_shutdown", async () => {
    await bridge.stop();
  });

  pi.registerCommand("win-gui", {
    description: "Windows GUI 桥接：/win-gui status | start | stop | monitors",
    handler: async (args, ctx) => {
      const sub = args.trim().toLowerCase();
      if (unavailableReason) {
        ctx.ui.notify(unavailableReason, "error");
        return;
      }
      if (sub === "stop") {
        await bridge.stop();
        ctx.ui.notify("win-gui bridge 已停止", "info");
        return;
      }
      if (sub === "start") {
        try {
          await bridge.ensureStarted(ctx);
          const hello = await bridge.call("hello");
          ctx.ui.notify(
            `win-gui bridge 已就绪（${String(hello.psVersion)}，${String(hello.monitorCount)} 块屏幕）`,
            "info",
          );
        } catch (error) {
          ctx.ui.notify(`启动失败：${(error as Error).message}`, "error");
        }
        return;
      }
      if (sub === "monitors") {
        try {
          const result = await invoke("monitors", {});
          const monitors = (result.monitors as Array<Record<string, unknown>>) ?? [];
          const lines = monitors.map(
            (m) =>
              `#${m.index} ${m.primary ? "主屏 " : ""}${m.w}x${m.h} @${m.x},${m.y}  DPI ${m.dpiX}（${m.scale}x）${m.device}`,
          );
          ctx.ui.notify(lines.join("\n") || "未检测到显示器", "info");
        } catch (error) {
          ctx.ui.notify((error as Error).message, "error");
        }
        return;
      }
      // status（默认）
      const state = bridge.running ? "运行中" : "未启动";
      const detail = bridge.diagnostics ? `\n最近错误：${bridge.diagnostics}` : "";
      ctx.ui.notify(
        `win-gui bridge：${state}\nPowerShell：${wsl!.pwsh}${wsl!.pwsh7 ? " (7)" : " (5.1)"}\n脚本：${BRIDGE_SCRIPT}${detail}`,
        "info",
      );
    },
  });

  // ------------------------------------------------------------ tool: 环境信息

  pi.registerTool({
    name: "win_env",
    label: "Windows 环境概览",
    namespace,
    exposure,
    description:
      "获取 Windows 侧环境信息：显示器布局（数量/分辨率/DPI/缩放/虚拟桌面范围/每屏工作区）、当前光标位置与其所属窗口。多显示器场景下先用它确定目标在哪个屏幕和坐标系。",
    parameters: Type.Object({
      includeWindows: Type.Optional(
        Type.Boolean({ description: "同时返回可见窗口列表（默认 false）" }),
      ),
    }),
    async execute(_id, params) {
      const hello = await invoke("hello", {});
      const monitors = (hello.monitors as Array<Record<string, unknown>>) ?? [];
      const virtualScreen = hello.virtualScreen as Record<string, number>;
      const monitorLines = monitors.map(
        (m) =>
          `  #${m.index}${m.primary ? " [主屏]" : "      "} ${m.w}x${m.h}  原点(${m.x},${m.y})  DPI ${m.dpiX} (${m.scale}x)  ${m.device}\n` +
          `          工作区 ${(m.workArea as Record<string, number>).w}x${(m.workArea as Record<string, number>).h} @ (${(m.workArea as Record<string, number>).x},${(m.workArea as Record<string, number>).y})`,
      );

      const parts: string[] = [
        `PowerShell ${String(hello.psVersion)} (${String(hello.psEdition)})，DPI 感知：${String(hello.dpiAware)}`,
        `虚拟桌面：${virtualScreen.w}x${virtualScreen.h}，原点 (${virtualScreen.x},${virtualScreen.y})`,
        `显示器 ${String(hello.monitorCount)} 块（所有坐标均为物理像素，可为负值）：`,
        ...monitorLines,
      ];

      let windows: Array<Record<string, unknown>> | undefined;
      if (params.includeWindows) {
        const listing = await invoke("windows", {});
        windows = (listing.windows as Array<Record<string, unknown>>) ?? [];
        parts.push("", `可见窗口 ${windows.length} 个：`);
        for (const w of windows.slice(0, 40)) {
          const rect = w.rect as Record<string, number>;
          parts.push(
            `  ${w.hwnd}  ${String(w.process).padEnd(22).slice(0, 22)} 屏${w.monitor} ${rect.w}x${rect.h}@(${rect.x},${rect.y})${w.foreground ? " [前台]" : ""}  ${w.title}`,
          );
        }
        if (windows.length > 40) parts.push(`  …另有 ${windows.length - 40} 个未列出`);
      }

      return {
        content: [{ type: "text" as const, text: parts.join("\n") }],
        details: { hello, monitors, windows },
      };
    },
  });

  // ---------------------------------------------------------------- tool: 窗口

  pi.registerTool({
    name: "win_windows",
    label: "列出 Windows 窗口",
    namespace,
    exposure,
    description:
      "列出 Windows 可见顶层窗口（句柄、进程、标题、位置尺寸、所属屏幕、是否前台）。给 window 类工具定位目标。title 为正则匹配，process 为进程名正则。",
    parameters: Type.Object({
      title: Type.Optional(Type.String({ description: "标题正则（不区分大小写由 PowerShell -match 决定）" })),
      process: Type.Optional(Type.String({ description: "进程名正则，如 chrome、Code、WXWork" })),
      all: Type.Optional(Type.Boolean({ description: "包含无标题窗口（默认 false）" })),
      limit: Type.Optional(Type.Number({ description: "最多返回条数，默认 40" })),
    }),
    async execute(_id, params) {
      const args: Record<string, unknown> = {};
      if (params.title) args.title = params.title;
      // 进程过滤放到 bridge 侧做（正则 + 缓存进程名），省掉全量窗口的传输
      if (params.process) args.process = params.process;
      if (params.all) args.all = params.all;
      const listing = await invoke("windows", args);
      const windows = (listing.windows as Array<Record<string, unknown>>) ?? [];
      const limit = params.limit ?? 40;
      const shown = windows.slice(0, limit);

      const lines = shown.map((w) => {
        const rect = w.rect as Record<string, number>;
        return (
          `${w.hwnd}  ${String(w.process).padEnd(20).slice(0, 20)} 屏${w.monitor} ` +
          `${String(rect.w).padStart(4)}x${String(rect.h).padStart(4)}@(${rect.x},${rect.y})` +
          `${w.minimized ? " [最小化]" : ""}${w.foreground ? " [前台]" : ""}  ${w.title}`
        );
      });
      const text =
        shown.length > 0
          ? `${windows.length} 个窗口${windows.length > limit ? `（显示前 ${limit}）` : ""}：\n${lines.join("\n")}`
          : "没有匹配的窗口。";

      return {
        content: [{ type: "text" as const, text }],
        details: { windows: shown, total: windows.length },
      };
    },
  });

  pi.registerTool({
    name: "win_focus",
    label: "激活 Windows 窗口",
    namespace,
    exposure,
    description:
      "把 Windows 窗口切到前台并取消最小化。用于点击/输入前确保目标窗口在最前（点击类工具本身也会自动置前，一般无需单独调用）。返回是否成功抢到前台。",
    parameters: Type.Object({
      window: Type.Object({
        hwnd: Type.Optional(Type.String({ description: "窗口句柄（最精确）" })),
        title: Type.Optional(Type.String({ description: "标题正则" })),
        process: Type.Optional(Type.String({ description: "进程名正则" })),
      }),
    }),
    async execute(_id, params) {
      const result = await invoke("focus", { window: params.window });
      return {
        content: [
          {
            type: "text" as const,
            text: `${result.ok ? "已置前" : "置前失败（可能被系统前台锁定拒绝）"}：${String(result.title)}  hwnd=${String(result.hwnd)}`,
          },
        ],
        details: result,
      };
    },
  });

  // ------------------------------------------------------- tool: 元素树（快照）

  pi.registerTool({
    name: "win_snapshot",
    label: "Windows 元素快照",
    namespace,
    exposure,
    description:
      "读取窗口的 UIA 元素树，返回 {uid, role, name, rect, patterns} 列表。这是**定位控件的首选方式**：比截图省 token 且能直接点击。uid 可在 win_click / win_type / win_read 中复用（仅在当前 bridge 进程内有效）。多显示器下 rect 是全局物理像素坐标。",
    parameters: Type.Object({
      window: Type.Object({
        hwnd: Type.Optional(Type.String({ description: "窗口句柄" })),
        title: Type.Optional(Type.String({ description: "标题正则" })),
        process: Type.Optional(Type.String({ description: "进程名正则" })),
      }),
      name: Type.Optional(Type.String({ description: "按名称正则过滤（服务端过滤，省返回量）" })),
      role: Type.Optional(Type.String({ description: "按角色过滤，如 Button|Edit|Text|Hyperlink" })),
      maxNodes: Type.Optional(Type.Number({ description: "最多返回节点数，默认 120" })),
      includeOffscreen: Type.Optional(Type.Boolean({ description: "包含屏幕外/零尺寸元素（默认 false）" })),
      patterns: Type.Optional(Type.Boolean({ description: "附带每个元素支持的 UIA pattern（默认 true）" })),
    }),
    async execute(_id, params) {
      const snap = await invoke("snapshot", {
        window: params.window,
        name: params.name,
        role: params.role,
        maxNodes: params.maxNodes ?? 120,
        includeOffscreen: params.includeOffscreen ?? false,
        patterns: params.patterns ?? true,
      });
      const nodes = (snap.nodes as Array<Record<string, unknown>>) ?? [];
      const rect = snap.rect as Record<string, number>;

      const header = `${String(snap.title)}  hwnd=${String(snap.hwnd)}  ${rect.w}x${rect.h}@(${rect.x},${rect.y})  元素 ${String(snap.visited)} 个${snap.truncated ? "（已截断）" : ""}，返回 ${nodes.length}`;
      const lines = nodes.map((n) => {
        const r = n.rect as Record<string, number>;
        const patterns = Array.isArray(n.patterns) ? ` [${(n.patterns as string[]).join(",")}]` : "";
        const flags = `${n.enabled === false ? " disabled" : ""}${n.offscreen ? " offscreen" : ""}`;
        return `${n.uid} ${String(n.role).padEnd(13)} ${String(r.w).padStart(4)}x${String(r.h).padStart(4)}@(${String(r.x)},${String(r.y)})${patterns}${flags}  ${n.name}`;
      });

      return {
        content: [{ type: "text" as const, text: `${header}\n${lines.join("\n")}` }],
        details: snap,
      };
    },
  });

  pi.registerTool({
    name: "win_read",
    label: "读取 Windows 控件文本",
    namespace,
    exposure,
    description:
      "读取控件或窗口的文本内容（UIA ValuePattern / TextPattern）。用于校验输入结果、读取页面文字。注意 UIA 文本有滞后：刚输入完立刻读可能偏短，可稍等再读。",
    parameters: Type.Object({
      uid: Type.Optional(Type.String({ description: "元素 uid（来自 win_snapshot）" })),
      window: Type.Optional(
        Type.Object({
          hwnd: Type.Optional(Type.String()),
          title: Type.Optional(Type.String()),
          process: Type.Optional(Type.String()),
        }),
      ),
      limit: Type.Optional(Type.Number({ description: "最大字符数，默认 4000" })),
    }),
    async execute(_id, params) {
      if (!params.uid && !params.window) {
        throw new Error("需要 uid 或 window 之一");
      }
      const result = await invoke("read", {
        uid: params.uid,
        window: params.window,
        limit: params.limit ?? 4000,
      });
      const value = (result.value as string) ?? "";
      const text = (result.text as string) ?? "";
      const chosen = value || text;
      return {
        content: [
          {
            type: "text" as const,
            text: chosen
              ? `${value ? "ValuePattern" : "TextPattern"}（${chosen.length} 字符）：\n${chosen}`
              : "该控件不提供文本（无 ValuePattern / TextPattern）。",
          },
        ],
        details: result,
      };
    },
  });

  // ------------------------------------------------------------- tool: 截图

  pi.registerTool({
    name: "win_screenshot",
    label: "Windows 截图",
    namespace,
    exposure,
    description:
      "截取 Windows 窗口 / 单块显示器 / 任意区域 / 整个虚拟桌面，直接把图片返回给模型（同时保存到 WSL 临时目录）。默认用 PrintWindow 抓后台窗口，不需要把窗口切到前台；抓到空白会自动回退为置前 + 屏幕拷贝。多显示器：target=monitor 时用 monitor 指定第几块屏。",
    parameters: Type.Object({
      target: Type.Optional(
        Type.String({ description: "window（默认）| monitor | region | full" }),
      ),
      window: Type.Optional(
        Type.Object({
          hwnd: Type.Optional(Type.String()),
          title: Type.Optional(Type.String()),
          process: Type.Optional(Type.String()),
        }),
      ),
      monitor: Type.Optional(Type.Number({ description: "显示器序号（target=monitor），从 win_env 获取" })),
      region: Type.Optional(
        Type.Object(
          { x: Type.Number(), y: Type.Number(), w: Type.Number(), h: Type.Number() },
          { description: "截取区域（target=region），全局物理像素坐标" },
        ),
      ),
      crop: Type.Optional(
        Type.Object(
          { x: Type.Number(), y: Type.Number(), w: Type.Number(), h: Type.Number() },
          { description: "在目标窗口/屏幕范围内再裁剪一块（全局物理像素坐标）" },
        ),
      ),
      maxDim: Type.Optional(
        Type.Number({ description: "返回图片的最长边像素上限，默认 1600，0 表示不缩放" }),
      ),
      format: Type.Optional(Type.String({ description: "png（默认）| jpeg" })),
      forceScreen: Type.Optional(Type.Boolean({ description: "跳过 PrintWindow，直接屏幕拷贝" })),
    }),
    async execute(_id, params) {
      mkdirSync(SHOT_DIR, { recursive: true });
      const target = params.target ?? "window";
      const ext = params.format === "jpeg" ? "jpg" : "png";
      const outWsl = join(SHOT_DIR, `shot-${Date.now()}.${ext}`);

      const args: Record<string, unknown> = {
        target,
        out: toWindowsUncPath(outWsl),
        format: params.format ?? "png",
        maxDim: params.maxDim ?? 1600,
      };
      if (params.window) args.window = params.window;
      if (typeof params.monitor === "number") args.monitor = params.monitor;
      if (params.region) args.region = params.region;
      if (params.crop) args.crop = params.crop;
      if (params.forceScreen) args.forceScreen = true;

      const result = await invoke("screenshot", args);
      const savedPath = String(result.path ?? outWsl);
      // bridge 返回的是 UNC 路径；若写入成功，WSL 侧同一文件即可读
      const localPath = savedPath.startsWith("\\\\wsl.localhost\\")
        ? "/" + savedPath.replace(/^\\\\wsl\.localhost\\[^\\]+\\/, "").replace(/\\/g, "/")
        : outWsl;

      const image = readImageBlock(localPath);
      if (!image) throw new Error(`截图已生成但无法读取：${localPath}`);

      const origin = result.origin as Record<string, number>;
      const captureRect = result.captureRect as Record<string, number>;
      const scale = Number(result.scale ?? 1);
      const notes: string[] = [
        `${target} 截图 ${String(result.sourceWidth)}x${String(result.sourceHeight)} → 返回 ${String(result.width)}x${String(result.height)}（缩放 ${scale}）`,
        `方式：${String(result.method)}${result.blank ? "（⚠ 内容接近空白，可能需要 target=region 或 forceScreen）" : ""}${result.raisedWindow ? "（已置前以便屏幕拷贝）" : ""}`,
        `截图左上角在屏幕上的物理坐标：(${origin.x},${origin.y})`,
        `换算：屏幕坐标 = (${origin.x}, ${origin.y}) + 图片像素 / ${scale}`,
      ];
      if (result.warning) notes.push(`⚠ ${String(result.warning)}`);
      if (localPath !== savedPath) notes.push(`文件：${localPath}`);

      return {
        content: [
          { type: "text" as const, text: notes.join("\n") },
          image,
        ],
        details: { ...result, localPath },
      };
    },
  });

  // ------------------------------------------------------------- tool: 交互

  pi.registerTool({
    name: "win_click",
    label: "点击 Windows 控件",
    namespace,
    exposure,
    description:
      "点击 Windows 界面元素。优先传 uid（来自 win_snapshot，点击其中心）；也可传 window+rx/ry（窗口内相对坐标，适合 canvas/画布这类无元素的目标）或全局 x/y。会按需把目标窗口置前，并在点击后回报光标实际落点与所在窗口，便于校验点错没。",
    parameters: Type.Object({
      uid: Type.Optional(Type.String({ description: "元素 uid" })),
      window: Type.Optional(
        Type.Object({
          hwnd: Type.Optional(Type.String()),
          title: Type.Optional(Type.String()),
          process: Type.Optional(Type.String()),
        }),
      ),
      x: Type.Optional(Type.Number({ description: "全局物理像素 X" })),
      y: Type.Optional(Type.Number({ description: "全局物理像素 Y" })),
      rx: Type.Optional(Type.Number({ description: "窗口内相对 X（配 window 使用）" })),
      ry: Type.Optional(Type.Number({ description: "窗口内相对 Y（配 window 使用）" })),
      button: Type.Optional(Type.String({ description: "left（默认）| right | middle" })),
      count: Type.Optional(Type.Number({ description: "点击次数，2 即双击" })),
      dx: Type.Optional(Type.Number({ description: "相对偏移 X（微调）" })),
      dy: Type.Optional(Type.Number({ description: "相对偏移 Y（微调）" })),
      method: Type.Optional(
        Type.String({ description: "mouse（默认，真实鼠标）| uia-invoke（直接触发元素默认动作，不移动鼠标）" }),
      ),
    }),
    async execute(_id, params) {
      const args: Record<string, unknown> = {
        uid: params.uid,
        window: params.window,
        button: params.button ?? "left",
        count: params.count ?? 1,
      };
      if (typeof params.x === "number") args.x = params.x;
      if (typeof params.y === "number") args.y = params.y;
      if (typeof params.rx === "number") args.rx = params.rx;
      if (typeof params.ry === "number") args.ry = params.ry;
      if (typeof params.dx === "number") args.dx = params.dx;
      if (typeof params.dy === "number") args.dy = params.dy;
      if (params.method) args.method = params.method;

      const result = await invoke("click", args);
      const cursor = result.cursor as Record<string, unknown> | undefined;
      const text =
        result.method === "uia-invoke"
          ? `已通过 UIA InvokePattern 触发元素（未移动鼠标），坐标 (${result.x},${result.y})`
          : `已${Number(result.count) > 1 ? `连点 ${String(result.count)} 次` : "点击"} ${String(result.button)} @ (${result.x},${result.y})` +
            (cursor ? `，光标现在位于窗口「${String(cursor.title)}」(${String(cursor.x)},${String(cursor.y)})` : "");
      return {
        content: [{ type: "text" as const, text }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "win_type",
    label: "向 Windows 输入文本",
    namespace,
    exposure,
    description:
      "向 Windows 输入中文/emoji/任意 Unicode 文本。默认 paste：走剪贴板 Ctrl+V（实测在新版 Notepad、WinForms 输入框、浏览器里都精确，且长文本最快），会临时占用剪贴板并在结束后还原。method=unicode 用 SendInput UNICODE 注入（不发剪贴板，但实测新版 Notepad 会把 \"abc def\" 输成 \"abc fff\"，仅推荐用于已知可靠的控件）。method=value 用 UIA SetValue（仅标准输入框）。传 uid 会先点中心聚焦。中文用 SendKeys 会乱码，本工具已规避。",
    parameters: Type.Object({
      text: Type.String({ description: "要输入的文本" }),
      uid: Type.Optional(Type.String({ description: "目标输入控件 uid（会先点击聚焦）" })),
      window: Type.Optional(
        Type.Object({
          hwnd: Type.Optional(Type.String()),
          title: Type.Optional(Type.String()),
          process: Type.Optional(Type.String()),
        }),
      ),
      method: Type.Optional(
        Type.String({ description: "paste（默认）| unicode | value" }),
      ),
      keepClipboard: Type.Optional(
        Type.Boolean({ description: "保留粘贴后的剪贴板内容而不还原（默认还原用户原内容）" }),
      ),
      replace: Type.Optional(Type.Boolean({ description: "先全选（Ctrl+A）覆盖原内容，默认 false" })),
      enter: Type.Optional(Type.Boolean({ description: "输入后回车，默认 false" })),
    }),
    async execute(_id, params) {
      const result = await invoke("type", {
        text: params.text,
        uid: params.uid,
        window: params.window,
        method: params.method ?? "paste",
        keepClipboard: params.keepClipboard ?? false,
        replace: params.replace ?? false,
        enter: params.enter ?? false,
      });
      const notes = [`已输入 ${String(result.length)} 字符（方式 ${String(result.method)}）`];
      if (params.replace) notes.push("已先全选覆盖");
      if (typeof result.observedLength === "number" && result.observedLength !== result.length) {
        notes.push(`读回长度 ${String(result.observedLength)}（UIA 文本可能滞后，如需确认请再 win_read 一次）`);
      }
      if (result.warning) notes.push(`⚠ ${String(result.warning)}`);
      return {
        content: [{ type: "text" as const, text: notes.join("；") }],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "win_key",
    label: "发送 Windows 按键",
    namespace,
    exposure,
    description:
      '发送按键或组合键到前台窗口，如 "Ctrl+S"、"Enter"、"Alt+F4"、"F5"、"Ctrl+Shift+T"。可用 win_focus 或传 window 先置前。repeat 可连按。',
    parameters: Type.Object({
      keys: Type.String({ description: '组合键，用 + 连接，如 "Ctrl+A"' }),
      window: Type.Optional(
        Type.Object({
          hwnd: Type.Optional(Type.String()),
          title: Type.Optional(Type.String()),
          process: Type.Optional(Type.String()),
        }),
      ),
      repeat: Type.Optional(Type.Number({ description: "重复次数，默认 1" })),
    }),
    async execute(_id, params) {
      const result = await invoke("key", {
        keys: params.keys,
        window: params.window,
        repeat: params.repeat ?? 1,
      });
      return {
        content: [
          {
            type: "text" as const,
            text: `已发送 ${String(result.keys)}${Number(result.repeat) > 1 ? ` ×${String(result.repeat)}` : ""}`,
          },
        ],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "win_drag",
    label: "Windows 拖拽",
    namespace,
    exposure,
    description:
      "按住鼠标从一点拖到另一点（全局物理像素坐标），用于画布/滑块/排序等。自动平滑分步移动以避免拖拽失效。",
    parameters: Type.Object({
      x1: Type.Number({ description: "起点 X" }),
      y1: Type.Number({ description: "起点 Y" }),
      x2: Type.Number({ description: "终点 X" }),
      y2: Type.Number({ description: "终点 Y" }),
      steps: Type.Optional(Type.Number({ description: "插值步数，默认 18" })),
    }),
    async execute(_id, params) {
      const result = await invoke("drag", params as Record<string, unknown>);
      return {
        content: [
          {
            type: "text" as const,
            text: `已从 (${params.x1},${params.y1}) 拖到 (${params.x2},${params.y2})`,
          },
        ],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "win_scroll",
    label: "Windows 滚动",
    namespace,
    exposure,
    description:
      "在前台窗口/光标位置滚动滚轮。可先给 x/y 把光标移到目标处（如某个列表内部）再滚。",
    parameters: Type.Object({
      direction: Type.Optional(Type.String({ description: "up（默认 down）| down | left | right" })),
      notches: Type.Optional(Type.Number({ description: "滚动格数，默认 3（每格 120）" })),
      x: Type.Optional(Type.Number({ description: "滚动前把光标移到此处 X" })),
      y: Type.Optional(Type.Number({ description: "滚动前把光标移到此处 Y" })),
    }),
    async execute(_id, params) {
      const result = await invoke("scroll", {
        direction: params.direction ?? "down",
        notches: params.notches ?? 3,
        x: params.x,
        y: params.y,
      });
      return {
        content: [
          {
            type: "text" as const,
            text: `已向${String(result.direction)}滚动 ${String(result.notches)} 格`,
          },
        ],
        details: result,
      };
    },
  });

  pi.registerTool({
    name: "win_clipboard",
    label: "Windows 剪贴板",
    namespace,
    exposure,
    description:
      "读取或写入 Windows 剪贴板。读：get 当前文本（可配合 Ctrl+C 抓取选中内容）；写：set 文本（随后可 Ctrl+V 粘贴）。",
    parameters: Type.Object({
      get: Type.Optional(Type.Boolean({ description: "读取当前剪贴板（默认 true，除非指定了 set）" })),
      set: Type.Optional(Type.String({ description: "写入该文本" })),
    }),
    async execute(_id, params) {
      const result = await invoke("clipboard", { set: params.set });
      const text = String(result.text ?? "");
      const notes: string[] = [];
      if (params.set !== undefined) notes.push(`已写入 ${params.set.length} 字符`);
      notes.push(text ? `当前剪贴板（${text.length} 字符）：\n${text.slice(0, 4000)}` : "当前剪贴板为空");
      return {
        content: [{ type: "text" as const, text: notes.join("\n") }],
        details: { ...result, text: text.slice(0, 8000) },
      };
    },
  });

  pi.registerTool({
    name: "win_wait",
    label: "等待 Windows 界面出现",
    namespace,
    exposure,
    description:
      "轮询等待窗口中出现匹配的元素（按名称/角色正则），用于等页面加载、弹窗、loading 结束。返回匹配到的元素（含 uid 可直接点击）。",
    parameters: Type.Object({
      window: Type.Object({
        hwnd: Type.Optional(Type.String()),
        title: Type.Optional(Type.String()),
        process: Type.Optional(Type.String()),
      }),
      name: Type.Optional(Type.String({ description: "元素名称正则" })),
      role: Type.Optional(Type.String({ description: "元素角色过滤" })),
      timeout: Type.Optional(Type.Number({ description: "超时毫秒，默认 5000" })),
    }),
    async execute(_id, params) {
      const result = await invoke("wait", {
        window: params.window,
        name: params.name,
        role: params.role,
        timeout: params.timeout ?? 5000,
      });
      const nodes = (result.nodes as Array<Record<string, unknown>>) ?? [];
      if (!result.waited || nodes.length === 0) {
        return {
          content: [{ type: "text" as const, text: `等待超时（${params.timeout ?? 5000} ms）内未出现匹配元素` }],
          details: result,
        };
      }
      const lines = nodes.slice(0, 20).map((n) => {
        const rect = n.rect as Record<string, number>;
        return `${n.uid} ${String(n.role).padEnd(12)} ${rect.w}x${rect.h}@(${rect.x},${rect.y})  ${n.name}`;
      });
      return {
        content: [{ type: "text" as const, text: `已出现 ${nodes.length} 个匹配元素：\n${lines.join("\n")}` }],
        details: result,
      };
    },
  });
}
