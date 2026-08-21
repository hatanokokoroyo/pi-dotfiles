// 临时脚本：监听网络请求与 JS 异常，带 initiator 信息
import { selectTarget, cdp, parseArgs } from './lib/cdp.mjs';

const { values } = parseArgs(process.argv.slice(2));
const target = await selectTarget({ target: values.target });
const wsUrl = target.webSocketDebuggerUrl;

function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    ws.onopen = () => resolve(ws);
    ws.onerror = (e) => reject(e);
  });
}

const sock = await connect(wsUrl);
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
  if (msg.method === 'Network.requestWillBeSent') {
    const r = msg.params.request;
    const init = msg.params.initiator;
    const stack = init.stack?.callFrames?.slice(0, 3).map(f => `${f.functionName}@${f.url.split('/').pop()}:${f.lineNumber}`).join(' <- ') || init.type;
    console.log(`[REQ] ${r.method} ${r.url}`);
    console.log(`      init: ${stack}`);
  }
  if (msg.method === 'Network.loadingFailed') {
    console.log(`[FAIL] ${msg.params.errorText} ${msg.params.canceled ? 'canceled' : ''}`);
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    console.log(`[EXC] ${(msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text).slice(0, 300)}`);
  }
};

await send('Network.enable');
await send('Runtime.enable');
if (values.reload === '1') {
  await send('Page.enable');
  await send('Page.reload', { ignoreCache: true });
}
console.log('监听中...');
setTimeout(() => process.exit(0), 20000);
