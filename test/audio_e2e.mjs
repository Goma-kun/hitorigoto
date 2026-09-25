// 音声モードの E2E 検証：Chrome for Testing + CDP で本番の拡張を開き、
// 実際の音声（webm/opus）を runEnglishFeedback に流して Gemini → 描画 → 保存まで通す。
//   実行: AUDIO=<音声.webm> ASR="<Chrome風の認識テキスト>" node test/audio_e2e.mjs
//   例:   ffmpeg -ss 30 -t 60 -i 収録.mp4 -vn -c:a libopus -b:a 32k -ac 1 /tmp/a.webm
// - Gemini API キーは ~/.config/nishira/gemini_api_key から読む（表示しない・リポジトリに入れない）
// - Chrome の疑似マイク（--use-file-for-fake-audio-capture）は Chrome 152 で無音しか録れなかったので、
//   録音層は「開始→停止で recorder が動く・無音なら結果を出さない」だけを見て、音声は直接流す
// - store_shots.mjs と同じ CDP の型
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { readFileSync, writeFileSync, rmSync, mkdtempSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ROOT   = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const OUT    = mkdtempSync(path.join(tmpdir(), 'hitorigoto-e2e-'));
const CHROME = process.env.CHROME; // Chrome for Testing の実行ファイル（例: .../Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing）
if (!CHROME) { console.error('NG: CHROME 環境変数に Chrome for Testing の実行ファイルを指定してください'); process.exit(1); }
const AUDIO  = process.env.AUDIO;
const ASR    = process.env.ASR || '';
if (!AUDIO) { console.log('NG: AUDIO=<音声ファイル> を指定してください'); process.exit(1); }
const KEY = readFileSync(`${homedir()}/.config/nishira/gemini_api_key`, 'utf8').trim();
const PORT = 9341;

const args = [
  `--user-data-dir=${OUT}/profile`, `--load-extension=${ROOT}/extension`, `--remote-debugging-port=${PORT}`,
  '--no-first-run', '--no-default-browser-check', '--disable-sync',
  '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
  '--window-size=420,760', 'about:blank',
];
const chrome = spawn(CHROME, args, { stdio: 'ignore' });
let wsUrl = null;
for (let i = 0; i < 40; i++) { await sleep(500); try { wsUrl = (await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json()).webSocketDebuggerUrl; break; } catch {} }
if (!wsUrl) { console.log('NG: Chrome が起動しない'); process.exit(1); }
const ws = new WebSocket(wsUrl); await new Promise((ok, ng) => { ws.onopen = ok; ws.onerror = ng; });
let seq = 0; const pending = new Map(); const logs = [];
ws.onmessage = (ev) => { const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { const { ok, ng } = pending.get(m.id); pending.delete(m.id); m.error ? ng(new Error(m.error.message)) : ok(m.result); }
  if (m.method === 'Runtime.consoleAPICalled') logs.push(`[console.${m.params.type}] ` + m.params.args.map(a => a.value ?? a.description).join(' '));
  if (m.method === 'Runtime.exceptionThrown') logs.push('[exception] ' + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
};
const send = (method, params = {}, sessionId) => new Promise((ok, ng) => { const id = ++seq; pending.set(id, { ok, ng }); ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })); });
const attach = async (t) => (await send('Target.attachToTarget', { targetId: t, flatten: true })).sessionId;
const evalIn = async (sid, expression) => { const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sid); if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text); return r.result.value; };
const waitIdle = async (sid) => { for (let i = 0; i < 90; i++) { await sleep(2000); if (!(await evalIn(sid, `enBusy`))) return true; } return false; };
const shot = async (sid, name) => { const r = await send('Page.captureScreenshot', { format: 'png' }, sid); writeFileSync(`${OUT}/${name}.png`, Buffer.from(r.data, 'base64')); };

try {
  await sleep(2000);
  const extId = [...createHash('sha256').update(`${ROOT}/extension`, 'utf8').digest('hex').slice(0, 32)].map(c => String.fromCharCode(97 + parseInt(c, 16))).join('');
  const opened = await send('Target.createTarget', { url: `chrome-extension://${extId}/sidepanel.html` });
  const sid = await attach(opened.targetId);
  await send('Page.enable', {}, sid); await send('Runtime.enable', {}, sid);
  await sleep(800);
  await evalIn(sid, `chrome.storage.local.set({ hg_gemini_key: ${JSON.stringify(KEY)}, hg_audio: 'on', en_sessions: [], en_recurring: [] })`);
  await send('Page.reload', {}, sid); await sleep(1500);

  // ① 録音層: 開始→停止で recorder が動き、疑似マイク（無音）では結果を出さない
  console.log('audioEnabled:', await evalIn(sid, `audioEnabled()`));
  await evalIn(sid, `document.getElementById('toggle-btn').click()`);
  await sleep(3000);
  console.log('録音中 recorder.active:', await evalIn(sid, `audioRec.active`));
  await evalIn(sid, `document.getElementById('toggle-btn').click()`);
  await waitIdle(sid);
  console.log('無音のとき:', (await evalIn(sid, `document.querySelector('#en-feedback').innerText`)).split('\n')[0]);
  console.log('無音のとき session 数:', await evalIn(sid, `enSessions.length`), '（0 が正）');

  // ② 実音声を直接流す（Chrome 風の認識テキストは ASR で渡す。空でも可）
  const b64 = readFileSync(AUDIO).toString('base64');
  const mime = AUDIO.endsWith('.ogg') ? 'audio/ogg;codecs=opus' : 'audio/webm;codecs=opus';
  await evalIn(sid, `(async()=>{ const bin=atob(${JSON.stringify(b64)}); const u8=new Uint8Array(bin.length); for(let i=0;i<bin.length;i++)u8[i]=bin.charCodeAt(i); window.__real=new Blob([u8],{type:'${mime}'}); transcript=${JSON.stringify(ASR)}; enLatest=null; enError=''; return true; })()`);
  await evalIn(sid, `runEnglishFeedback(window.__real); true`);
  console.log('添削完了:', await waitIdle(sid));
  console.log('===== #en-feedback =====');
  console.log(await evalIn(sid, `document.querySelector('#en-feedback').innerText`));
  console.log('===== session[0] =====');
  console.log(JSON.stringify(await evalIn(sid, `enSessions[0] || null`), null, 1));
  await evalIn(sid, `document.querySelector('#panel-speak').scrollTop = 0; true`);
  await shot(sid, 'result_top');
  console.log('===== console/exception =====');
  console.log(logs.join('\n') || '(なし)');
  console.log('スクショ:', `${OUT}/result_top.png`);
} finally {
  chrome.kill();
  rmSync(`${OUT}/profile`, { recursive: true, force: true });
}
