#!/usr/bin/env node
// 在当前页面执行 JavaScript（DOM 读取/操作），输出结果
// 用法: browser-eval.mjs [--target <id>] '<js 表达式或语句>'
import { selectTarget, cdp, parseArgs } from './lib/cdp.mjs';

const { flags, values, positional } = parseArgs(process.argv.slice(2));
const expr = positional.join(' ');

if (!expr) {
  console.log('用法: browser-eval.mjs [--target <id>] \'<js>\'');
  console.log('示例:');
  console.log("  browser-eval.mjs 'document.title'");
  console.log("  browser-eval.mjs 'document.querySelectorAll(\"a\").length'");
  console.log("  browser-eval.mjs 'await fetch(\"https://api.example.com\").then(r => r.status)'");
  process.exit(1);
}

const target = await selectTarget({ target: values.target });
const r = await cdp(target.webSocketDebuggerUrl, 'Runtime.evaluate', {
  expression: expr,
  returnByValue: true,
  awaitPromise: true,
});

if (r.exceptionDetails) {
  console.error(`[ERROR] 页面执行异常: ${r.exceptionDetails.text} ${r.exceptionDetails.exception?.description || ''}`.trim());
  process.exit(1);
}

const v = r.result;
if (v.type === 'object' && v.subtype === 'error') {
  console.error(`[ERROR] ${v.description || 'JS 错误'}`);
  process.exit(1);
}
if (v.value === undefined) {
  console.log('(undefined)');
} else if (typeof v.value === 'string') {
  console.log(v.value);
} else {
  console.log(JSON.stringify(v.value, null, 2));
}
