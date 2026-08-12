/**
 * Footer 自定义扩展 —— 完整复刻 pi 默认 footer，并叠加自定义展示要素
 * （费用单位人民币/美元、AI 输出速率 tok/s）
 *
 * pi 默认以美元（$）显示模型费用；本扩展通过 ctx.ui.setFooter() 完全复刻默认
 * FooterComponent 的渲染（工作目录 / git 分支 / 会话名 / ↑↓RW tokens / CH 缓存
 * 命中率 / context 使用率 / (auto) / 模型名 / 推理级别），并在此之上自定义：
 *  - 费用单位切换为人民币（¥，按汇率换算）
 *  - AI 流式输出实时速率 tok/s（输出中瞬时 + 结束后本次平均 avg）
 *
 * 用法（交互模式）:
 *   /footer          切换 人民币/美元
 *   /footer cny      固定人民币显示（默认）
 *   /footer usd      固定美元显示
 *   /footer off      恢复 pi 默认 footer
 *   /footer tok      切换 tok/s 实时输出速率显示（默认开启）
 *   /footer tok on|off  显式开启/关闭 tok/s
 *
 * tok/s 说明: 基于 message_update 事件里的流式 delta 文本（text/thinking/
 * toolcall 均计入），用 js-tiktoken 的 o200k_base（与 DeepSeek-V3 tokenizer
 * 同族）换算近似 token 数；流式中按 2s 滑动窗口显示实时 tok/s，回复结束
 * （assistant message_end）后 3s 内显示本次平均速度 avg N tok/s。依赖缺失
 * 时回退字符估算（PI_TOK_CHARS_PER_TOKEN 可覆盖系数，默认 4）。
 *
 * 汇率: 默认 7.15（美元→人民币），可用环境变量 PI_CNY_RATE 覆盖，
 *       例如 PI_CNY_RATE=7.2 pi
 *
 * 安装: 由 pi-dotfiles package 管理（local path 安装于 ~/.pi/pi-dotfiles/），
 *       全局生效；修改后 /reload 或重启 pi 生效
 *
 * 初始化: 扩展在 session_start 事件（启动 / 会话切换 / /reload 均触发）时
 *         自动应用自定义 footer，无需手动执行命令；模式与 tok 开关持久化到
 *         ~/.pi/agent/footer-state.json（可用 PI_FOOTER_STATE 覆盖路径），
 *         reload/重启后恢复上次设置。
 *
 * 说明: 渲染逻辑移植自 pi 内置 components/footer.js（v0.84.1），数据源替换为
 *       ExtensionContext 对应 API；唯一无法获取的 session.autoCompactionEnabled
 *       通过读取 settings.json 的 compaction.enabled 推断（默认 true）。
 */

import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

// ---------- tok/s 实时输出速率（AI 流式输出速度感知） ----------
//
// 数据源：pi 扩展事件 `message_update`（流式过程中逐 chunk 触发），其
// `assistantMessageEvent` 携带 text/thinking/toolcall 的 delta 增量文本。
// 将 delta 换算为近似 token 数（默认用 js-tiktoken 的 o200k_base BPE 编码，
// 与 DeepSeek-V3 官方 tokenizer 同族、128k vocab；依赖缺失时回退字符估算），
// 维护 (时间, 累计token) 采样序列，footer render() 时按滑动窗口计算速率。

type TokenEncoder = { encode(text: string): number[] };
let tokEncoder: TokenEncoder | undefined;
try {
	// @ts-ignore - jiti/CommonJS 环境下 require 可用；依赖缺失则回退字符估算
	const tiktoken = require("js-tiktoken");
	tokEncoder = tiktoken.getEncoding("o200k_base");
} catch {
	tokEncoder = undefined;
}

/** 字符估算系数（仅当 js-tiktoken 不可用时生效），可用 PI_TOK_CHARS_PER_TOKEN 覆盖 */
const TOK_CHARS_PER_TOKEN = (() => {
	const v = parseFloat(process.env.PI_TOK_CHARS_PER_TOKEN || "4");
	return isFinite(v) && v > 0 ? v : 4;
})();
const TOK_WINDOW_MS = 2000; // 速率滑动窗口（毫秒）
const TOK_AVG_TTL_MS = 3000; // 回复结束后 avg 速率展示时长（毫秒）
const TOK_SAMPLE_TTL_MS = 10000; // 采样保留时长
const TOK_SAMPLE_MAX = 200; // 采样上限

interface TokSample {
	t: number; // 采样时间（performance.now 毫秒）
	cum: number; // 累计 token 数
}

let tokCum = 0;
let tokSamples: TokSample[] = [];
let tokEnabled = true; // /footer tok on|off 控制，默认开启
let tokTuiRef: { requestRender: (force?: boolean) => void } | undefined;

// 本次回复（一次 assistant 流式）的边界与平均速率
let replyActive = false;
let replyStartCum = 0;
let replyStartT = 0;
let replyAvg: { rate: number; endT: number } | undefined;

/** 将流式 delta 文本换算为近似 token 数（增量编码，跨 chunk 边界合并误差对速率显示可忽略） */
function countTokens(text: string): number {
	if (!text) return 0;
	if (tokEncoder) {
		try {
			return tokEncoder.encode(text).length;
		} catch {
			/* 编码异常时回退字符估算 */
		}
	}
	return Math.max(1, Math.round(text.length / TOK_CHARS_PER_TOKEN));
}

/** 记录一段流式 delta，更新累计数与采样序列 */
function recordStreamDelta(delta: string): void {
	if (!tokEnabled || !delta) return;
	const n = countTokens(delta);
	if (n <= 0) return;
	tokCum += n;
	const now = performance.now();
	tokSamples.push({ t: now, cum: tokCum });
	// 裁剪：只保留最近 TTL 内的采样
	const cutoff = now - TOK_SAMPLE_TTL_MS;
	while (tokSamples.length > 2 && tokSamples[0].t < cutoff) tokSamples.shift();
	if (tokSamples.length > TOK_SAMPLE_MAX) tokSamples.splice(0, tokSamples.length - TOK_SAMPLE_MAX);
	// 请求重绘（TUI 合并+节流，安全）；流式期间 TUI 本身每 chunk 也重绘，这里是双保险
	tokTuiRef?.requestRender();
}

/** 计算滑动窗口内的 tok/s；不足两个采样或速率为 0 时返回 undefined */
function computeTokPerSec(now: number): number | undefined {
	if (tokSamples.length < 2) return undefined;
	const cutoff = now - TOK_WINDOW_MS;
	// 窗口左端点：取最后一个 t < cutoff 的采样（保证窗口内至少覆盖一个完整时段）
	let start = 0;
	while (start < tokSamples.length - 1 && tokSamples[start + 1].t < cutoff) start++;
	const a = tokSamples[start];
	const b = tokSamples[tokSamples.length - 1];
	const dtSec = (b.t - a.t) / 1000;
	if (dtSec <= 0) return undefined;
	const rate = (b.cum - a.cum) / dtSec;
	if (rate <= 0) return undefined;
	return rate;
}

/** 从 message_update 事件提取流式 delta 文本（text/thinking/toolcall 均计入） */
function extractStreamDelta(evt: any): string {
	return evt?.assistantMessageEvent?.delta ?? "";
}

// ---------- 以下辅助函数移植自 pi 内置 footer 组件 ----------

/** 紧凑 token 计数格式：<1k 原样，<10k 一位小数 k，<1M 取整 k，<10M 一位小数 M，其余取整 M */
function formatTokens(count: number): string {
	if (count < 1000) return count.toString();
	if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
	if (count < 1000000) return `${Math.round(count / 1000)}k`;
	if (count < 10000000) return `${(count / 1000000).toFixed(1)}M`;
	return `${Math.round(count / 1000000)}M`;
}

/** 工作目录显示：家目录缩写为 ~ */
function formatCwdForFooter(cwd: string, home: string | undefined): string {
	if (!home) return cwd;
	const resolvedCwd = resolve(cwd);
	const resolvedHome = resolve(home);
	const relativeToHome = relative(resolvedHome, resolvedCwd);
	const isInsideHome =
		relativeToHome === "" ||
		(relativeToHome !== ".." && !relativeToHome.startsWith(`..${sep}`) && !isAbsolute(relativeToHome));
	if (!isInsideHome) return cwd;
	return relativeToHome === "" ? "~" : `~${sep}${relativeToHome}`;
}

/** 清理扩展状态文本中的控制字符 */
function sanitizeStatusText(text: string): string {
	return text.replace(/[\r\n\t]/g, " ").replace(/ +/g, " ").trim();
}

interface UsageTotals {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
}

function createTotals(): UsageTotals {
	return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
}

function addUsage(totals: UsageTotals, usage: any): void {
	totals.input += usage?.input ?? 0;
	totals.output += usage?.output ?? 0;
	totals.cacheRead += usage?.cacheRead ?? 0;
	totals.cacheWrite += usage?.cacheWrite ?? 0;
	totals.cost += usage?.cost?.total ?? 0;
}

/** 读取 compaction.enabled（项目 .pi/settings.json 优先，其次全局，默认 true） */
function readCompactionEnabled(cwd: string): boolean {
	for (const file of [join(cwd, ".pi", "settings.json"), join(homedir(), ".pi", "agent", "settings.json")]) {
		try {
			const s = JSON.parse(readFileSync(file, "utf8"));
			if (s.compaction?.enabled !== undefined) return !!s.compaction.enabled;
		} catch {
			/* 文件不存在或解析失败，继续下一个 */
		}
	}
	return true;
}

// ---------- 扩展主体 ----------

export default function (pi: ExtensionAPI) {
	// tok/s 实时速率：订阅流式增量（扩展加载时注册一次，与 footer 模式无关）
	pi.on("message_update", (evt: any) => {
		const delta = extractStreamDelta(evt);
		if (delta) recordStreamDelta(delta);
	});
	// 回复边界：assistant 消息开始 → 记录起点；结束 → 结算本次平均速率
	pi.on("message_start", (evt: any) => {
		if (evt?.message?.role === "assistant") {
			replyActive = true;
			replyStartCum = tokCum;
			replyStartT = performance.now();
			replyAvg = undefined;
		}
	});
	pi.on("message_end", (evt: any) => {
		if (evt?.message?.role === "assistant" && replyActive) {
			const now = performance.now();
			const tokens = tokCum - replyStartCum;
			const durSec = (now - replyStartT) / 1000;
			replyActive = false;
			if (tokens > 0 && durSec > 0) {
				replyAvg = { rate: tokens / durSec, endT: now };
				tokTuiRef?.requestRender();
			} else {
				replyAvg = undefined;
			}
		}
	});

	// 美元 → 人民币汇率
	const USD_TO_CNY = parseFloat(process.env.PI_CNY_RATE || "7.15");
	const RATE = isFinite(USD_TO_CNY) && USD_TO_CNY > 0 ? USD_TO_CNY : 7.15;
	if (RATE !== USD_TO_CNY) {
		console.warn("[footer-custom] PI_CNY_RATE 非法，已回退默认 7.15");
	}

	type Mode = "cny" | "usd" | "off";
	let mode: Mode = "cny";

	// ---- 状态持久化：mode + tokEnabled 跨 reload/重启保持 ----
	// 默认存 ~/.pi/agent/footer-state.json，可用 PI_FOOTER_STATE 覆盖（测试/自定义）
	const STATE_FILE = process.env.PI_FOOTER_STATE || join(homedir(), ".pi", "agent", "footer-state.json");

	function loadState() {
		try {
			const s = JSON.parse(readFileSync(STATE_FILE, "utf8"));
			mode = s.mode === "usd" || s.mode === "off" ? s.mode : "cny";
			tokEnabled = typeof s.tokEnabled === "boolean" ? s.tokEnabled : true;
		} catch {
			/* 无状态文件或解析失败：保持默认（cny + tok on） */
		}
	}
	function saveState() {
		try {
			writeFileSync(STATE_FILE, JSON.stringify({ mode, tokEnabled }, null, 2) + "\n");
		} catch (e) {
			console.warn("[footer-custom] 状态保存失败:", e);
		}
	}
	loadState(); // 应用持久化设置

	function setMode(ctx: any, m: Mode, opts?: { silent?: boolean }) {
		mode = m;
		saveState();

		if (m === "off") {
			ctx.ui.setFooter(undefined); // 恢复内置默认 footer
			if (!opts?.silent) ctx.ui.notify("已恢复 pi 默认 footer（美元显示）", "info");
			return;
		}

		// 启动时读取一次 auto-compaction 状态（改设置需 reload 生效，与扩展一致）
		const autoCompact = readCompactionEnabled(ctx.cwd);

		ctx.ui.setFooter((_tui, theme, footerData) => {
			tokTuiRef = _tui; // 供流式增量触发重绘
			const unsub = footerData.onBranchChange(() => _tui.requestRender());
			return {
				dispose: unsub,
				invalidate() {},
				render(width: number): string[] {
					// 1. 累计 usage（与默认一致：遍历全部条目，含 toolResult / branch_summary / compaction）
					const totals = createTotals();
					let latestCacheHitRate: number | undefined;
					for (const entry of ctx.sessionManager.getEntries()) {
						if (entry.type === "message" && entry.message.role === "assistant") {
							const usage = entry.message.usage;
							addUsage(totals, usage);
							const latestPromptTokens = (usage?.input ?? 0) + (usage?.cacheRead ?? 0) + (usage?.cacheWrite ?? 0);
							latestCacheHitRate =
								latestPromptTokens > 0 ? ((usage?.cacheRead ?? 0) / latestPromptTokens) * 100 : undefined;
						} else if (entry.type === "message" && entry.message.role === "toolResult" && entry.message.usage) {
							addUsage(totals, entry.message.usage);
						} else if (
							(entry.type === "branch_summary" || entry.type === "compaction") &&
							(entry as any).usage
						) {
							addUsage(totals, (entry as any).usage);
						}
					}

					// 2. context 使用率（正确处理 compaction 后 token 未知的情况）
					const contextUsage = ctx.getContextUsage();
					const contextWindow = contextUsage?.contextWindow ?? ctx.model?.contextWindow ?? 0;
					const contextPercentValue = contextUsage?.percent ?? 0;
					const contextPercent =
						contextUsage?.percent !== null && contextUsage?.percent !== undefined
							? contextPercentValue.toFixed(1)
							: "?";

					// 3. 第一行：工作目录 + git 分支 + 会话名
					let pwd = formatCwdForFooter(ctx.cwd, process.env.HOME || process.env.USERPROFILE);
					const branch = footerData.getGitBranch();
					if (branch) pwd = `${pwd} (${branch})`;
					const sessionName = ctx.sessionManager.getSessionName();
					if (sessionName) pwd = `${pwd} • ${sessionName}`;

					// 4. 第二行统计部分
					const statsParts: string[] = [];
					if (totals.input) statsParts.push(`↑${formatTokens(totals.input)}`);
					if (totals.output) statsParts.push(`↓${formatTokens(totals.output)}`);
					if (tokEnabled) {
						const now = performance.now();
						if (replyActive) {
							const tokRate = computeTokPerSec(now);
							if (tokRate !== undefined) statsParts.push(`${Math.round(tokRate)} tok/s`);
						} else if (replyAvg && now - replyAvg.endT < TOK_AVG_TTL_MS) {
							statsParts.push(`avg ${Math.round(replyAvg.rate)} tok/s`);
						}
					}
					if (totals.cacheRead) statsParts.push(`R${formatTokens(totals.cacheRead)}`);
					if (totals.cacheWrite) statsParts.push(`W${formatTokens(totals.cacheWrite)}`);
					if ((totals.cacheRead > 0 || totals.cacheWrite > 0) && latestCacheHitRate !== undefined) {
						statsParts.push(`CH${latestCacheHitRate.toFixed(1)}%`);
					}
					if (totals.cost > 0 || mode === "cny") {
						// 自定义展示要素之一：费用单位（人民币 ¥ / 美元 $）
						const costStr =
							mode === "cny" ? `¥${(totals.cost * RATE).toFixed(2)}` : `$${totals.cost.toFixed(3)}`;
						statsParts.push(costStr);
					}

					// context 百分比（>90% 红色、>70% 黄色），auto 指示器
					const autoIndicator = autoCompact ? " (auto)" : "";
					const contextPercentDisplay =
						contextPercent === "?"
							? `?/${formatTokens(contextWindow)}${autoIndicator}`
							: `${contextPercent}%/${formatTokens(contextWindow)}${autoIndicator}`;
					let contextPercentStr: string;
					if (contextPercentValue > 90) contextPercentStr = theme.fg("error", contextPercentDisplay);
					else if (contextPercentValue > 70) contextPercentStr = theme.fg("warning", contextPercentDisplay);
					else contextPercentStr = contextPercentDisplay;
					statsParts.push(contextPercentStr);

					let statsLeft = statsParts.join(" ");

					// 5. 右侧：模型名 + 推理级别（多 provider 时加 provider 前缀）
					const modelName = ctx.model?.id || "no-model";
					let statsLeftWidth = visibleWidth(statsLeft);
					if (statsLeftWidth > width) {
						statsLeft = truncateToWidth(statsLeft, width, "...");
						statsLeftWidth = visibleWidth(statsLeft);
					}
					const minPadding = 2;
					let rightSideWithoutProvider = modelName;
					if (ctx.model?.reasoning) {
						const thinkingLevel = ctx.thinkingLevel || "off";
						rightSideWithoutProvider =
							thinkingLevel === "off" ? `${modelName} • thinking off` : `${modelName} • ${thinkingLevel}`;
					}
					let rightSide = rightSideWithoutProvider;
					if (footerData.getAvailableProviderCount() > 1 && ctx.model) {
						rightSide = `(${ctx.model.provider}) ${rightSideWithoutProvider}`;
						if (statsLeftWidth + minPadding + visibleWidth(rightSide) > width) {
							rightSide = rightSideWithoutProvider;
						}
					}

					// 6. 左右对齐
					const rightSideWidth = visibleWidth(rightSide);
					const totalNeeded = statsLeftWidth + minPadding + rightSideWidth;
					let statsLine: string;
					if (totalNeeded <= width) {
						const padding = " ".repeat(width - statsLeftWidth - rightSideWidth);
						statsLine = statsLeft + padding + rightSide;
					} else {
						const availableForRight = width - statsLeftWidth - minPadding;
						if (availableForRight > 0) {
							const truncatedRight = truncateToWidth(rightSide, availableForRight, "");
							const truncatedRightWidth = visibleWidth(truncatedRight);
							const padding = " ".repeat(Math.max(0, width - statsLeftWidth - truncatedRightWidth));
							statsLine = statsLeft + padding + truncatedRight;
						} else {
							statsLine = statsLeft;
						}
					}

					// 7. 组装输出（dim 样式按默认逻辑分段处理，避免颜色 reset 影响）
					const dimStatsLeft = theme.fg("dim", statsLeft);
					const remainder = statsLine.slice(statsLeft.length);
					const dimRemainder = theme.fg("dim", remainder);
					const pwdLine = truncateToWidth(theme.fg("dim", pwd), width, theme.fg("dim", "..."));
					const lines = [pwdLine, dimStatsLeft + dimRemainder];

					// 8. 扩展状态行（若有）
					const extensionStatuses = footerData.getExtensionStatuses();
					if (extensionStatuses.size > 0) {
						const sortedStatuses = Array.from(extensionStatuses.entries())
							.sort(([a], [b]) => a.localeCompare(b))
							.map(([, text]) => sanitizeStatusText(text));
						const statusLine = sortedStatuses.join(" ");
						lines.push(truncateToWidth(statusLine, width, theme.fg("dim", "...")));
					}
					return lines;
				},
			};
		});

		if (!opts?.silent)
			ctx.ui.notify(
				`费用显示: ${m === "cny" ? `人民币 ¥（汇率 ${RATE}）` : "美元 $"}，/footer 可切换`,
				"info",
			);
	}

	// 初始化/重载：启动、会话切换（resume/fork/new）、/reload 均触发 session_start，自动应用自定义 footer
	pi.on("session_start", (_evt: any, ctx: any) => {
		setMode(ctx, mode, { silent: true });
	});

	pi.registerCommand("footer", {
		description: "自定义 footer: /footer [cny|usd|off|tok [on|off]]（默认人民币 ¥，tok/s 默认开启）",
		handler: async (args, ctx) => {
			const arg = args.trim();
			if (arg === "cny" || arg === "usd" || arg === "off") {
				setMode(ctx, arg);
			} else if (arg === "tok" || arg === "tok on" || arg === "tok off") {
				tokEnabled = arg === "tok" ? !tokEnabled : arg === "tok on";
				saveState();
				ctx.ui.notify(`tok/s 实时速率显示: ${tokEnabled ? "开启" : "关闭"}`, "info");
				if (tokEnabled) tokTuiRef?.requestRender();
			} else {
				setMode(ctx, mode === "cny" ? "usd" : "cny");
			}
		},
	});
}
