// 独り言のストア用スクショ撮影：Chrome for Testing + CDP（まとめるくん/うながすくんの型）
// 拡張をunpackedで読み込み、seedデータを入れて実UIを撮る。
// 640x400 + deviceScaleFactor 2 で 1280x800 のPNGが直接出る。
// 使い方:
//   CHROME_FOR_TESTING=<実行ファイル> node test/store_shots.mjs
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const CHROME = process.env.CHROME_FOR_TESTING;
if (!CHROME) {
  console.log('NG: 環境変数 CHROME_FOR_TESTING を設定してください');
  process.exit(1);
}
const SCRATCH = mkdtempSync(path.join(tmpdir(), 'hg-shots-'));
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const OUT = path.join(ROOT, 'store-assets');
mkdirSync(OUT, { recursive: true });
const PORT = 9336;

const args = [
  `--user-data-dir=${SCRATCH}/profile`,
  `--load-extension=${ROOT}/extension`,
  `--remote-debugging-port=${PORT}`,
  '--no-first-run', '--no-default-browser-check', '--disable-sync',
  '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
  '--window-size=800,600',
  'about:blank',
];
const chrome = spawn(CHROME, args, { stdio: 'ignore' });

let wsUrl = null;
for (let i = 0; i < 40; i++) {
  await sleep(500);
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}/json/version`);
    wsUrl = (await res.json()).webSocketDebuggerUrl;
    break;
  } catch { /* まだ起動中 */ }
}
if (!wsUrl) { console.log('NG: Chromeが起動しない'); process.exit(1); }

const ws = new WebSocket(wsUrl);
await new Promise((ok, ng) => { ws.onopen = ok; ws.onerror = ng; });
let seq = 0;
const pending = new Map();
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { ok, ng } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? ng(new Error(msg.error.message)) : ok(msg.result);
  }
};
function send(method, params = {}, sessionId) {
  const id = ++seq;
  return new Promise((ok, ng) => {
    pending.set(id, { ok, ng });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
}
async function attach(targetId) {
  return (await send('Target.attachToTarget', { targetId, flatten: true })).sessionId;
}
async function evalIn(sid, expression) {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sid);
  if (r.exceptionDetails) throw new Error(String(r.exceptionDetails.exception?.description || r.exceptionDetails.text));
  return r.result.value;
}

await sleep(2000);

// ---- 拡張IDの特定 ----
// Chrome内部の拡張（thunk.js等）も SW を持つため、ターゲット探索では取り違える。
// unpacked のIDは「絶対パスの sha256 先頭32桁を a〜p に写像」で決まるので計算で出す
const extId = [...createHash('sha256').update(`${ROOT}/extension`, 'utf8').digest('hex').slice(0, 32)]
  .map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
console.log('拡張ID:', extId);

// ---- sidepanel をタブで開き、ページ側から seed → リロードで読み直す ----
// （SWへの attach は環境によって chrome.storage が引けないことがあるため、ページ側で入れる）
const opened = await send('Target.createTarget', { url: `chrome-extension://${extId}/sidepanel.html` });
const pageSid = await attach(opened.targetId);
await send('Page.enable', {}, pageSid);
await sleep(1000);

await evalIn(pageSid, `(async () => {
  await chrome.storage.local.set({
    en_recurring: [
      { text: 'concentrate to → concentrate on', count: 4, last_seen: '2026-08-15' },
      { text: 'in the weekend → on the weekend', count: 3, last_seen: '2026-08-17' },
      { text: '冠詞の抜け（go to park → go to the park）', count: 2, last_seen: '2026-08-17' },
    ],
    en_sessions: [
      {
        id: '2026-08-18T21:04:00.000Z',
        transcript: "Yesterday I go to park near my house and I practiced to speak English for thirty minutes. I think I could concentrate to speaking more than last week.",
        corrected_text: "Yesterday I went to the park near my house and practiced speaking English for thirty minutes. I think I was able to concentrate on speaking more than last week.",
        issues: [
          { type: 'grammar', original: 'I go to park', suggestion: 'I went to the park', reason: '昨日のことなので過去形にします。park には冠詞 the が必要です。' },
          { type: 'grammar', original: 'practiced to speak', suggestion: 'practiced speaking', reason: 'practice は動名詞（-ing）をとる動詞です。' },
          { type: 'vocabulary', original: 'concentrate to', suggestion: 'concentrate on', reason: 'concentrate は前置詞 on と組み合わせます。' },
        ],
        good: '時間や比較の表現（for thirty minutes / more than last week）が自然に使えています。',
        engineId: 'nano',
      },
      {
        id: '2026-08-17T12:30:00.000Z',
        transcript: "I will explain about my favorite movie.",
        corrected_text: "I will talk about my favorite movie.",
        issues: [
          { type: 'vocabulary', original: 'explain about', suggestion: 'talk about', reason: 'explain は about を伴いません。' },
        ],
        good: '文の構成がはっきりしていました。',
        engineId: 'nano',
      },
    ],
  });
  return true;
})()`);

// seed を反映した状態で読み直す
await send('Page.reload', {}, pageSid);
await sleep(1500);
await send('Emulation.setDeviceMetricsOverride', {
  width: 640, height: 400, deviceScaleFactor: 2, mobile: false,
}, pageSid);
await sleep(500);

// 撮影用の額装：パネルを中央に置き、左右は紫系の背景にする（本体CSSは触らず全高で見せる）
await evalIn(pageSid, `(() => {
  const st = document.createElement('style');
  st.textContent = \`
    html {
      background: radial-gradient(120% 140% at 50% 0%, #3b2f63 0%, #221a3e 55%, #171130 100%) fixed;
    }
    body {
      width: 372px; height: 100vh; margin: 0 auto;
      box-shadow: 0 0 48px rgba(0,0,0,0.6), 0 0 0 1px rgba(167,139,250,0.3);
    }
  \`;
  document.head.appendChild(st);
  return true;
})()`);

async function shot(name) {
  await sleep(800);
  const r = await send('Page.captureScreenshot', { format: 'png' }, pageSid);
  writeFileSync(path.join(OUT, name), Buffer.from(r.data, 'base64'));
  console.log('saved:', name);
}

// ---- 1枚目: 開始前（今日はここに気をつける） ----
// このChromeにはNanoが無いので、表示確認用に available を装う（本番コードの分岐はそのまま通す）
await evalIn(pageSid, `(() => { nanoState = 'available'; enLatest = null; renderEnglish(); return true; })()`);
await shot('screenshot_01.png');

// ---- 2枚目: 添削結果 ----
await evalIn(pageSid, `(() => {
  enLatest = {
    engineId: 'nano',
    corrected_text: "Yesterday I went to the park near my house and practiced speaking English for thirty minutes.",
    issues: [
      { type: 'grammar', original: 'I go to park', suggestion: 'I went to the park', reason: '昨日のことなので過去形にします。park には冠詞 the が必要です。' },
      { type: 'vocabulary', original: 'concentrate to', suggestion: 'concentrate on', reason: 'concentrate は前置詞 on と組み合わせます。' },
    ],
    recurring: [],
    recognition_doubt: [],
    good: '時間や比較の表現が自然に使えています。',
  };
  renderEnglish();
  return true;
})()`);
await shot('screenshot_02.png');

// ---- 3枚目: 聞き取りが怪しい箇所（別枠表示）を含む結果 ----
await evalIn(pageSid, `(() => {
  enLatest = {
    engineId: 'nano',
    corrected_text: "I ordered french fries and a strawberry shake at the cafe.",
    issues: [
      { type: 'phrasing', original: 'I did order', suggestion: 'I ordered', reason: '強調の意図がなければシンプルな過去形が自然です。' },
    ],
    recurring: [],
    recognition_doubt: ['french fries and extractions'],
    good: '注文の場面を具体的に説明できています。',
  };
  renderEnglish();
  // 別枠（聞き取りが怪しい箇所）と修正版が画面に入るようスクロールする
  const doubt = document.querySelector('.en-doubt');
  if (doubt) doubt.closest('.en-section, div')?.scrollIntoView({ block: 'start' });
  return true;
})()`);
await shot('screenshot_03.png');

// ---- 4枚目: 履歴タブ ----
await evalIn(pageSid, `(async () => {
  const h = await HistoryStore.load();
  enSessions = h.enSessions; enRecurring = h.enRecurring;
  document.getElementById('tab-history').click();
  renderHistory();
  return true;
})()`);
await shot('screenshot_04.png');

chrome.kill();
console.log('完了');
process.exit(0);
