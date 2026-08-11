#!/usr/bin/env node
// 截取当前页面截图，保存到文件并输出路径（配合 read 工具查看）
// 用法: browser-shot.mjs [--target <id>] [--full] [--out <path>]
import { selectTarget, cdp, parseArgs } from './lib/cdp.mjs';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const { flags, values, positional } = parseArgs(process.argv.slice(2));
const full = flags.has('full');
const outPath = values.out || (positional[0] ? positional[0] : null);

const target = await selectTarget({ target: values.target });
const ws = target.webSocketDebuggerUrl;

let shot;
if (full) {
  // 全页截图：先取文档尺寸，再 captureBeyondViewport + clip
  const dim = await cdp(ws, 'Runtime.evaluate', {
    expression: '({width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight})',
    returnByValue: true,
  });
  const { width, height } = dim.result.value;
  shot = await cdp(ws, 'Page.captureScreenshot', {
    format: 'png',
    captureBeyondViewport: true,
    clip: { x: 0, y: 0, width, height, scale: 1 },
  });
} else {
  shot = await cdp(ws, 'Page.captureScreenshot', { format: 'png' });
}

const filepath = outPath || join(tmpdir(), `browser-shot-${Date.now()}.png`);
writeFileSync(filepath, Buffer.from(shot.data, 'base64'));
console.log(`[OK] 截图已保存: ${filepath}  (${(shot.data.length * 0.75 / 1024).toFixed(0)} KB, 页面 ${target.title || target.url})`);
