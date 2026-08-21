// 临时脚本：监听页面 console 异常并重新加载页面，输出错误
import { selectTarget, cdp, parseArgs } from './lib/cdp.mjs';

const { flags } = parseArgs(process.argv.slice(2));
const target = await selectTarget();
const ws = target.webSocketDebuggerUrl;

// 保持长连接的 WebSocket 封装
function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    ws.onopen = () => resolve(ws);
    ws.onerror = (e) => reject(e);
  });
}

const sock = await connect(ws);
let id = 0;
const pending = new Map();
const rawSend = (ws0, s) => ws0.send(s);
const send = (method, params = {}) => new Promise((res, rej) => {
  const msgId = ++id;
  pending.set(msgId, { res, rej });
  rawSend(sock, JSON.stringify({ id: msgId, method, params }));
});

sock.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const p = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? p.rej(new Error(msg.error.message)) : p.res(msg.result);
    return;
  }
  // 事件
  if (msg.method === 'Runtime.consoleAPICalled') {
    const args = msg.params.args.map(a => a.value ?? a.description ?? '').join(' ');
    console.log(`[console.${msg.params.type}] ${args.slice(0, 300)}`);
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    const d = msg.params.exceptionDetails;
    const text = d.exception?.description || d.text || '';
    console.log(`[EXCEPTION] ${text.slice(0, 500)}`);
  }
  if (msg.method === 'Log.entryAdded') {
    const e = msg.params.entry;
    if (e.level === 'error' || e.level === 'warning') {
      console.log(`[log.${e.level}] ${e.text?.slice(0, 300)}`);
    }
  }
  if (msg.method === 'Network.loadingFailed') {
    console.log(`[net-fail] ${msg.params.errorText} ${msg.params.blockedReason || ''}`);
  }
};

await send('Runtime.enable');
await send('Log.enable');
await send('Network.enable');
if (flags.has('reload')) {
  await send('Page.enable');
  await send('Page.reload', { ignoreCache: true });
}
console.log('监听中... (Ctrl+C 结束)');
setTimeout(() => process.exit(0), 15000);
