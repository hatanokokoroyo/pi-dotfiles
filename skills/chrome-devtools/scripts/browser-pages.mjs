#!/usr/bin/env node
// 列出 Windows Chrome 当前打开的所有页面（验证连接 + 查看 target id）
import { getTargets } from './lib/cdp.mjs';

const targets = await getTargets();
const pages = targets.filter((t) => t.type === 'page');
console.log(`[OK] 已连接 Windows Chrome（localhost:${process.env.CDP_PORT || '9222'}），共 ${pages.length} 个页面:`);
for (const t of pages) {
  console.log(`  ${t.id}  ${t.title || '(无标题)'}  ${t.url}`);
}
