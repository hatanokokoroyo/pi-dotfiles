// CDP 公共封装：连接 Windows Chrome 的远程调试端口（WSL2 镜像模式下 localhost 互通）
// 零依赖：Node >= 22 内置 fetch / WebSocket
// 用法：其他 browser-*.mjs 脚本 import 本模块
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const CDP_PORT = process.env.CDP_PORT || '9222';
const STATE_DIR = join(homedir(), '.cache', 'pi-browser');
export const STATE_FILE = join(STATE_DIR, 'state.json');

// --- 状态持久化（记录上次操作的 target，供 eval/shot 默认使用） ---
export function loadState() {
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf8')); } catch { return {}; }
}

export function saveState(state) {
  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

// --- 获取浏览器 target 列表 ---
export async function getTargets() {
  const res = await fetch(`http://localhost:${CDP_PORT}/json`);
  if (!res.ok) {
    throw new Error(`[ERROR] CDP 连接失败（HTTP ${res.status}）。请确认 Windows Chrome 已通过任务栏快捷方式启动（含 --remote-debugging-port=${CDP_PORT}），且 WSL2 为镜像模式。`);
  }
  return res.json();
}

// --- 选择页面 target：显式 --target 优先，其次上次记录，最后第一个非 chrome:// 页面 ---
export async function selectTarget(opts = {}) {
  const targets = (await getTargets()).filter((t) => t.type === 'page');
  if (!targets.length) throw new Error('[ERROR] 没有可用的 page target');
  if (opts.target) {
    const t = targets.find((x) => x.id === opts.target);
    if (!t) throw new Error(`[ERROR] target ${opts.target} 不存在，用 browser-pages 查看可用 id`);
    return t;
  }
  const state = loadState();
  if (state.lastTarget) {
    const t = targets.find((x) => x.id === state.lastTarget);
    if (t) return t;
  }
  return targets.find((t) => !t.url.startsWith('chrome://')) || targets[0];
}

// --- 通过 WebSocket 调用一次 CDP 方法 ---
export function cdp(wsUrl, method, params = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error(`[ERROR] CDP 调用超时: ${method}`));
    }, 30000);
    ws.onopen = () => ws.send(JSON.stringify({ id: 1, method, params }));
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id === 1) {
        clearTimeout(timer);
        ws.close();
        msg.error ? reject(new Error(`[ERROR] ${method}: ${msg.error.message}`)) : resolve(msg.result);
      }
    };
    ws.onerror = () => {
      clearTimeout(timer);
      reject(new Error(`[ERROR] WebSocket 连接失败: ${wsUrl}`));
    };
  });
}

// --- 通用参数解析：提取 --key value / --flag，剩余为位置参数 ---
export function parseArgs(argv) {
  const flags = new Set();
  const values = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const name = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        values[name] = next;
        i++;
      } else {
        flags.add(name);
      }
    } else {
      positional.push(a);
    }
  }
  return { flags, values, positional };
}
