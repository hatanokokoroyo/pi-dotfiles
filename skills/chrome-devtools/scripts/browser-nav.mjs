#!/usr/bin/env node
// 导航页面：默认在当前 tab 导航，--new 打开新标签页
// 用法: browser-nav.mjs <url> [--new]
import { getTargets, cdp, loadState, saveState } from './lib/cdp.mjs';

const args = process.argv.slice(2);
const newTab = args.includes('--new');
const url = args.find((a) => !a.startsWith('-'));

if (!url) {
  console.log('用法: browser-nav.mjs <url> [--new]');
  console.log('  browser-nav.mjs https://example.com           # 当前 tab 导航');
  console.log('  browser-nav.mjs https://example.com --new     # 新开标签页');
  process.exit(1);
}

// 等待页面加载完成（readyState === 'complete'），避免紧随其后的 eval/shot 拿到空白页
async function waitLoaded(wsUrl, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const st = await cdp(wsUrl, 'Runtime.evaluate', { expression: 'document.readyState', returnByValue: true });
      if (st.result?.value === 'complete') return;
    } catch { /* 页面切换过程中可能短暂不可用，忽略重试 */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  console.warn('[WARN] 等待页面加载超时，继续执行（可用 browser-eval 检查 document.readyState）');
}

let target;
if (newTab) {
  // CDP HTTP 端点：PUT /json/new?url=...
  const res = await fetch(`http://localhost:${process.env.CDP_PORT || '9222'}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' });
  if (!res.ok) throw new Error(`[ERROR] 新开标签页失败: HTTP ${res.status}`);
  const t = await res.json();
  saveState({ ...loadState(), lastTarget: t.id });
  target = t;
  console.log(`[OK] 新开标签页: ${url}  (target ${t.id})`);
} else {
  const targets = (await getTargets()).filter((x) => x.type === 'page');
  if (!targets.length) throw new Error('[ERROR] 没有可用的页面');
  const state = loadState();
  target =
    targets.find((t) => t.id === state.lastTarget) ||
    targets.find((t) => !t.url.startsWith('chrome://')) ||
    targets[0];
  await cdp(target.webSocketDebuggerUrl, 'Page.navigate', { url });
  saveState({ ...state, lastTarget: target.id });
  console.log(`[OK] 已导航: ${url}  (target ${target.id})`);
}

await waitLoaded(target.webSocketDebuggerUrl);
